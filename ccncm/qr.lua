-- ccncm/qr.lua
-- Render a QR code (produced by ncm.util.qrcode) into a Basalt bimg.
--
-- One terminal cell holds a 3x2 block of QR modules using CC:Tweaked's
-- built-in 0x80-0x9F sub-pixel glyphs, so a 33-module code (ECL L, 1-module
-- quiet zone) becomes 18 columns x 12 rows and fits a 51x19 terminal.
--
-- The packing heuristic (calculateTexel / SAMPLING_LOOKUP) is the same one
-- ncm.util.qrcode.printCC uses; that renderer is itself adapted from
-- GMapiServer's qr_bimg_utils.py (GPL-2.0).  The QR *encoding* is not done
-- here - qrcode.encode() supplies the finished module matrix.

local qrcode = require("ncm.util.qrcode")

local M = {}

-- Per-sub-pixel fallback sampling order, used when a sub-pixel is neither of
-- the two dominant states of its 3x2 block.
local SAMPLING_LOOKUP = {
  { 1, 2, 3, 4, 5 },
  { 3, 0, 5, 2, 4 },
  { 0, 3, 4, 1, 5 },
  { 1, 5, 2, 4, 0 },
  { 2, 5, 0, 3, 1 },
  { 3, 4, 1, 2, 0 },
}

-- t = {b1..b6} module states (1 = dark).  Returns glyphByte, state1, state2.
local function calculateTexel(t)
  local counts, order = {}, {}
  for i = 1, 6 do
    local v = t[i]
    if counts[v] == nil then
      counts[v] = 0
      order[#order + 1] = v
    end
    counts[v] = counts[v] + 1
  end
  table.sort(order, function(a, b) return counts[a] > counts[b] end)

  local stream = {}
  for i = 1, 6 do
    local v = t[i]
    if v == order[1] then
      stream[i] = 1
    elseif order[2] ~= nil and v == order[2] then
      stream[i] = 0
    else
      stream[i] = 0
      for _, sample in ipairs(SAMPLING_LOOKUP[i]) do
        local s = t[sample + 1]
        if s == order[1] then
          stream[i] = 1
          break
        elseif order[2] ~= nil and s == order[2] then
          stream[i] = 0
          break
        end
      end
    end
  end

  local byte = 128
  local ref = stream[6]
  if stream[1] ~= ref then byte = byte + 1 end
  if stream[2] ~= ref then byte = byte + 2 end
  if stream[3] ~= ref then byte = byte + 4 end
  if stream[4] ~= ref then byte = byte + 8 end
  if stream[5] ~= ref then byte = byte + 16 end

  local state1, state2
  if order[2] ~= nil then
    if ref == 1 then
      state1, state2 = order[2], order[1]
    else
      state1, state2 = order[1], order[2]
    end
  else
    state1, state2 = order[1], order[1]
  end
  return string.char(byte), state1, state2
end

-- Build the padded module matrix (1-indexed) with a quiet zone.
local function padMatrix(qr, border)
  local size = qr.size
  local n = size + border * 2
  local m = {}
  for y = 0, n - 1 do
    local row = {}
    for x = 0, n - 1 do
      local sx, sy = x - border, y - border
      row[x + 1] = (sx >= 0 and sy >= 0 and sx < size and sy < size)
        and qr.modules[sy][sx] or false
    end
    m[y + 1] = row
  end
  return m, n
end

-- Encode `text` and return a Basalt bimg.  opts are passed to qrcode.encode()
-- (ecl / errorCorrectionLevel / level); opt.border sets the quiet zone.
function M.toBimg(text, opts)
  opts = opts or {}
  local border = opts.border
  if border == nil then border = 1 end

  local qr = qrcode.encode(text, opts)
  local m, w = padMatrix(qr, border)
  local h = w

  -- The packing eats 2 columns and 3 rows at a time.
  if w % 2 == 1 then
    for y = 1, h do m[y][w + 1] = false end
    w = w + 1
  end
  while h % 3 ~= 0 do
    h = h + 1
    local row = {}
    for x = 1, w do row[x] = false end
    m[h] = row
  end

  local rows = {}
  for y = 1, h, 3 do
    local text, fg, bg = {}, {}, {}
    local n = 0
    for x = 1, w, 2 do
      local t = {
        m[y][x] and 1 or 0,
        m[y][x + 1] and 1 or 0,
        m[y + 1][x] and 1 or 0,
        m[y + 1][x + 1] and 1 or 0,
        m[y + 2][x] and 1 or 0,
        m[y + 2][x + 1] and 1 or 0,
      }
      local glyph, s1, s2
      if t[1] == t[2] and t[2] == t[3] and t[3] == t[4]
        and t[4] == t[5] and t[5] == t[6] then
        glyph, s1, s2 = " ", t[1], t[1]
      else
        glyph, s1, s2 = calculateTexel(t)
      end
      n = n + 1
      text[n] = glyph
      fg[n] = s1 == 1 and "Q" or "B"
      bg[n] = s2 == 1 and "Q" or "B"
    end
    rows[#rows + 1] = { table.concat(text), table.concat(fg), table.concat(bg) }
  end

  return { rows }
end

-- Pixel dimensions of the packed bimg (for layout decisions).
function M.sizeOf(text, opts)
  local bimg = M.toBimg(text, opts)
  local frame = bimg[1]
  return #frame[1][1], #frame
end

return M
