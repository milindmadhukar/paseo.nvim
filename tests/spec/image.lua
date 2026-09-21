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

  vim.fn.delete(path)
  vim.fn.delete(text)
end

return {
  { "image", test_image },
}
