-- ccncm/bimg.lua
-- Small helpers around Lib/utf8display's bimg format.
--
-- A bimg is {{ {text, fg, bg}, ... }}: one inner table per terminal row, each
-- row a byte string plus two equally long colour strings.  Basalt's
-- drawContent() understands "Q" as "element foreground" and "B" as "element
-- background", which is what the reference client used and what lets a row
-- react to hover/selected colours.

local utf8display = require("Lib.utf8display")

local M = {}

M.utf8display = utf8display

-- Pad a per-character colour string to at least `len` characters by repeating
-- its last character (utf8display silently falls back otherwise).
local function padColor(colorStr, len)
  if type(colorStr) ~= "string" or #colorStr == 0 then return colorStr end
  if #colorStr >= len then return colorStr end
  return colorStr .. string.rep(colorStr:sub(-1), len - #colorStr)
end

-- Convert a UTF-8 string into a bimg suitable for Basalt setImage().
-- fg / bg are colour-code strings: "Q" = element foreground, "B" = element
-- background, or literal blit codes ("f", "0", ...).  Chinese text is passed
-- through untouched; only its bytes are consumed by the font.
function M.ProcessStrToBimg(text, fgColor, bgColor)
  text = tostring(text or "")
  local textLen = utf8display and (utf8.len and utf8.len(text)) or #text
  if not textLen then textLen = #text end
  local fg = padColor(fgColor, textLen)
  local bg = padColor(bgColor, textLen)
  return utf8display.strToBimg(text, fg, bg)
end

-- A bimg may be "framed" ({{rows}}) as produced by strToBimg, or a bare list
-- of rows as the icon files are written.  Normalise to the framed form.
function M.asFramed(x)
  if type(x) ~= "table" then return { { { "", "", "" } } } end
  if type(x[1]) == "table" and type(x[1][1]) == "table" then return x end
  return { x }
end

-- Horizontally concatenate two bimg frames (same height).
function M.ConcatBimg(a, b)
  a = M.asFramed(a)
  b = M.asFramed(b)
  local result = {}
  for i = 1, #a do
    result[i] = {}
    for j = 1, #a[i] do
      result[i][j] = {}
      for k = 1, #a[i][j] do
        result[i][j][k] = a[i][j][k] .. b[i][j][k]
      end
    end
  end
  return result
end

-- Width (in terminal cells) of a bimg frame.
function M.widthOf(bimg)
  local frame = M.asFramed(bimg)[1]
  local w = 0
  for _, row in ipairs(frame) do
    if #row[1] > w then w = #row[1] end
  end
  return w
end

-- Height (in terminal rows) of a bimg frame.
function M.heightOf(bimg)
  return #M.asFramed(bimg)[1]
end

-- The font's cell height, measured from a single rendered glyph.  Used to
-- size list rows without hard-coding the font metrics.
function M.glyphHeight()
  local ok, bimg = pcall(M.ProcessStrToBimg, "A", "Q", "B")
  if not ok or type(bimg) ~= "table" then return 3 end
  local h = M.heightOf(bimg)
  if h < 1 then h = 3 end
  return h
end

return M
