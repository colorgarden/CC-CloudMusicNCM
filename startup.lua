-- startup.lua
-- CC-CloudMusicNCM entry point.
--
-- Run this from the project root (the directory that contains Lib/ and icons/)
-- because Basalt, utf8display and the icon bitmaps are required with
-- require("Lib.basalt") / require("icons.Home").  The client also expects the
-- `ncm` library at /ncm.
--
-- Everything is wrapped in pcall so a missing library, a missing font or a
-- broken terminal prints an ASCII error instead of a Lua traceback.

package.path = "/?.lua;/?/init.lua;" .. package.path

local function fail(msg)
  pcall(function()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
  end)
  print("CC-CloudMusicNCM - cannot start")
  print(tostring(msg))
  print("")
  print("Prerequisites:")
  print("  - Advanced computer with HTTP enabled")
  print("  - the ncm library installed at /ncm (require \"ncm\")")
  print("  - a CJK font: /ccncm_font.lua, or network access to the")
  print("    default remote font used by Lib/utf8display.lua")
  print("See README.md for installation instructions.")
end

local okApp, app = pcall(require, "ccncm.app")
if not okApp then
  fail(app)
  return
end

local okBuild, built, buildErr = pcall(app.build)
if not okBuild then
  fail(built)
  return
end
if built == false or built == nil then
  fail(buildErr or "unknown build error")
  return
end

-- app.run() blocks in Basalt's event loop until the user stops it.
local okRun, runErr = pcall(app.run)
if not okRun then
  fail(runErr)
end
