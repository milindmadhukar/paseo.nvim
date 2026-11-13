--- Colour arithmetic on `#rrggbb` strings: mix, lighten, hue rotation, HSL.
---
--- What |paseo.ui.theme| derives the palette with. It used to borrow
--- nvzone/volt's colour module; this is the handful of conversions it needed,
--- with the same meanings, so the plugin has no dependency for arithmetic.

local M = {}

---@param hex string
---@return integer|nil r, integer|nil g, integer|nil b
function M.hex2rgb(hex)
  if type(hex) ~= "string" then
    return nil
  end
  local digits = hex:gsub("^#", "")
  if #digits ~= 6 or digits:find "[^%x]" then
    return nil
  end
  return tonumber(digits:sub(1, 2), 16), tonumber(digits:sub(3, 4), 16), tonumber(digits:sub(5, 6), 16)
end

---@return string
function M.rgb2hex(r, g, b)
  -- FLOORED, as the colours this plugin was tuned against were -- a 50% mix
  -- of 255 and 0 is 127, not 128 -- but with a hair of slack, so a value an
  -- HSL round trip returns as 33.9999999 comes back as the 34 it was.
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v + 1e-6)))
  end
  return ("#%02x%02x%02x"):format(clamp(r), clamp(g), clamp(b))
end

---@return number h 0-360, number s 0-1, number l 0-1
function M.rgb2hsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then
    return 0, 0, l
  end
  local d = max - min
  local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
  local h
  if max == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h * 60, s, l
end

---@return number r, number g, number b  0-255
function M.hsl2rgb(h, s, l)
  if s == 0 then
    return l * 255, l * 255, l * 255
  end
  local function channel(p, q, t)
    t = t % 1
    if t < 1 / 6 then
      return p + (q - p) * 6 * t
    elseif t < 1 / 2 then
      return q
    elseif t < 2 / 3 then
      return p + (q - p) * (2 / 3 - t) * 6
    end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  h = (h % 360) / 360
  return channel(p, q, h + 1 / 3) * 255, channel(p, q, h) * 255, channel(p, q, h - 1 / 3) * 255
end

---@param hex string
---@return number|nil h, number|nil s, number|nil l
function M.hex2hsl(hex)
  local r, g, b = M.hex2rgb(hex)
  if not r then
    return nil
  end
  return M.rgb2hsl(r, g, b)
end

---@return string
function M.hsl2hex(h, s, l)
  return M.rgb2hex(M.hsl2rgb(h, s, l))
end

---`second` mixed into `first`: `strength` is the PERCENT of `second` in the
---result, 0-100.
---@param first string
---@param second string
---@param strength number
---@return string
function M.mix(first, second, strength)
  local r1, g1, b1 = M.hex2rgb(first)
  local r2, g2, b2 = M.hex2rgb(second)
  if not (r1 and r2) then
    return first
  end
  local t = math.max(0, math.min(100, strength or 50)) / 100
  return M.rgb2hex(r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t)
end

---Lighter (positive) or darker (negative) by `percent` lightness points.
---@param hex string
---@param percent number
---@return string
function M.change_hex_lightness(hex, percent)
  local h, s, l = M.hex2hsl(hex)
  if not h then
    return hex
  end
  return M.hsl2hex(h, s, math.max(0, math.min(1, l + percent / 100)))
end

---The hue turned by `percent` of the wheel (not degrees).
---@param hex string
---@param percent number
---@return string
function M.change_hex_hue(hex, percent)
  local h, s, l = M.hex2hsl(hex)
  if not h then
    return hex
  end
  return M.hsl2hex((h + percent / 100 * 360) % 360, s, l)
end

return M
