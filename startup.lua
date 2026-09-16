-- startup.lua
-- CC-CloudMusicNCM entry point.
--
-- Run this from the project root (the directory that contains Lib/ and icons/)
-- because Basalt, utf8display and the icon bitmaps are required with
-- require("Lib.basalt") / require("icons.Home").  The client also expects the
-- `ncm` library at /ncm.
--
-- The UI is drawn ONLY on an attached monitor; the computer's own terminal is
-- reserved for logs.  Every diagnostic is written through printNative() (in
-- ccncm/data.lua) so it lands on the computer screen while Basalt paints the
-- monitor.  Without a monitor the client refuses to start rather than taking
-- over the computer terminal.  Everything is wrapped in pcall so a missing
-- library, a missing font or a broken terminal prints an ASCII error instead of
-- a Lua traceback.

package.path = "/?.lua;/?/init.lua;" .. package.path

-- printNative() saves the current redirection, prints through term.native(),
-- then restores the previous redirection.  It is shared with the app so there
-- is a single implementation (ccncm/data.lua).
local okData, data = pcall(require, "ccncm.data")
local printNative
if okData and type(data.printNative) == "function" then
  printNative = data.printNative
else
  printNative = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    local line = table.concat(parts, "\t")
    local previous = term.current()
    local ok = pcall(function()
      term.redirect(term.native())
      pcall(term.setTextColor, colors.white)
      pcall(term.setBackgroundColor, colors.black)
      print(line)
    end)
    pcall(term.redirect, previous)
    return ok
  end
end

-- A font/terminal failure can surface a Chinese error string (e.g. from
-- utf8display).  Without a CJK font that would render as garbage, so the
-- diagnostic must be forced back to ASCII.
local function asciiSafe(text)
  return (tostring(text or ""):gsub("[\128-\255]", "?"))
end

-- Reset the computer's own terminal to a known state (black background, white
-- text, cursor at 1,1).  Never touches the monitor.
local function resetNative()
  pcall(function()
    local native = term.native()
    native.setBackgroundColor(colors.black)
    native.setTextColor(colors.white)
    native.clear()
    native.setCursorPos(1, 1)
  end)
end

local function fail(msg)
  resetNative()
  printNative("CC-CloudMusicNCM - cannot start")
  printNative(asciiSafe(msg))
  printNative("")
  printNative("Prerequisites:")
  printNative("  - A monitor block attached to this computer")
  printNative("  - Advanced computer with HTTP enabled")
  printNative("  - the ncm library installed at /ncm (require \"ncm\")")
  printNative("  - a CJK font: /ccncm_font.lua, or network access to the")
  printNative("    default remote font used by Lib/utf8display.lua")
  printNative("See README.md for installation instructions.")
end

-- ---------------------------------------------------------------------------
-- Monitor detection: this is a HARD requirement.
-- ---------------------------------------------------------------------------

local monitor
if peripheral and type(peripheral.find) == "function" then
  monitor = peripheral.find("monitor")
end

if not monitor then
  resetNative()
  printNative("CC-CloudMusicNCM requires a monitor. Place a monitor block next to this computer and restart. Recommended: 3x2 blocks (2x2 minimum).")
  return
end

-- The layout targets 51x19, so scale 1 is far too coarse on a monitor.  Warn on
-- the native terminal if the wall is too small, but still run.
pcall(function() monitor.setTextScale(0.5) end)
local mw, mh = 0, 0
if type(monitor.getSize) == "function" then
  local okSize, w, h = pcall(monitor.getSize)
  if okSize then
    mw, mh = tonumber(w) or 0, tonumber(h) or 0
  end
end
if mw < 51 or mh < 19 then
  printNative(string.format(
    "warning: monitor is %dx%d but the layout needs 51x19. Recommended: 3x2 blocks (2x2 minimum). Continuing.",
    mw, mh))
end

-- Bind the UI to the monitor.  term.redirect(monitor) makes term.current() the
-- monitor, so Basalt's main frame (created lazily by getMainFrame() during
-- app.build) binds to it.  The reference client instead creates a second frame
-- and sets frame.term = monitor, but this client builds everything on
-- basalt.getMainFrame(), so a single redirect is the smaller, safer change; the
-- printNative() helper keeps every log line on the computer terminal regardless.
if not pcall(function() term.redirect(monitor) end) then
  fail("cannot redirect the terminal to the monitor")
  return
end

-- ---------------------------------------------------------------------------
-- Build and run
-- ---------------------------------------------------------------------------

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

-- app.run() blocks in Basalt's event loop until the user stops it (Ctrl+T makes
-- Basalt.stop() clear the terminal it was drawing on).  Hand the terminal back
-- to the computer afterwards so the shell prompt is not stranded on the monitor.
local okRun, runErr = pcall(app.run)
pcall(function() term.redirect(term.native()) end)
resetNative()
if not okRun then
  fail(runErr)
end
