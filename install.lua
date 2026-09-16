--[[
  install.lua - one-click installer for CC-CloudMusicNCM, a CC:Tweaked
  NetEase Cloud Music client (Basalt UI + utf8display CJK bitmaps).

  What it does
    0. checks that the `ncm` library is installed at /ncm; when it is missing,
       offers to download and run the library installer through the ghproxy
       mirror and, once /ncm/init.lua exists, continues automatically,
    1. installs the shared Basalt UI framework ONCE on the internal disk at
       /Lib/basalt.lua (stage A).  If it is already there the download is
       skipped; if it cannot fit, the client stage never runs,
    2. picks a client install root: the internal disk by default, or a disk
       drive / mounted filesystem with room for the client archive, offered
       once (see Storage),
    3. removes any previous <root>ccncm install,
    4. downloads dist/ccncm.tar fully into memory, measures what it needs,
       checks free space on the chosen root against that measured figure, and
       only then extracts it (uncompressed USTAR - no gzip library or temp file),
    5. verifies the files that the client's startup.lua requires.

  Failure reporting
    Every step prints a start line before it runs. Every fatal path goes
    through failStep(), which prints WHAT step failed, WHICH url/path it
    involved, the EXACT error text (including any HTTP status the response
    carried) and WHAT to try, then aborts. Mirrors are tried in turn and a
    failure prints that mirror's url, its reason and "trying the next
    mirror"; when every mirror fails one block lists each url and its error.

  Layout (the client bundle's entries are already rooted at `ccncm/`):

      /Lib/basalt.lua           shared Basalt UI framework (once, internal)
      /ccncm/startup.lua        entry point
      /ccncm/ccncm/*.lua        Basalt UI, data layer, strings
      /ccncm/Lib/utf8display.lua  CJK dot-matrix renderer
      /ccncm/icons/*.lua        icon bitmaps
      /ccncm/LICENSE

  Basalt is ~330 KB and is by far the largest dependency, so it is installed
  once at the absolute path /Lib/basalt.lua and shared.  startup.lua already
  sets package.path = "/?.lua;/?/init.lua;" .. package.path, so
  require("Lib.basalt") matches /Lib/basalt.lua with no client change; that is
  also why the small client may live on a disk drive or a mounted filesystem.

  The root matters: startup.lua uses require("Lib.basalt"), require("ccncm.app")
  and require("icons.Home"), which CraftOS resolves relative to the running
  program's directory (with the absolute patterns above checked first). So the
  client must be launched as `ccncm/startup` from the directory that contains
  `ccncm/` (by default `/`).

  Requirements
    * An Advanced Computer (or Command Computer) with the HTTP API enabled.
    * The `ncm` library at /ncm (this installer can fetch it for you).
    * The server must allow the chosen mirror host in its http whitelist.

  Usage
    wget run https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main/install.lua
    -- the installer then shows an interactive download-source menu
    -- (jsDelivr / GitHub raw / ghproxy.net / custom URL);
    -- pass a bundle base URL as the first argument to skip the menu:
    wget run <url> https://my.mirror/ccncm

    -- a second argument fixes the client install root and skips the disk
    -- prompt (a trailing slash is optional and normalised):
    wget run <url> https://my.mirror/ccncm /disk

  Storage
    The client is installed under `<root>ccncm`, where `<root>` is the
    internal disk (`/`) by default. Before writing anything, the installer
    probes for filesystems that have room for the measured client archive:
      * disk drives reported by `peripheral.find("drive")` /
        `peripheral.find("disk drive")`,
      * the conventional mount points `/disk`, `/disk2` ... `/disk9`,
      * any other directory whose `fs.getFreeSpace` differs from `/`'s - the
        way the ROM's `mount` program attaches a directory as storage.
    Each existing candidate is listed with its free space; if one fits, the
    installer asks once (default NO) and otherwise falls back to the internal
    disk, whose normal computed free-vs-needed check then decides. No drive
    names, capacities or mount paths are assumed anywhere. Basalt always goes
    to the internal disk and is never installed on a removable drive.
]]

local CONFIG = {
  -- Where the dist/ archives are served from (overridable by argv[1]).
  base = "https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main",
  -- Where ccncm/ is installed (must end with "/").
  root = "/",
  -- Client bundle path relative to the base URL.
  bundle = "dist/ccncm.tar",
  -- Shared Basalt framework bundle path relative to the base URL.
  libBundle = "dist/ccncm-lib.tar",
}

-- The shared framework always lives here (absolute), and the lib bundle roots
-- its single entry at Lib/ so extracting at "/" lands exactly this path.
local BASALT_PATH = "/Lib/basalt.lua"
local BASALT_ENTRY = "Lib/basalt.lua"

local args = { ... }

-- ------------------------------------------------------------------- log file
-- Every line this installer prints is also appended, one line at a time, to a
-- log file on the computer's internal disk. Writing it immediately (rather than
-- buffering and dumping at the end) means that if the machine runs out of
-- memory mid-install, everything up to the last completed line is already on
-- disk and can be read back after the screen has scrolled away.
--
-- Opening is best-effort: a read-only or absent disk must not stop the install,
-- so a failure only prints one warning and turns logging off.
local LOG_PATH = "/ccncm-install.log"
local logFile
do
  local ok, f = pcall(fs.open, LOG_PATH, "a")
  if ok and f ~= nil then
    logFile = f
  else
    print("warning: cannot write " .. LOG_PATH .. "; continuing without a log file")
  end
end

-- The single place every screen line goes through: print it, then append the
-- exact same text to the log. A failed append disables logging instead of
-- aborting. `print` is used (not write) so the installer's own output is
-- unchanged.
local function emit(text)
  local s = tostring(text)
  print(s)
  if logFile then
    local ok = pcall(function() logFile.write(s .. "\n") end)
    if not ok then logFile = nil end
  end
end

-- One header line per run so several runs in the same appended file are easy to
-- tell apart. UTC and ASCII only.
local function runHeader()
  local stamp = "?"
  local okd, d = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
  if okd and type(d) == "string" then stamp = d end
  local id = "?"
  local okc, c = pcall(os.getComputerID)
  if okc then id = tostring(c) end
  local argv = {}
  for i = 1, #args do argv[i] = tostring(args[i]) end
  emit(("=== run %s args=%s computer=%s ==="):format(
    stamp, #argv > 0 and table.concat(argv, " ") or "(none)", id))
end

runHeader()

-- --------------------------------------------------------------- failure report
-- One structured reporter for every fatal path. The block is ASCII-only and
-- delimited so it is easy to spot and easy to copy out of the terminal.
local REPORT_WIDTH = 66

-- Print `prefix` followed by `text`, word-wrapped so continuation lines line
-- up under the text column. ASCII only.
local function reportFill(prefix, text)
  local line = prefix
  local started = false
  for word in tostring(text):gmatch("%S+") do
    if not started then
      line = line .. word
      started = true
    elseif #line + 1 + #word <= REPORT_WIDTH then
      line = line .. " " .. word
    else
      emit(line)
      line = string.rep(" ", #prefix) .. word
    end
  end
  if started then emit(line) end
end

-- Turn an http.get failure into a reason string. http.get returns
-- `nil, err, failingResponse`; when the third value is present its
-- getResponseCode()/getResponseMessage() carry the HTTP status and message.
local function httpReason(err, response)
  local reason = tostring(err)
  if type(response) == "table" then
    local code, message
    if type(response.getResponseCode) == "function" then
      local ok, c = pcall(response.getResponseCode)
      if ok then code = c end
    end
    if type(response.getResponseMessage) == "function" then
      local ok, m = pcall(response.getResponseMessage)
      if ok then message = m end
    end
    if code ~= nil or message ~= nil then
      reason = reason .. " (HTTP " .. tostring(code or "?")
        .. (message ~= nil and (" " .. tostring(message)) or "") .. ")"
    end
  end
  return reason
end

-- Read the status off a live response handle. A mirror may answer with a
-- non-nil handle and an error status; that must be reported too.
local function responseStatus(handle)
  if type(handle) ~= "table" or type(handle.getResponseCode) ~= "function" then
    return nil, nil
  end
  local ok, code = pcall(handle.getResponseCode)
  if not ok or type(code) ~= "number" then return nil, nil end
  local message
  if type(handle.getResponseMessage) == "function" then
    local okm, m = pcall(handle.getResponseMessage)
    if okm then message = m end
  end
  return code, message
end

-- The single fatal reporter. `details` is an optional array of extra lines
-- (used to list every failed mirror). Aborts with the reason text, level 0 so
-- no Lua traceback is printed.
local function failStep(step, source, reason, hint, details)
  emit(string.rep("-", REPORT_WIDTH))
  emit("INSTALL FAILED")
  emit("  step   : " .. tostring(step))
  if source and source ~= "" then emit("  source : " .. tostring(source)) end
  reportFill("  reason : ", reason)
  if details then
    for _, d in ipairs(details) do reportFill("           ", d) end
  end
  if hint and hint ~= "" then reportFill("  try    : ", hint) end
  emit(string.rep("-", REPORT_WIDTH))
  -- The exact text error() is about to raise, so the log ends with it too.
  emit(tostring(reason))
  if logFile then emit("log written to " .. LOG_PATH) end
  error(tostring(reason), 0)
end

-- Each discrete step prints one start line before it runs.
local function stepStart(name)
  emit("Step: " .. name)
end

-- Report that every mirror failed, listing each url and its own error.
local function mirrorFailure(step, what, errors)
  local details = {}
  for i, e in ipairs(errors) do
    details[#details + 1] = ("mirror %d: %s"):format(i, e.url)
    details[#details + 1] = ("error: %s"):format(e.reason)
  end
  failStep(step, "all mirrors for " .. what,
    ("could not obtain %s from any of the %d mirrors"):format(what, #errors),
    "check the computer's network and http whitelist, then retry; the source menu lists each host",
    details)
end

-- Optional argv[2]: an explicit client install root. When present, disk
-- detection and the interactive prompt are skipped. A trailing slash is
-- optional; it is normalised here so the rest of the installer can always
-- append "ccncm".
stepStart("read config and arguments")
local explicitRoot
local cfgOk, cfgErr = pcall(function()
  if args[2] and args[2] ~= "" then
    explicitRoot = args[2]
    if explicitRoot:sub(1, 1) ~= "/" then explicitRoot = "/" .. explicitRoot end
    if explicitRoot:sub(-1) ~= "/" then explicitRoot = explicitRoot .. "/" end
  end
end)
if not cfgOk then
  failStep("read config and arguments", "argv[2]", tostring(cfgErr),
    "pass an absolute install root such as /disk, or omit the second argument")
end

-- The internal disk is the default and the fallback. Normalise CONFIG.root the
-- same way so installRoot always ends with "/".
local internalRoot = CONFIG.root
if internalRoot:sub(1, 1) ~= "/" then internalRoot = "/" .. internalRoot end
if internalRoot:sub(-1) ~= "/" then internalRoot = internalRoot .. "/" end

-- ---------------------------------------------------------------- ncm constants
-- The client's data layer is require("ncm"); without it nothing can run.
local NCM_INIT = "/ncm/init.lua"
local NCM_INSTALL_CMD = "wget run https://ghproxy.net/https://raw.githubusercontent.com/"
  .. "colorgarden/NeteaseCloudMusicApiLibCCT/main/install.lua "
  .. "https://ghproxy.net/https://raw.githubusercontent.com/"
  .. "colorgarden/NeteaseCloudMusicApiLibCCT/main"

-- The same URLs as NCM_INSTALL_CMD, split out so this installer can invoke wget
-- itself instead of only telling the user to. ghproxy is deliberate: it streams
-- the live raw files, whereas jsDelivr caches each file of an @main URL
-- separately and has served stale library bundles before. The base URL is passed
-- as argv[1] to the library installer so it too uses ghproxy for its bundle and
-- skips its own interactive source menu.
local LIB_INSTALL_URL = "https://ghproxy.net/https://raw.githubusercontent.com/"
  .. "colorgarden/NeteaseCloudMusicApiLibCCT/main/install.lua"
local LIB_BASE_URL = "https://ghproxy.net/https://raw.githubusercontent.com/"
  .. "colorgarden/NeteaseCloudMusicApiLibCCT/main"

-- ----------------------------------------------------------------- utilities
local function log(fmt, ...)
  if select("#", ...) > 0 then emit(fmt:format(...)) else emit(fmt) end
end

-- Byte-count sanity: when the response carried Content-Length, the received
-- byte count must match it. When it did not, say so rather than staying
-- silent so the operator knows the download was unverifiable.
local function noteByteCount(got, total)
  if total and total > 0 then
    log("  received %d bytes (Content-Length: %d)", got, total)
  else
    log("  received %d bytes (no Content-Length header)", got)
  end
end

local function byteMismatch(got, total)
  if total and total > 0 and got ~= total then
    return ("expected %d bytes, received %d"):format(total, got)
  end
  return nil
end

-- CC's fs API prepends "file:line: " to errors it raises; keep only the
-- filesystem's own message so the reported error is about the actual problem.
local function fsErrorText(err)
  return (tostring(err):gsub("^.-:%d+:%s*", "", 1))
end

local function mkdirp(dir)
  local parts = {}
  for seg in dir:gmatch("[^/]+") do parts[#parts + 1] = seg end
  local cur = dir:sub(1, 1) == "/" and "" or "."
  for i = 1, #parts do
    cur = cur .. "/" .. parts[i]
    if not fs.exists(cur) then fs.makeDir(cur) end
  end
end

local function dirname(p)
  return p:match("^(.*)/[^/]*$") or "."
end

local function rmrf(p)
  if not fs.exists(p) then return end
  if fs.isDir(p) then
    for _, f in ipairs(fs.list(p)) do rmrf(fs.combine(p, f)) end
    fs.delete(p)
  else
    fs.delete(p)
  end
end

-- ------------------------------------------------------------------ progress
-- One-line ASCII progress bar, redrawn in place on its own row.
--
-- Every write is clamped to width-1 columns: writing the bottom-right cell of
-- a terminal scrolls it, which would scroll the bar off the screen. On CC each
-- terminal write is expensive, so a redraw is throttled to PROGRESS_INTERVAL ms
-- (the first frame of a new label and the final 100% frame are always drawn).
local PROGRESS_INTERVAL = 250
local PROGRESS_BAR = 18

local lastDraw, lastLabel, progressRow = 0, nil, nil

local function humanBytes(n)
  if n >= 1024 * 1024 then return ("%.2f MB"):format(n / (1024 * 1024)) end
  if n >= 1024 then return ("%.2f KB"):format(n / 1024) end
  return tostring(n) .. " B"
end

-- label : "Download" / "Extract". total nil or 0 drops the bar and percentage
-- and prints just the label and detail (e.g. "Download 53.21 KB").
local function drawProgress(label, done, total, detail)
  local now = os.epoch("utc")
  local pct
  if total and total > 0 then
    pct = math.floor(done * 100 / total)
    if pct > 100 then pct = 100 end
  end
  local final = pct ~= nil and pct >= 100
  if label == lastLabel and not final and now - lastDraw < PROGRESS_INTERVAL then
    return false
  end
  if label ~= lastLabel then
    -- A new phase takes over the row the cursor is on now and keeps drawing
    -- there, so a bar never marches down the screen.
    progressRow = select(2, term.getCursorPos())
    lastLabel = label
    lastDraw = 0
  end
  lastDraw = now

  local text
  if pct then
    local filled = math.floor(pct * PROGRESS_BAR / 100)
    if filled > PROGRESS_BAR then filled = PROGRESS_BAR end
    local bar = string.rep("#", filled) .. string.rep("-", PROGRESS_BAR - filled)
    text = ("%-8s [%s] %3d%%  %s"):format(label, bar, pct, detail or "")
  else
    text = ("%s %s"):format(label, detail or "")
  end

  local w = select(1, term.getSize())
  if #text > w - 1 then text = text:sub(1, w - 1) end
  term.setCursorPos(1, progressRow)
  term.clearLine()
  write(text)
  return final == true
end

-- Erase the bar before normal output so no log line is glued to it, leaving
-- the cursor on the bar's own row for the next print.
local function finishProgress()
  if progressRow then
    -- Keep the completed bar on screen (a fast connection throttles the
    -- intermediate frames away) and move past it so the next log line does
    -- not overwrite it from column 1.
    local _, h = term.getSize()
    term.setCursorPos(1, math.min(progressRow + 1, h))
  end
  lastDraw, lastLabel, progressRow = 0, nil, nil
end

-- content-length from the response headers, matched case-insensitively. nil
-- when the server did not send one (the bar then shows the byte count only and
-- the completion line says the download was not verifiable).
local function contentLength(handle)
  if type(handle.getResponseHeaders) ~= "function" then return nil end
  local ok, headers = pcall(handle.getResponseHeaders)
  if not ok or type(headers) ~= "table" then return nil end
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == "content-length" then
      local n = tonumber(value)
      if n and n > 0 then return n end
    end
  end
  return nil
end

-- Read a single-response body in chunks, drawing the download bar as it
-- arrives, and return the whole body, the received byte count and the
-- advertised Content-Length (nil when the server sent none). CC:Tweaked's
-- read(n) blocks until n bytes or EOF and returns nil at EOF, so the bar
-- follows the network. CraftOS-PC's read(n) is a non-blocking readsome() that
-- can return "" once it has drained its buffer; the first empty read falls
-- back to readAll() (which blocks until the rest is buffered) so the installer
-- still terminates with the whole archive.
local DOWNLOAD_CHUNK = 32768

local function readBodyProgress(handle, label)
  local total = contentLength(handle)
  local out, got, drewFinal = {}, 0, false
  local function detail(n)
    if total and total > 0 then return humanBytes(n) end
    return humanBytes(n) .. " (no Content-Length)"
  end
  if type(handle.read) == "function" then
    while true do
      local chunk = handle.read(DOWNLOAD_CHUNK)
      if chunk == nil then break end
      if #chunk == 0 then
        if type(handle.readAll) == "function" then
          local rest = handle.readAll() or ""
          if #rest > 0 then
            out[#out + 1] = rest
            got = got + #rest
            drewFinal = drawProgress(label, got, total, detail(got))
          end
        end
        break
      end
      out[#out + 1] = chunk
      got = got + #chunk
      drewFinal = drawProgress(label, got, total, detail(got))
    end
  end
  if got == 0 and type(handle.readAll) == "function" then
    local body = handle.readAll() or ""
    if #body > 0 then
      drawProgress(label, #body, total, detail(#body))
      return body, #body, total
    end
  end
  if total and total > 0 and got >= total and not drewFinal then
    -- Guarantee a clean 100% frame even if the last draws were throttled.
    drawProgress(label, total, total, detail(total))
  elseif not drewFinal then
    -- A truncated body: draw the real byte count so the bar never claims 100%
    -- for a short read. The byte-count check reports the mismatch right after.
    lastDraw = 0
    drawProgress(label, got, total, detail(got))
  end
  return table.concat(out), got, total
end

-- ------------------------------------------------------------ storage probe
-- Look for a filesystem other than the internal disk that the client could be
-- installed onto (a disk drive or a directory the ROM mounted). Nothing here
-- assumes a capacity, a peripheral name or a mount path: every candidate is
-- discovered by probing and then filtered by the measured archive size.
--
-- Returns an array of { path = <absolute path>, free = <bytes> } in this order:
--   1. attached disk drives, from peripheral.find("drive"/"disk drive");
--   2. conventional mount points /disk, /disk2 ... /disk9;
--   3. any other directory under / (or one level deeper) whose reported free
--      space differs from its parent's - i.e. a separate filesystem.
-- Returns nil when the fs API cannot report free space at all, in which case
-- detection is skipped and the installer behaves exactly as before.
local MAX_MOUNT_DEPTH = 2

local function findStorageCandidates()
  if type(fs.getFreeSpace) ~= "function" then return nil end

  local seen, out = {}, {}

  local function freeSpace(path)
    local ok, free = pcall(fs.getFreeSpace, path)
    if ok and type(free) == "number" then return free end
    return nil
  end

  -- Only writable filesystems can hold the install, and this also drops the
  -- read-only ROM, whose free space reads as 0 and would otherwise look like a
  -- separate filesystem in step 3 below.
  local function isWritable(path)
    if type(fs.isReadOnly) ~= "function" then return true end
    local ok, ro = pcall(fs.isReadOnly, path)
    if ok then return not ro end
    return true
  end

  -- Normalise to an absolute path with no trailing slash, so the same
  -- filesystem discovered two ways (e.g. a drive's mount path and /disk) is
  -- recorded once.
  local function normalize(path)
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    while #path > 1 and path:sub(-1) == "/" do path = path:sub(1, -2) end
    return path
  end

  local function add(path)
    if type(path) ~= "string" or path == "" then return end
    path = normalize(path)
    if seen[path] then return end
    local free = freeSpace(path)
    if free and isWritable(path) then
      seen[path] = true
      out[#out + 1] = { path = path, free = free }
    end
  end

  -- The disk API is a global, but guard it: older builds and test shims may
  -- not provide it, and `peripheral.find` itself can be absent.
  local diskApi = rawget(_G, "disk")

  -- 1. Disk drives. `peripheral.find` returns every matching peripheral as a
  --    vararg, so collect the whole pcall result (element 1 is the ok flag).
  if peripheral and type(peripheral.find) == "function" then
    for _, kind in ipairs({ "drive", "disk drive" }) do
      local found = { pcall(peripheral.find, kind) }
      if found[1] then
        for i = 2, #found do
          local drive = found[i]
          local name
          if type(peripheral.getName) == "function" then
            local ok, n = pcall(peripheral.getName, drive)
            if ok then name = n end
          end
          if name == nil and type(drive) == "table" then name = drive.name end
          if name ~= nil and diskApi and type(diskApi.hasData) == "function" then
            local ok, has = pcall(diskApi.hasData, name)
            if ok and has and type(diskApi.getMountPath) == "function" then
              local okp, mount = pcall(diskApi.getMountPath, name)
              if okp and type(mount) == "string" then add(mount) end
            end
          end
        end
      end
    end
  end

  -- 2. Conventional mount points used by CC's disk API and by hand.
  for i = 1, 9 do
    local path = i == 1 and "/disk" or ("/disk" .. i)
    local ok, isDir = pcall(fs.isDir, path)
    if ok and isDir then add(path) end
  end

  -- 3. Generic mount discovery. A mounted filesystem shares /'s directory
  --    listing but reports its own free space, so compare each directory's
  --    free space with its parent's. Probe one level deeper for a mount nested
  --    in a plain directory; the depth limit stops any runaway recursion.
  local rootFree = freeSpace("/")
  local function probe(dir, depth, parentFree)
    if depth > MAX_MOUNT_DEPTH then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end
    for _, name in ipairs(entries) do
      local child = (dir == "/" and "" or dir) .. "/" .. name
      local okd, isDir = pcall(fs.isDir, child)
      if okd and isDir then
        local free = freeSpace(child)
        if free then
          if parentFree ~= nil and free ~= parentFree then add(child) end
          probe(child, depth + 1, free)
        end
      end
    end
  end
  if rootFree ~= nil then probe("/", 1, rootFree) end

  return out
end

-- Decide where to install the client, given the measured archive size. Returns
-- a root that always ends in "/" (the internal disk as a fallback). An explicit
-- argv[2] wins outright; otherwise the first candidate with enough free space
-- is offered once with a [y/N] prompt (default NO). Candidates that do not fit
-- are still printed, so the user can see why the internal disk was kept.
local function chooseStorage(needed)
  stepStart("choose storage target")
  if explicitRoot then
    pcall(mkdirp, explicitRoot)
    log("Using the install root from the command line: %s", explicitRoot)
    return explicitRoot
  end

  local candidates = findStorageCandidates()
  if not candidates or #candidates == 0 then return internalRoot end

  log("")
  log("Other storage found (the client needs about %d bytes):", needed)
  local fitPath, fitFree
  for _, c in ipairs(candidates) do
    local fits = c.free >= needed
    if fits and not fitPath then fitPath, fitFree = c.path, c.free end
    log(("  %-10s %d bytes free%s"):format(c.path, c.free, fits and "  (fits)" or ""))
  end
  log("")

  if not fitPath then
    log("None of those has enough room; using the internal disk instead.")
    log("")
    return internalRoot
  end

  write(("Install onto %s instead of the internal disk (%d bytes free)? [y/N] ")
    :format(fitPath, fitFree))
  local ans = read and read() or nil
  if type(ans) == "string" and ans:match("^[yY]") then
    local chosen = fitPath
    if chosen:sub(-1) ~= "/" then chosen = chosen .. "/" end
    log("Installing onto %s", chosen)
    return chosen
  end
  log("Keeping the internal disk.")
  return internalRoot
end

-- Plain single-response GET via the built-in http API, with a few retries.
-- The bundle is ~440 KB, far below the ~16 MiB single-response cap, so no
-- chunked/big-GET helper is needed. That helper is also wrong here: CDNs such
-- as jsDelivr force gzip on text responses and CraftOS decompresses the body,
-- which makes byte-range validation fail.
--
-- Returns `handle` on success, or `nil, err, failingResponse` so the caller
-- can report the HTTP status the response carried.
local function plainGet(url)
  if not http then
    return nil, "the HTTP API is unavailable (use an Advanced Computer and enable http)"
  end
  local lastErr, lastResp
  for _ = 1, 3 do
    local h, err, resp = http.get(url, nil, true)
    if h then return h end
    lastErr, lastResp = err, resp
    sleep(1)
  end
  return nil, lastErr, lastResp
end

-- CC:Tweaked charges every file its contents plus the length of its path (and a
-- little metadata), which the USTAR size fields do not include. This is a
-- per-entry allowance for that bookkeeping, NOT a size threshold: the byte
-- total itself is measured from the archive by measureTar(), never guessed.
local PER_ENTRY_OVERHEAD = 64

-- Decode the USTAR header fields the walks below need. A header is 512 bytes:
--   name     bytes   0.. 99
--   size     bytes 124..135  (11 octal digits followed by a NUL)
--   typeflag byte  156
--   prefix   bytes 345..499
-- All offsets above are 0-based; the sub() indices here are 1-based.
local function tarHeader(hdr)
  local name = hdr:sub(1, 100):match("^[^%z]*") or ""
  local size = tonumber((hdr:sub(125, 136):match("^[^%z]*") or "0"):gsub("%s", ""), 8) or 0
  local typeflag = hdr:sub(157, 157)
  local prefix = hdr:sub(346, 500):match("^[^%z]*") or ""
  local full = prefix ~= "" and (prefix .. "/" .. name) or name
  return name, full, size, typeflag
end

-- A valid USTAR archive starts with a header carrying the "ustar" magic.
local function tarMagicOk(body)
  return #body >= 512 and body:sub(258, 262) == "ustar"
end

-- Pass 1: measure an in-memory USTAR archive without writing anything.
--
-- USTAR stores each entry as a fixed 512-byte header block followed by its data
-- rounded up to a 512-byte boundary. This walks those blocks and sums the
-- declared sizes; the 512-byte headers and padding are skipped (they are the
-- container, not the payload). Every entry is counted too - including
-- directories - so the caller can add PER_ENTRY_OVERHEAD per entry.
local function measureTar(body)
  local total, entries, pos = 0, 0, 1
  while pos + 511 <= #body do
    local hdr = body:sub(pos, pos + 511)
    local name, _, size = tarHeader(hdr)
    if name == "" then break end -- end-of-archive marker
    total = total + size
    entries = entries + 1
    pos = pos + 512 + math.ceil(size / 512) * 512
  end
  return total, entries
end

-- Describe an archive for diagnostics: how many entries were found and the
-- first few entry names. Used when the body is not USTAR or an entry is
-- missing, so the operator can see what the server actually returned.
local function tarDiagnostics(body)
  local names, entries, pos = {}, 0, 1
  while pos + 511 <= #body do
    local hdr = body:sub(pos, pos + 511)
    local name, full, size = tarHeader(hdr)
    if name == "" then break end -- end-of-archive marker
    entries = entries + 1
    if #names < 4 then names[#names + 1] = full ~= "" and full or name end
    pos = pos + 512 + math.ceil(size / 512) * 512
  end
  return entries, names
end

-- True when the archive carries a regular-file entry whose full path is `want`.
-- Used to confirm a bundle really contains the framework/client entry before
-- anything is written to disk.
local function tarHasEntry(body, want)
  local pos = 1
  while pos + 511 <= #body do
    local hdr = body:sub(pos, pos + 511)
    local name, full, size, typeflag = tarHeader(hdr)
    if name == "" then break end -- end-of-archive marker
    if full == want and typeflag ~= "5" then return true end
    pos = pos + 512 + math.ceil(size / 512) * 512
  end
  return false
end

-- Sanity-check a downloaded archive before using it. Returns the entry count,
-- or nil plus a reason. On failure it prints what was found: the entry count,
-- the first few entry names and the body size.
local function checkTar(step, source, body, required)
  stepStart(step)
  local entries, names = tarDiagnostics(body)
  local found = ("found %d entries, body %d bytes"):format(entries, #body)
  if #names > 0 then found = found .. ", first entries: " .. table.concat(names, ", ") end

  if not tarMagicOk(body) or entries == 0 then
    log("  archive sanity: %s", found)
    return nil, "not a USTAR archive (" .. found .. ")"
  end
  if required and not tarHasEntry(body, required) then
    log("  archive sanity: %s", found)
    return nil, ("required entry %s is missing (%s)"):format(required, found)
  end
  log("  archive sanity: OK (%d entries, body %d bytes)", entries, #body)
  return entries
end

-- Pass 2: extract an in-memory USTAR archive under `root`. This is the same
-- walk measureTar() uses, and it runs only after the free-space check passes,
-- so nothing is written before the check. Each entry's work is wrapped in
-- pcall: an "out of space" or "read-only mount" error names the entry that
-- failed and the filesystem's own error text instead of a raw traceback.
local function extractTar(body, root, entries, step, source)
  local count, pos, done = 0, 1, 0
  while pos + 511 <= #body do
    local hdr = body:sub(pos, pos + 511)
    local name, full, size, typeflag = tarHeader(hdr)
    if name == "" then break end -- end-of-archive marker
    pos = pos + 512
    done = done + 1
    local ok, err = pcall(function()
      if typeflag == "5" then
        mkdirp((root .. full):gsub("/+$", ""))
      else
        mkdirp(dirname(root .. full))
        local f = fs.open(root .. full, "wb")
        if not f then error("cannot open " .. root .. full .. " for writing", 0) end
        f.write(body:sub(pos, pos + size - 1))
        f.close()
        count = count + 1
      end
    end)
    if not ok then
      finishProgress()
      local detail = ("entry %d/%d %q: %s"):format(done, entries or 0, full, fsErrorText(err))
      log("  %s", detail)
      failStep(step, source, detail,
        "the target filesystem is full or read-only; free space or choose another install root")
    end
    drawProgress("Extract", done, entries, ("%d/%d files"):format(done, entries or 0))
    pos = pos + math.ceil(size / 512) * 512
  end
  finishProgress()
  return count
end

-- Download one archive and sanity-check it. Returns body, entries on success,
-- or nil, reason on any per-mirror failure: connection error (with HTTP
-- status when the response carried one), non-2xx status, Content-Length
-- mismatch, a body that is not USTAR, or a missing required entry.
local function downloadArchive(url, label, required)
  local started = os.epoch("utc")
  local handle, gerr, gresp = plainGet(url)
  if not handle then
    local reason = httpReason(gerr, gresp)
    log("  GET %s -> no response after %d ms: %s", url, os.epoch("utc") - started, reason)
    return nil, reason
  end
  local code, message = responseStatus(handle)
  if code and code >= 400 then
    handle.close()
    log("  GET %s -> HTTP %s after %d ms", url, tostring(code), os.epoch("utc") - started)
    if message then return nil, ("HTTP %d %s"):format(code, tostring(message)) end
    return nil, ("HTTP %d"):format(code)
  end
  local body, got, total = readBodyProgress(handle, "Download")
  handle.close()
  finishProgress()
  log("  GET %s -> status %s, Content-Length %s, %d bytes received, %d ms",
    url, code and tostring(code) or "none",
    (total and total > 0) and tostring(total) or "none",
    got, os.epoch("utc") - started)
  stepStart("check byte count of " .. label)
  noteByteCount(got, total)
  local mismatch = byteMismatch(got, total)
  if mismatch then return nil, mismatch end
  local entries, tarErr = checkTar("check tar archive " .. label, url, body, required)
  if not entries then return nil, tarErr end
  return body, entries
end

-- True when the shared framework is present, either at the absolute shared
-- path or as a copy sitting next to the client. startup.lua's
-- package.path = "/?.lua;/?/init.lua;" .. ... makes require("Lib.basalt")
-- match /Lib/basalt.lua first, then the relative Lib/basalt.lua via the default
-- patterns, so either location works.
local function basaltAvailable(target)
  return fs.exists(BASALT_PATH) or fs.exists(target .. "/Lib/basalt.lua")
end

-- ---------------------------------------------------------------- ncm pre-check
-- Offer to install the library when it is missing, then fall through to the
-- client install once /ncm/init.lua exists. Declining leaves the computer
-- untouched (same behaviour as the older print-and-exit installer).
stepStart("check the ncm library")
if not fs.exists(NCM_INIT) then
  emit("CC-CloudMusicNCM installer: the ncm library is not installed.")
  emit("")
  emit("Expected to find " .. NCM_INIT .. " but it is missing.")
  emit("Install the library first by running this exact command on the computer:")
  emit("")
  emit(NCM_INSTALL_CMD)
  emit("")

  write("Download and run the ncm library installer now, using the ghproxy mirror? [y/N] ")
  local ans = read and read() or nil
  local yes = type(ans) == "string" and ans:match("^[yY]") ~= nil

  if not yes then
    emit("")
    emit("Not installing the ncm library. Run this exact command, then re-run this installer:")
    emit("")
    emit(NCM_INSTALL_CMD)
    return
  end

  local wget = shell and shell.resolveProgram and shell.resolveProgram("wget")
  if not wget then
    emit("")
    emit("Cannot find the `wget` program on this computer.")
    emit("Run this exact command manually, then re-run this installer:")
    emit("")
    emit(NCM_INSTALL_CMD)
    return
  end

  emit("")
  emit("Running the ncm library installer ...")
  local runOk, runErr = pcall(shell.run, "wget", "run", LIB_INSTALL_URL, LIB_BASE_URL)
  if not runOk then
    failStep("install the ncm library", LIB_INSTALL_URL, tostring(runErr),
      "run the library installer manually, then retry: " .. NCM_INSTALL_CMD)
  end

  if not fs.exists(NCM_INIT) then
    failStep("install the ncm library", LIB_INSTALL_URL,
      NCM_INIT .. " is still missing after the library installer ran",
      "run this exact command manually, then retry: " .. NCM_INSTALL_CMD)
  end
  emit("ncm library installed at /ncm; continuing with the client install.")
  emit("")
end

-- --------------------------------------------------------------- source pick
-- Interactive mirror menu, same style as the library installer. All three
-- mirrors serve the same repo; jsDelivr caches @main per file and has served
-- stale files before, which is why the menu exists. `args[1]` (when non-empty)
-- is a base URL and skips the menu, keeping the documented one-argument form
-- working.
local MIRRORS = {
  { name = "jsDelivr (recommended)", base = "https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main" },
  { name = "GitHub raw", base = "https://raw.githubusercontent.com/colorgarden/CC-CloudMusicNCM/main" },
  { name = "ghproxy.net (GitHub proxy)", base = "https://ghproxy.net/https://raw.githubusercontent.com/colorgarden/CC-CloudMusicNCM/main" },
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Reads one line; returns "" when the input stream is closed (non-interactive).
local function ask(prompt)
  if prompt then write(prompt) end
  local ans = read and read() or nil
  if ans == nil then return "" end
  return trim(ans)
end

-- Interactive menu unless a base URL was given on the command line:
--   install.lua [baseUrl]
local function pickSource()
  if args[1] and args[1] ~= "" then
    CONFIG.base = args[1]:gsub("/+$", "")
    emit("Using command-line source: " .. CONFIG.base)
    return
  end

  stepStart("select download source")
  emit("Choose a download source:")
  for i, m in ipairs(MIRRORS) do emit(("  %d) %s"):format(i, m.name)) end
  emit(("  %d) Custom URL"):format(#MIRRORS + 1))

  local n = tonumber(ask("Select [1]: ")) or 1
  if n >= 1 and n <= #MIRRORS then
    CONFIG.base = MIRRORS[n].base
    emit("Selected: " .. MIRRORS[n].name)
  elseif n == #MIRRORS + 1 then
    local u = ask("Bundle base URL (the dir containing dist/): ")
    if u ~= "" then CONFIG.base = u:gsub("/+$", "") end
    emit("Using custom source")
  else
    CONFIG.base = MIRRORS[1].base
    emit("Invalid input, using default: " .. MIRRORS[1].name)
  end
  emit("Selected base URL: " .. CONFIG.base)
end

local pickOk, pickErr = pcall(pickSource)
if not pickOk then
  failStep("select download source", "argv",
    tostring(pickErr),
    "pass a valid bundle base URL as the first argument, or run without arguments for the menu")
end

-- ------------------------------------------------------------- stage A: Basalt
-- Install the shared Basalt UI framework once, on the internal disk only.
--
-- Basalt is the single biggest file the client needs (~330 KB of the ~415 KB
-- client), so keeping it out of the client bundle is what lets the client fit
-- on a 125 KB floppy or a disk drive. It is idempotent: when /Lib/basalt.lua
-- already exists (and is non-empty) the download is skipped entirely, and
-- nothing fancier than existence plus that sanity check is compared. If the
-- framework cannot fit, the client stage must not run.
local function installBasalt(sources)
  stepStart("install shared Basalt UI framework")
  log("[1/5] Shared Basalt UI framework at %s ...", BASALT_PATH)

  if fs.exists(BASALT_PATH) then
    local size
    if type(fs.getSize) == "function" then
      local ok, sz = pcall(fs.getSize, BASALT_PATH)
      if ok and type(sz) == "number" then size = sz end
    end
    if size == nil or size > 0 then
      log("  already present%s; not downloading it again.",
        size and (" (" .. size .. " bytes)") or "")
      return
    end
    log("  found an empty %s; reinstalling it.", BASALT_PATH)
  end

  local body, entries, source
  local mirrorErrors = {}
  for i = 1, #sources do
    local url = sources[i] .. "/" .. CONFIG.libBundle
    stepStart(("download shared Basalt bundle (mirror %d/%d)"):format(i, #sources))
    log("  url: %s", url)
    local b, info = downloadArchive(url, CONFIG.libBundle, BASALT_ENTRY)
    if b then
      body, entries, source = b, info, url
      break
    end
    log("  mirror failed: %s", url)
    log("  reason: %s", info)
    log("  trying the next mirror ...")
    mirrorErrors[#mirrorErrors + 1] = { url = url, reason = info }
  end
  if not body then
    mirrorFailure("download " .. CONFIG.libBundle, CONFIG.libBundle, mirrorErrors)
  end

  local totalBytes = measureTar(body)
  local needed = totalBytes + entries * PER_ENTRY_OVERHEAD
  log("  archive: %d entries, %d bytes (needs about %d with per-file overhead)",
    entries, totalBytes, needed)

  stepStart("check free space for the shared framework")
  if type(fs.getFreeSpace) == "function" then
    local okf, free = pcall(fs.getFreeSpace, internalRoot)
    if not okf then
      failStep("check free space", internalRoot, tostring(free),
        "the filesystem cannot report free space; check the computer's disk")
    end
    log("  free %d bytes, needed %d bytes (%d entries)", free, needed, entries)
    if free < needed then
      failStep("check free space", internalRoot,
        ("not enough disk space for the shared framework: %d bytes free, this archive "
          .. "needs about %d bytes (%d entries)"):format(free, needed, entries),
        "delete files on the computer, or raise computer_space_limit in "
          .. "config/computercraft-server.toml (then restart the world), and retry")
    end
  end

  stepStart("extract " .. CONFIG.libBundle)
  local files = extractTar(body, internalRoot, entries, "extract " .. CONFIG.libBundle, source)
  log("  extracted %d files", files)
  if not fs.exists(BASALT_PATH) then
    failStep("verify shared framework", BASALT_PATH,
      BASALT_PATH .. " is missing after extraction",
      "re-run the installer and pick another mirror")
  end
end

-- -------------------------------------------------------------- stage B: client
-- Download each candidate client bundle into memory, measure the archive that
-- was just downloaded, pick the install root from the measured size, check that
-- the bundle fits there, and only then extract it. The size MUST come from the
-- archive itself: a hardcoded byte count goes stale as soon as the bundle
-- changes, and it cannot account for CC charging disk per file.
local function installClient(sources)
  stepStart("download and measure the client bundle")
  log("[2/5] Downloading and measuring the client bundle ...")
  local installed = false
  local installRoot, installTarget, removedPrev
  local mirrorErrors = {}
  for i = 1, #sources do
    local url = sources[i] .. "/" .. CONFIG.bundle
    stepStart(("download client bundle (mirror %d/%d)"):format(i, #sources))
    log("  url: %s", url)

    local body, info = downloadArchive(url, CONFIG.bundle, "ccncm/startup.lua")
    if not body then
      log("  mirror failed: %s", url)
      log("  reason: %s", info)
      log("  trying the next mirror ...")
      mirrorErrors[#mirrorErrors + 1] = { url = url, reason = info }
    else
      local entries = info
      -- Buffer the whole archive, then measure it BEFORE writing a single byte.
      local totalBytes = measureTar(body)
      local needed = totalBytes + entries * PER_ENTRY_OVERHEAD
      log("  archive: %d entries, %d bytes (needs about %d with per-file overhead)",
        entries, totalBytes, needed)

      -- Pick the target once we know how much room the archive needs. The choice
      -- is remembered so a mirror retry never asks again.
      if not installRoot then
        installRoot = chooseStorage(needed)
        installTarget = installRoot .. "ccncm"
        log("  target : %s", installTarget)
      end

      -- Remove any previous install of the chosen target so re-running is
      -- idempotent. Only <target>ccncm is ever touched; the shared
      -- /Lib/basalt.lua is never removed.
      if not removedPrev then
        stepStart("remove previous client install")
        local rok, rerr = pcall(rmrf, installTarget)
        if not rok then
          failStep("remove previous client install", installTarget, tostring(rerr),
            "close any program using it and check that the mount is writable")
        end
        removedPrev = true
      end

      stepStart("check free space for the client")
      if type(fs.getFreeSpace) == "function" then
        local okf, free = pcall(fs.getFreeSpace, installRoot)
        if not okf then
          failStep("check free space", installRoot, tostring(free),
            "the filesystem cannot report free space; check the computer's disk")
        end
        log("  free %d bytes, needed %d bytes (%d entries)", free, needed, entries)
        if free < needed then
          local hint = "delete files on the computer, or raise computer_space_limit in "
            .. "config/computercraft-server.toml (then restart the world), and retry"
          if installRoot ~= internalRoot then
            hint = "free space on " .. installRoot .. ", or let the installer keep the internal disk"
          end
          failStep("check free space", installRoot,
            ("not enough disk space: %d bytes free, this archive needs about %d bytes (%d entries)")
              :format(free, needed, entries),
            hint)
        end
      end

      stepStart("extract " .. CONFIG.bundle)
      local files = extractTar(body, installRoot, entries, "extract " .. CONFIG.bundle, url)
      log("  extracted %d files", files)

      if fs.exists(installTarget .. "/startup.lua")
        and fs.exists(installTarget .. "/Lib/utf8display.lua")
        and fs.exists(installTarget .. "/icons/Home.lua")
        and basaltAvailable(installTarget) then
        installed = true
        if i > 1 then log("  note: the chosen source failed; using another mirror") end
        break
      end
      log("  mirror failed: %s", url)
      log("  reason: archive extracted but required client files are missing")
      log("  trying the next mirror ...")
      mirrorErrors[#mirrorErrors + 1] = {
        url = url, reason = "archive extracted but required client files are missing",
      }
      pcall(rmrf, installTarget)
    end
  end
  if not installed then
    mirrorFailure("download client bundle", CONFIG.bundle, mirrorErrors)
  end

  -- Verify the files startup.lua loads and print the run instruction.
  stepStart("verify installed files")
  log("[4/5] Verifying ...")
  local checks = {
    "startup.lua",
    "Lib/utf8display.lua",
    "icons/Home.lua",
  }
  local missing = {}
  for _, rel in ipairs(checks) do
    local ok = fs.exists(installTarget .. "/" .. rel)
    log("  %s %s", ok and "OK  " or "MISS", rel)
    if not ok then missing[#missing + 1] = rel end
  end
  local basaltOk = basaltAvailable(installTarget)
  log("  %s %s", basaltOk and "OK  " or "MISS",
    "Lib/basalt.lua (shared at " .. BASALT_PATH .. ")")
  if not basaltOk then missing[#missing + 1] = "Lib/basalt.lua" end
  if #missing > 0 then
    failStep("verify installed files", installTarget,
      "missing: " .. table.concat(missing, ", "),
      "re-run the installer; if it repeats, delete " .. installTarget .. " and retry")
  end

  -- The run command is relative to / so it works from the default shell prompt.
  -- Requires are resolved relative to the program's own directory, so the client
  -- must always be launched by a path that reaches it.
  local runPrefix = installRoot == "/" and "" or installRoot:sub(2)
  local runCmd = runPrefix .. "ccncm/startup"

  log("")
  log("[5/5] Done. CC-CloudMusicNCM is installed.")
  log("  shared framework: %s", BASALT_PATH)
  log("  client          : %s", installTarget)
  log("Run it as:")
  log("  %s", runCmd)
  log("from the shell prompt in / (the command path is relative to /).")
  log("Its requires resolve relative to the program directory, so launch it by")
  log("this path (or a full path to %s/startup.lua).", installTarget)
end

-- --------------------------------------------------------------------- main
log("CC-CloudMusicNCM installer for CC:Tweaked")
log("  lib bundle    : %s/%s", CONFIG.base, CONFIG.libBundle)
log("  client bundle : %s/%s", CONFIG.base, CONFIG.bundle)

-- Every known mirror is tried in turn for both bundles; the selected source is
-- first, then the others as fallbacks.
local sources = { CONFIG.base }
for _, m in ipairs(MIRRORS) do
  if m.base ~= CONFIG.base then sources[#sources + 1] = m.base end
end

installBasalt(sources)
installClient(sources)

if logFile then logFile.close() end
