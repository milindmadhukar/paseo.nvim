--- Pasting an image into the composer.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_image()
  local image = require "paseo.image"

  -- Binary, with the NUL bytes and the 0x0a that make readfile() the wrong
  -- tool: a PNG signature is exactly that shape.
  local bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0"
  local path = vim.fn.tempname() .. ".png"
  local fd = assert(io.open(path, "wb"))
  fd:write(bytes)
  fd:close()

  local png, err = image.from_file(path)
  eq("image: a .png is read as image/png", png and png.mime, "image/png")
  eq("image: no error with it", err, nil)
  -- The regression this guards: reading through readfile() split the file on
  -- newlines and dropped the NULs, so the bytes that arrived were not the
  -- bytes on disk -- and a provider rejected the result as a corrupt image.
  eq("image: the bytes survive the round trip", png and vim.base64.decode(png.data), bytes)
  eq("image: and the size is the size before encoding", png and png.bytes, #bytes)

  local text = vim.fn.tempname() .. ".txt"
  local handle = assert(io.open(text, "w"))
  handle:write "not a picture"
  handle:close()
  local none, why = image.from_file(text)
  truthy("image: a .txt is refused", none == nil and why ~= nil)

  local absent, missing = image.from_file(vim.fn.tempname() .. ".png")
  truthy("image: a file that is not there is refused", absent == nil and missing ~= nil)

  -- Refused HERE rather than after a round trip to the daemon: no provider
  -- takes a 40 MB screenshot, and base64 makes it a third larger again.
  local limit = image.max_bytes
  image.max_bytes = 4
  local big, too_big = image.from_file(path)
  image.max_bytes = limit
  truthy("image: an oversized file is refused before sending", big == nil and too_big ~= nil)

  local names = {}
  for _, reader in ipairs(image.readers()) do
    names[#names + 1] = reader.name
  end
  eq("image: the clipboard readers are reported for checkhealth", names, {
    "wl-paste",
    "xclip",
    "pngpaste",
  })

  -- Placeholders are TEXT in the prompt; the bytes are a field of the request.
  -- Inlining base64 into the prompt is the obvious wrong turn here -- it works
  -- once, against one provider, and reads as a wall of noise on the timeline.
  local chat = io.open(vim.fn.getcwd() .. "/lua/paseo/ui/chat.lua", "r")
  if chat then
    local source = chat:read "*a"
    chat:close()
    truthy(
      "image: the chat sends images beside the prompt, not inside it",
      source:find("images = #images > 0 and images or nil", 1, true) ~= nil
    )
  end

  -- A PASTE THAT NAMES FILES: what dragging one onto the terminal, or
  -- pasting one copied in a file manager, delivers.
  local dir = vim.fn.tempname() .. " shots"
  vim.fn.mkdir(dir, "p")
  local spaced = dir .. "/my shot.png"
  local second = dir .. "/b.jpg"
  for _, p in ipairs { spaced, second } do
    local fd2 = assert(io.open(p, "wb"))
    fd2:write(bytes)
    fd2:close()
  end
  local function pasted(input)
    local images = image.from_paste(input)
    return images and #images or 0
  end
  eq("paste: a plain path is an image", pasted { path }, 1)
  eq("paste: a file:// URL, %20 and all", pasted { vim.uri_from_fname(spaced) }, 1)
  eq("paste: a quoted path", pasted { "'" .. spaced .. "'" }, 1)
  eq("paste: a backslash-escaped path", pasted { (spaced:gsub(" ", "\\ ")) }, 1)
  eq("paste: one per line", pasted { path, second }, 2)
  eq("paste: several on one line", pasted { (spaced:gsub(" ", "\\ ")) .. " " .. (second:gsub(" ", "\\ ")) }, 2)
  eq("paste: a mime type comes with it", image.from_paste({ second })[1].mime, "image/jpeg")
  eq("paste: a sentence that names one is text", pasted { "look at " .. path }, 0)
  eq("paste: a .txt is text", pasted { text }, 0)
  eq("paste: a path that is not there is text", pasted { dir .. "/gone.png" }, 0)
  eq("paste: ordinary prose is text", pasted { "hello", "world" }, 0)

  -- Outside a composer, vim.paste is untouched.
  require("paseo.ui.chat").attach_events()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.paste({ path }, -1)
  truthy(
    "paste: in any other buffer a path pastes as text",
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find(path, 1, true) ~= nil
  )
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, "rf")

  vim.fn.delete(path)
  vim.fn.delete(text)
end

return {
  { "image", test_image },
}
