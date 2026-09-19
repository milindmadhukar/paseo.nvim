--- Images for the composer: the clipboard, or a path, as base64.
---
--- Neovim's clipboard is TEXT. An image copied from a browser or a screenshot
--- tool never reaches a register -- `"+p` yields nothing, or at best a file
--- name -- so pasting one into a prompt is not a keymap away. It takes the
--- platform's own clipboard reader, read as BINARY, and carried to the daemon
--- as base64 beside the text, which is the shape `agent.send` already takes.
---
--- Nothing here touches the composer. Getting the bytes and deciding what the
--- prompt looks like are separate problems; the second one lives in
--- `paseo.ui.chat`.

local M = {}

---Bigger than this is refused rather than sent.
---
---Base64 inflates by a third and the whole thing crosses the sidecar's stdin
---as ONE line -- but mostly, no provider accepts a 40 MB screenshot, and
---saying so here costs a sentence instead of a round trip.
M.max_bytes = 10 * 1024 * 1024

---@class paseo.Image
---@field data string    base64, with no data-URL prefix
---@field mime string
---@field bytes integer  size BEFORE encoding
---@field origin string  "clipboard", or the path it was read from

local BY_EXTENSION = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  bmp = "image/bmp",
}

---In order of preference. A clipboard usually carries the same picture several
---ways at once -- a screenshot copied from a browser arrives as PNG, as HTML
---and as a URL -- and PNG is the one every provider takes.
local PREFERRED = { "image/png", "image/jpeg", "image/webp", "image/gif", "image/avif" }

---The best image type on offer, or nil if none of them is an image.
---@param offered string[]
---@return string|nil
local function best(offered)
  local seen, order = {}, {}
  for _, mime in ipairs(offered) do
    mime = vim.trim(mime)
    if mime ~= "" and not seen[mime] then
      seen[mime] = true
      order[#order + 1] = mime
    end
  end
  for _, want in ipairs(PREFERRED) do
    if seen[want] then
      return want
    end
  end
  -- Iterating the LIST, not the set: a table's key order is not defined, and
  -- "whichever image/* came back first" has to mean the same thing twice.
  for _, mime in ipairs(order) do
    if mime:match "^image/" then
      return mime
    end
  end
  return nil
end

---@param bytes string|nil  raw, not text
---@param mime string
---@param origin string
---@return paseo.Image|nil, string|nil
local function encode(bytes, mime, origin)
  if not bytes or bytes == "" then
    return nil, "the image came back empty"
  end
  if #bytes > M.max_bytes then
    return nil,
      ("image is %.1f MB; the limit is %.0f MB"):format(
        #bytes / 1048576,
        M.max_bytes / 1048576
      )
  end
  return { data = vim.base64.encode(bytes), mime = mime, bytes = #bytes, origin = origin }, nil
end

---@class paseo.image.Reader
---@field name string
---@field available fun(): boolean
---@field read fun(): paseo.Image|nil, string|nil

---Readers, in the order they are tried.
---
---A reader returning `nil, nil` means "the clipboard holds no image", which is
---an ANSWER; `nil, err` means the reader itself failed, and the next one still
---gets a turn -- on a Wayland session with XWayland both are installed and
---either may be the one holding the selection.
---@type paseo.image.Reader[]
local readers = {
  {
    name = "wl-paste",
    available = function()
      return vim.fn.executable "wl-paste" == 1 and (vim.env.WAYLAND_DISPLAY or "") ~= ""
    end,
    read = function()
      local types = vim.system({ "wl-paste", "--list-types" }, { text = true }):wait()
      if types.code ~= 0 then
        -- wl-paste exits non-zero on an EMPTY clipboard too, which is not a
        -- failure worth reporting.
        return nil, nil
      end
      local mime = best(vim.split(types.stdout or "", "\n"))
      if not mime then
        return nil, nil
      end
      local out = vim
        .system({ "wl-paste", "--no-newline", "--type", mime }, { text = false })
        :wait()
      if out.code ~= 0 then
        return nil, ("wl-paste --type %s failed: %s"):format(mime, vim.trim(out.stderr or ""))
      end
      return encode(out.stdout, mime, "clipboard")
    end,
  },
  {
    name = "xclip",
    available = function()
      return vim.fn.executable "xclip" == 1 and (vim.env.DISPLAY or "") ~= ""
    end,
    read = function()
      local targets = vim
        .system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { text = true })
        :wait()
      if targets.code ~= 0 then
        return nil, nil
      end
      local mime = best(vim.split(targets.stdout or "", "\n"))
      if not mime then
        return nil, nil
      end
      local out = vim
        .system({ "xclip", "-selection", "clipboard", "-t", mime, "-o" }, { text = false })
        :wait()
      if out.code ~= 0 then
        return nil, ("xclip -t %s failed: %s"):format(mime, vim.trim(out.stderr or ""))
      end
      return encode(out.stdout, mime, "clipboard")
    end,
  },
  {
    name = "pngpaste",
    available = function()
      return vim.fn.executable "pngpaste" == 1
    end,
    read = function()
      local out = vim.system({ "pngpaste", "-" }, { text = false }):wait()
      -- Non-zero means "no image on the pasteboard". That is an answer.
      if out.code ~= 0 then
        return nil, nil
      end
      return encode(out.stdout, "image/png", "clipboard")
    end,
  },
}

---Which readers exist on this machine, and which one could actually run. For
---`:checkhealth paseo`.
---@return { name: string, available: boolean }[]
function M.readers()
  local out = {}
  for _, reader in ipairs(readers) do
    out[#out + 1] = { name = reader.name, available = reader.available() }
  end
  return out
end

---The image on the clipboard, if there is one.
---@return paseo.Image|nil, string|nil error
function M.from_clipboard()
  local tried, failure = 0, nil
  for _, reader in ipairs(readers) do
    if reader.available() then
      tried = tried + 1
      local image, err = reader.read()
      if image then
        return image, nil
      end
      failure = failure or err
    end
  end
  if tried == 0 then
    return nil, "no clipboard image reader found; install wl-paste, xclip or pngpaste"
  end
  return nil, failure or "the clipboard holds no image"
end

---@param path string
---@return paseo.Image|nil, string|nil error
function M.from_file(path)
  path = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, ("no such file: %s"):format(path)
  end

  local mime = BY_EXTENSION[vim.fn.fnamemodify(path, ":e"):lower()]
  if not mime then
    local known = vim.tbl_keys(BY_EXTENSION)
    table.sort(known)
    return nil,
      ("%s is not an image this can carry (%s)"):format(
        vim.fn.fnamemodify(path, ":t"),
        table.concat(known, ", ")
      )
  end

  -- io.open rather than vim.fn.readfile: readfile splits on newlines and
  -- mangles NUL bytes, which is most of a PNG.
  local handle, open_err = io.open(path, "rb")
  if not handle then
    return nil, open_err or ("cannot read " .. path)
  end
  local bytes = handle:read "*a"
  handle:close()

  return encode(bytes, mime, vim.fn.fnamemodify(path, ":~"))
end

---One line about an image, for a notification.
---@param image paseo.Image
---@return string
function M.describe(image)
  local size = image.bytes < 1024 and ("%d B"):format(image.bytes)
    or image.bytes < 1048576 and ("%.0f KB"):format(image.bytes / 1024)
    or ("%.1f MB"):format(image.bytes / 1048576)
  return ("%s, %s"):format(image.mime:gsub("^image/", ""), size)
end

return M
