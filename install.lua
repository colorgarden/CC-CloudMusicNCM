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

-- Optional argv[2]: an explicit client install root. When present, disk
-- detection and the interactive prompt are skipped. A trailing slash is
-- optional; it is normalised here so the rest of the installer can always
-- append "ccncm".
local explicitRoot
if args[2] and args[2] ~= "" then
  explicitRoot = args[2]
  if explicitRoot:sub(1, 1) ~= "/" then explicitRoot = "/" .. explicitRoot end
  if explicitRoot:sub(-1) ~= "/" then explicitRoot = explicitRoot .. "/" end
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
  if select("#", ...) > 0 then print(fmt:format(...)) else print(fmt) end
end

local function die(msg)
  printError("install: " .. msg)
  error(msg, 0)
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
    term.setCursorPos(1, progressRow)
    term.clearLine()
  end
  lastDraw, lastLabel, progressRow = 0, nil, nil
end

-- content-length from the response headers, matched case-insensitively. nil
-- when the server did not send one (the bar then shows the byte count only).
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
-- arrives, and return the whole body. CC:Tweaked's read(n) blocks until n
-- bytes or EOF and returns nil at EOF, so the bar follows the network.
-- CraftOS-PC's read(n) is a non-blocking readsome() that can return "" once it
-- has drained its buffer; the first empty read falls back to readAll() (which
-- blocks until the rest is buffered) so the installer still terminates with
-- the whole archive.
local DOWNLOAD_CHUNK = 32768

local function readBodyProgress(handle, label)
  local total = contentLength(handle)
  local out, got, drewFinal = {}, 0, false
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
            drewFinal = drawProgress(label, got, total, humanBytes(got))
          end
        end
        break
      end
      out[#out + 1] = chunk
      got = got + #chunk
      drewFinal = drawProgress(label, got, total, humanBytes(got))
    end
  end
  if got == 0 and type(handle.readAll) == "function" then
    local body = handle.readAll() or ""
    if #body > 0 then
      drawProgress(label, #body, total, humanBytes(#body))
      return body, #body
    end
  end
  if total and total > 0 and not drewFinal then
    -- Guarantee a clean final frame even if the last draws were throttled.
    drawProgress(label, total, total, humanBytes(total))
  end
  return table.concat(out), got
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
  if explicitRoot then
    pcall(mkdirp, explicitRoot)
    log("Using the install root from the command line: %s", explicitRoot)
    return explicitRoot
  end

  local candidates = findStorageCandidates()
  if not candidates or #candidates == 0 then return internalRoot end

  print("")
  print("Other storage found (the client needs about " .. needed .. " bytes):")
  local fitPath, fitFree
  for _, c in ipairs(candidates) do
    local fits = c.free >= needed
    if fits and not fitPath then fitPath, fitFree = c.path, c.free end
    print(("  %-10s %d bytes free%s"):format(c.path, c.free, fits and "  (fits)" or ""))
  end
  print("")

  if not fitPath then
    print("None of those has enough room; using the internal disk instead.")
    print("")
    return internalRoot
  end

  write(("Install onto %s instead of the internal disk (%d bytes free)? [y/N] ")
    :format(fitPath, fitFree))
  local ans = read and read() or nil
  if type(ans) == "string" and ans:match("^[yY]") then
    local chosen = fitPath
    if chosen:sub(-1) ~= "/" then chosen = chosen .. "/" end
    return chosen
  end
  print("Keeping the internal disk.")
  return internalRoot
end

-- Plain single-response GET via the built-in http API, with a few retries.
-- The bundle is ~440 KB, far below the ~16 MiB single-response cap, so no
-- chunked/big-GET helper is needed. That helper is also wrong here: CDNs such
-- as jsDelivr force gzip on text responses and CraftOS decompresses the body,
-- which makes byte-range validation fail.
local function plainGet(url)
  if not http then
    die("the HTTP API is unavailable (use an Advanced Computer and enable http)")
  end
  local lastErr
  for _ = 1, 3 do
    local h, err = http.get(url, nil, true)
    if h then return h end
    lastErr = err
    sleep(1)
  end
  return nil, lastErr
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

-- True when the archive carries a regular-file entry whose full path is `want`.
-- Used to confirm the lib bundle really contains Lib/basalt.lua before writing.
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

-- Pass 2: extract an in-memory USTAR archive under `root`. This is the same
-- walk measureTar() uses, and it runs only after the free-space check passes,
-- so nothing is written before the check.
local function extractTar(body, root, entries)
  local count, pos, done = 0, 1, 0
  while pos + 511 <= #body do
    local hdr = body:sub(pos, pos + 511)
    local name, full, size, typeflag = tarHeader(hdr)
    if name == "" then break end -- end-of-archive marker
    pos = pos + 512
    if typeflag == "5" then
      mkdirp((root .. full):gsub("/+$", ""))
    else
      mkdirp(dirname(root .. full))
      local f = assert(fs.open(root .. full, "wb"))
      f.write(body:sub(pos, pos + size - 1))
      f.close()
      count = count + 1
    end
    done = done + 1
    drawProgress("Extract", done, entries, ("%d/%d files"):format(done, entries or 0))
    pos = pos + math.ceil(size / 512) * 512
  end
  finishProgress()
  return count
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
if not fs.exists(NCM_INIT) then
  print("CC-CloudMusicNCM installer: the ncm library is not installed.")
  print("")
  print("Expected to find " .. NCM_INIT .. " but it is missing.")
  print("Install the library first by running this exact command on the computer:")
  print("")
  print(NCM_INSTALL_CMD)
  print("")

  write("Download and run the ncm library installer now, using the ghproxy mirror? [y/N] ")
  local ans = read and read() or nil
  local yes = type(ans) == "string" and ans:match("^[yY]") ~= nil

  if not yes then
    print("")
    print("Not installing the ncm library. Run this exact command, then re-run this installer:")
    print("")
    print(NCM_INSTALL_CMD)
    return
  end

  local wget = shell and shell.resolveProgram and shell.resolveProgram("wget")
  if not wget then
    print("")
    print("Cannot find the `wget` program on this computer.")
    print("Run this exact command manually, then re-run this installer:")
    print("")
    print(NCM_INSTALL_CMD)
    return
  end

  print("")
  print("Running the ncm library installer ...")
  shell.run("wget", "run", LIB_INSTALL_URL, LIB_BASE_URL)

  if not fs.exists(NCM_INIT) then
    die("the ncm library installer finished but " .. NCM_INIT .. " is still missing.\n"
      .. "  It may have failed or been aborted. Run this command manually, then retry:\n"
      .. "  " .. NCM_INSTALL_CMD)
  end
  print("ncm library installed at /ncm; continuing with the client install.")
  print("")
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
    print("Using command-line source: " .. CONFIG.base)
    return
  end

  print("Choose a download source:")
  for i, m in ipairs(MIRRORS) do print(("  %d) %s"):format(i, m.name)) end
  print(("  %d) Custom URL"):format(#MIRRORS + 1))

  local n = tonumber(ask("Select [1]: ")) or 1
  if n >= 1 and n <= #MIRRORS then
    CONFIG.base = MIRRORS[n].base
    print("Selected: " .. MIRRORS[n].name)
  elseif n == #MIRRORS + 1 then
    local u = ask("Bundle base URL (the dir containing dist/): ")
    if u ~= "" then CONFIG.base = u:gsub("/+$", "") end
    print("Using custom source")
  else
    CONFIG.base = MIRRORS[1].base
    print("Invalid input, using default: " .. MIRRORS[1].name)
  end
end

pickSource()

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

  local body
  for i = 1, #sources do
    local base = sources[i]
    log("  source %d/%d: %s", i, #sources, base)
    local handle, err = plainGet(base .. "/" .. CONFIG.libBundle)
    if handle then
      body = readBodyProgress(handle, "Download")
      handle.close()
      finishProgress()
      break
    end
    log("  download failed: %s", tostring(err))
  end
  if not body then
    die("could not download " .. CONFIG.libBundle .. " from any mirror")
  end

  -- The lib bundle must contain exactly the shared framework; refuse anything
  -- that does not (guards against serving the wrong file from a stale mirror).
  if not tarHasEntry(body, BASALT_ENTRY) then
    die(CONFIG.libBundle .. " does not contain " .. BASALT_ENTRY)
  end

  local totalBytes, entries = measureTar(body)
  local needed = totalBytes + entries * PER_ENTRY_OVERHEAD
  log("  archive: %d entries, %d bytes (needs about %d with per-file overhead)",
    entries, totalBytes, needed)

  if type(fs.getFreeSpace) == "function" then
    local free = fs.getFreeSpace(internalRoot)
    log("  free space on %s: %d bytes", internalRoot, free)
    if free < needed then
      die(("not enough disk space for the shared framework: %d bytes free, this archive "
        .. "needs about %d bytes (%d entries).\n"
        .. "  Delete files on the computer, or raise computer_space_limit in\n"
        .. "  config/computercraft-server.toml (then restart the world), and retry.")
        :format(free, needed, entries))
    end
  end

  local files = extractTar(body, internalRoot, entries)
  log("  extracted %d files", files)
  if not fs.exists(BASALT_PATH) then
    die("extraction finished but " .. BASALT_PATH .. " is missing")
  end
end

-- -------------------------------------------------------------- stage B: client
-- Download each candidate client bundle into memory, measure the archive that
-- was just downloaded, pick the install root from the measured size, check that
-- the bundle fits there, and only then extract it. The size MUST come from the
-- archive itself: a hardcoded byte count goes stale as soon as the bundle
-- changes, and it cannot account for CC charging disk per file.
local function installClient(sources)
  log("[2/5] Downloading and measuring the client bundle ...")
  local installed = false
  local installRoot, installTarget, removedPrev
  for i = 1, #sources do
    local base = sources[i]
    log("  source %d/%d: %s", i, #sources, base)

    local handle, err = plainGet(base .. "/" .. CONFIG.bundle)
    if not handle then
      log("  download failed: %s", tostring(err))
    else
      -- Buffer the whole archive, then measure it BEFORE writing a single byte.
      local body = readBodyProgress(handle, "Download")
      handle.close()
      finishProgress()

      local totalBytes, entries = measureTar(body)
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
        log("[3/5] Removing previous client install (if any) ...")
        rmrf(installTarget)
        removedPrev = true
      end

      if type(fs.getFreeSpace) == "function" then
        local free = fs.getFreeSpace(installRoot)
        log("  free space: %d bytes", free)
        if free < needed then
          local msg = ("not enough disk space: %d bytes free, this archive needs about %d bytes (%d entries)."):format(
            free, needed, entries)
          if installRoot == internalRoot then
            msg = msg .. "\n  Delete files on the computer, or raise computer_space_limit in\n"
              .. "  config/computercraft-server.toml (then restart the world), and retry."
          end
          die(msg)
        end
      end

      local files = extractTar(body, installRoot, entries)
      log("  extracted %d files", files)

      if fs.exists(installTarget .. "/startup.lua")
        and fs.exists(installTarget .. "/Lib/utf8display.lua")
        and fs.exists(installTarget .. "/icons/Home.lua")
        and basaltAvailable(installTarget) then
        installed = true
        if i > 1 then log("  note: the chosen source failed; using another mirror") end
        break
      end
      log("  bundle incomplete; trying another mirror ...")
      rmrf(installTarget)
    end
  end
  if not installed then
    die("could not install a complete bundle from any mirror")
  end

  -- Verify the files startup.lua loads and print the run instruction.
  log("[4/5] Verifying ...")
  local checks = {
    "startup.lua",
    "Lib/utf8display.lua",
    "icons/Home.lua",
  }
  local allOk = true
  for _, rel in ipairs(checks) do
    local ok = fs.exists(installTarget .. "/" .. rel)
    log("  %s %s", ok and "OK  " or "MISS", rel)
    if not ok then allOk = false end
  end
  local basaltOk = basaltAvailable(installTarget)
  log("  %s %s", basaltOk and "OK  " or "MISS",
    "Lib/basalt.lua (shared at " .. BASALT_PATH .. ")")
  if not basaltOk then allOk = false end
  if not allOk then
    die("verification failed: a required file did not land under " .. installTarget)
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
