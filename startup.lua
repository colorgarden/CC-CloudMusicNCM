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

-- Optional: draw on an attached monitor instead of the computer's own screen.
-- Basalt needs a colour terminal with graphics support, which a monitor may or
-- may not provide, so this is attempted defensively and reverted on failure.
local monitor
if peripheral and type(peripheral.find) == "function" then
  monitor = peripheral.find("monitor")
end
if monitor then
  -- The layout is 51x19, so scale 1 is far too coarse on a monitor.
  pcall(function() monitor.setTextScale(0.5) end)
  if not pcall(function() term.redirect(monitor) end) then
    monitor = nil
  else
    print("Rendering on the attached monitor.")
  end
end

local okApp, app = pcall(require, "ccncm.app")
if not okApp then
  fail(app)
  return
end

local okBuild, built, buildErr = pcall(app.build)
if (not okBuild or built == false or built == nil) and monitor then
  -- The monitor could not host the UI (Basalt wants a colour graphics
  -- terminal). Fall back to the computer's own screen and try once more.
  pcall(function() term.redirect(term.native()) end)
  monitor = nil
  okBuild, built, buildErr = pcall(app.build)
end
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
