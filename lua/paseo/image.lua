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

---Does `path` name a picture, by its extension? What the transcript asks of a
---file an agent read or linked before it hangs a thumbnail under it.
---@param path string|nil
---@return boolean
function M.is_image_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ext = path:match "%.([%w]+)$"
  return ext ~= nil and BY_EXTENSION[ext:lower()] ~= nil
end

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

---What a terminal paste of FILES looks like: a path, a `file://` URL, a
---quoted or backslash-escaped path, or several of them, one per line or
---space-separated. That is what dragging a file onto the terminal, or
---pasting one copied in a file manager, delivers -- text, never bytes.
---@param text string
---@return string[]|nil paths  Every one an image file on disk; nil if any is not.
local function paths_in(text)
  local function one(token)
    token = vim.trim(token)
    if token == "" then
      return nil
    end
    local quoted = token:match "^'(.*)'$" or token:match '^"(.*)"$'
    token = quoted or token:gsub("\\(.)", "%1")
    if token:match "^file://" then
      local ok, path = pcall(vim.uri_to_fname, token)
      token = ok and path or token
    end
    token = vim.fn.expand(token)
    if not BY_EXTENSION[vim.fn.fnamemodify(token, ":e"):lower()] then
      return nil
    end
    local stat = vim.uv.fs_stat(token)
    return stat and stat.type == "file" and token or nil
  end

  local out = {}
  for _, line in ipairs(vim.split(vim.trim(text), "\n", { trimempty = true })) do
    local whole = one(line)
    if whole then
      out[#out + 1] = whole
    else
      -- Several on one line: split on spaces that are not escaped or quoted.
      local tokens, current, quote = {}, {}, nil
      local i = 1
      while i <= #line do
        local c = line:sub(i, i)
        if c == "\\" and not quote then
          current[#current + 1] = line:sub(i, i + 1)
          i = i + 1
        elseif (c == "'" or c == '"') and (quote == nil or quote == c) then
          quote = quote == nil and c or nil
          current[#current + 1] = c
        elseif c:match "%s" and not quote then
          tokens[#tokens + 1] = table.concat(current)
          current = {}
        else
          current[#current + 1] = c
        end
        i = i + 1
      end
      tokens[#tokens + 1] = table.concat(current)
      for _, token in ipairs(tokens) do
        if vim.trim(token) ~= "" then
          local path = one(token)
          if not path then
            return nil
          end
          out[#out + 1] = path
        end
      end
    end
  end
  return #out > 0 and out or nil
end

---The images a paste names, if it names nothing but images.
---
---nil, nil means "this is ordinary text, paste it": a sentence that happens
---to mention `shot.png` is not a request to attach it, so EVERY token has to
---be an image file that exists.
---@param lines string[]|string  What `vim.paste` was handed.
---@return paseo.Image[]|nil images, string|nil err
function M.from_paste(lines)
  local text = type(lines) == "table" and table.concat(lines, "\n") or lines
  if #text > 8192 then
    return nil, nil
  end
  local paths = paths_in(text)
  if not paths then
    return nil, nil
  end
  local images = {}
  for _, path in ipairs(paths) do
    local image, err = M.from_file(path)
    if not image then
      return nil, err
    end
    images[#images + 1] = image
  end
  return images, nil
end

-- ------------------------------------------------------------ remembered

---Where the images you sent are kept, by the id of the message they went
---with. The timeline carries the words of a message and not its pictures, so
---this is the only way a transcript can show them again -- after a restart
---too, since the id comes back on the timeline as it was sent.
---@return string
function M.cache_dir()
  return vim.fs.joinpath(vim.fn.stdpath "cache", "paseo", "images")
end

---A fresh message id: a UUIDv4, the shape the daemon makes its own.
---@return string
function M.message_id()
  local bytes = vim.uv.random(16)
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = ("%02x"):format(b[i])
  end
  local h = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

local BY_MIME = {}
for ext, mime in pairs(BY_EXTENSION) do
  if not BY_MIME[mime] or #ext < #BY_MIME[mime] then
    BY_MIME[mime] = ext
  end
end

---A message id is a file name here, so nothing that could leave the folder.
---@param id string
---@return boolean
local function safe(id)
  return type(id) == "string" and id:match "^[%w-]+$" ~= nil and #id <= 128
end

---Write the images a message is about to carry, in the order its
---placeholders count. Before the request goes out, so the message can never
---come back before its pictures are on disk.
---@param id string
---@param images { data: string, mimeType: string }[]
---@return boolean ok
function M.store(id, images)
  if not safe(id) or #images == 0 then
    return false
  end
  local dir = vim.fs.joinpath(M.cache_dir(), id)
  vim.fn.mkdir(dir, "p")
  for n, image in ipairs(images) do
    local ext = BY_MIME[image.mimeType] or "png"
    local ok, bytes = pcall(vim.base64.decode, image.data or "")
    local fd = ok and io.open(vim.fs.joinpath(dir, ("%d.%s"):format(n, ext)), "wb")
    if fd then
      fd:write(bytes)
      fd:close()
    end
  end
  M.prune()
  return true
end

---The images stored for message `id`, in placeholder order.
---@param id string|nil
---@return string[]
function M.stored(id)
  if not safe(id) then
    return {}
  end
  local dir = vim.fs.joinpath(M.cache_dir(), id)
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    local n = kind == "file" and tonumber(name:match "^(%d+)%.")
    if n then
      found[#found + 1] = { n = n, path = vim.fs.joinpath(dir, name) }
    end
  end
  table.sort(found, function(a, b)
    return a.n < b.n
  end)
  return vim.tbl_map(function(f)
    return f.path
  end, found)
end

---How long a sent image is kept.
M.keep_days = 30

---Forget images sent more than `M.keep_days` ago. Once a session: it is a
---directory listing, and nothing needs it sooner.
function M.prune()
  if M._pruned then
    return
  end
  M._pruned = true
  local cutoff = os.time() - M.keep_days * 86400
  local root = M.cache_dir()
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and safe(name) then
      local path = vim.fs.joinpath(root, name)
      local stat = vim.uv.fs_stat(path)
      if stat and stat.mtime.sec < cutoff then
        vim.fn.delete(path, "rf")
      end
    end
  end
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
