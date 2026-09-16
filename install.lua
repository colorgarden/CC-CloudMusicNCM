--[[
  install.lua - one-click installer for CC-CloudMusicNCM, a CC:Tweaked
  NetEase Cloud Music client (Basalt UI + utf8display CJK bitmaps).

  What it does
    1. checks that the `ncm` library is installed at /ncm; when it is missing,
       offers to download and run the library installer through the ghproxy
       mirror and, once /ncm/init.lua exists, continues automatically,
    2. removes any previous /ccncm install,
    3. downloads dist/ccncm.tar fully into memory, measures what it needs,
       checks free disk space against that measured figure, and only then
       extracts it (uncompressed USTAR - no gzip library or temp file needed),
    4. verifies the files that the client's startup.lua requires.

  Layout (the bundle's entries are already rooted at `ccncm/`):

      /ccncm/startup.lua        entry point
      /ccncm/ccncm/*.lua        Basalt UI, data layer, strings
      /ccncm/Lib/*.lua          Basalt, utf8display, json
      /ccncm/icons/*.lua        icon bitmaps
      /ccncm/README.md, /ccncm/LICENSE

  The root matters: startup.lua uses require("Lib.basalt"), require("ccncm.app")
  and require("icons.Home"), which CraftOS resolves relative to the running
  program's directory. So the client must be launched as `ccncm/startup` from
  the directory that contains `ccncm/` (by default `/`).

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

  Everything is installed under `/` by default. Change CONFIG.root below to
  install elsewhere; the value must end with "/".
]]

local CONFIG = {
  -- Where dist/ccncm.tar is served from (overridable by argv[1]).
  base = "https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main",
  -- Where ccncm/ is installed (must end with "/").
  root = "/",
  -- Bundle path relative to the base URL.
  bundle = "dist/ccncm.tar",
}

local args = { ... }

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

-- Wrap a binary HTTP handle so `read(n)` behaves the way readBody() above
-- expects: blocking, returning nil only at end of stream.
--
-- CC:Tweaked's http handle already does this. CraftOS-PC does not: there
-- `read(n)` is a non-blocking readsome() that can return "" while the body is
-- still downloading, so a plain read loop would stop at the first header and
-- buffer nothing. On the first empty read we fall back to readAll(), which
-- blocks until the whole (small, ~450 KB) response is buffered, and then serve
-- the remaining reads from memory.
local function blockingHandle(handle)
  local body, pos = nil, 1
  return {
    read = function(n)
      if body then
        if pos > #body then return nil end
        local chunk = body:sub(pos, pos + n - 1)
        pos = pos + #chunk
        return chunk
      end
      local chunk = handle.read(n)
      if chunk ~= nil and #chunk == 0 then
        body = handle.readAll() or ""
        if pos > #body then return nil end
        chunk = body:sub(pos, pos + n - 1)
        pos = pos + #chunk
      end
      return chunk
    end,
  }
end

-- Read the whole (small, single-response) body into one Lua string before
-- measuring or extracting it. blockingHandle() makes read(n) blocking, so this
-- loop terminates only at end of stream, and the archive never touches disk.
local function readBody(handle)
  local h = blockingHandle(handle)
  local out = {}
  while true do
    local chunk = h.read(65536)
    if not chunk or #chunk == 0 then break end
    out[#out + 1] = chunk
  end
  return table.concat(out)
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

-- Pass 2: extract an in-memory USTAR archive under `root`. This is the same
-- walk measureTar() uses, and it runs only after the free-space check passes,
-- so nothing is written before the check.
local function extractTar(body, root)
  local count, pos = 0, 1
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
    pos = pos + math.ceil(size / 512) * 512
  end
  return count
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
    local u = ask("Bundle base URL (the dir containing dist/ccncm.tar): ")
    if u ~= "" then CONFIG.base = u:gsub("/+$", "") end
    print("Using custom source")
  else
    CONFIG.base = MIRRORS[1].base
    print("Invalid input, using default: " .. MIRRORS[1].name)
  end
end

pickSource()

-- --------------------------------------------------------------------- main
local root = CONFIG.root
if root:sub(-1) ~= "/" then root = root .. "/" end
local target = root .. "ccncm"

log("CC-CloudMusicNCM installer for CC:Tweaked")
log("  bundle : %s/%s", CONFIG.base, CONFIG.bundle)
log("  target : %s/", target)

-- 1. remove any previous install so re-running is idempotent.
log("[1/4] Removing previous install (if any) ...")
rmrf(target)

-- 2. download each candidate bundle into memory, measure the archive that was
-- just downloaded, check that it fits, and only then extract it. The size MUST
-- come from the archive itself: a hardcoded byte count goes stale as soon as
-- the bundle changes, and it cannot account for CC charging disk per file.
local sources = { CONFIG.base }
for _, m in ipairs(MIRRORS) do
  if m.base ~= CONFIG.base then sources[#sources + 1] = m.base end
end

log("[2/3] Downloading and extracting ...")
local installed = false
for i = 1, #sources do
  local base = sources[i]
  log("  source %d/%d: %s", i, #sources, base)

  local handle, err = plainGet(base .. "/" .. CONFIG.bundle)
  if not handle then
    log("  download failed: %s", tostring(err))
  else
    -- Buffer the whole archive, then measure it BEFORE writing a single byte.
    local body = readBody(handle)
    handle.close()

    local totalBytes, entries = measureTar(body)
    local needed = totalBytes + entries * PER_ENTRY_OVERHEAD
    log("  archive: %d entries, %d bytes (needs about %d with per-file overhead)",
      entries, totalBytes, needed)

    if fs.getFreeSpace then
      local free = fs.getFreeSpace(root)
      log("  free space: %d bytes", free)
      if free < needed then
        die(string.format(
          "not enough disk space: %d bytes free, this archive needs about %d bytes (%d entries).\n"
            .. "  Delete files on the computer, or raise computer_space_limit in\n"
            .. "  config/computercraft-server.toml (then restart the world), and retry.",
          free, needed, entries))
      end
    end

    local files = extractTar(body, root)
    log("  extracted %d files", files)

    if fs.exists(target .. "/startup.lua")
      and fs.exists(target .. "/Lib/basalt.lua")
      and fs.exists(target .. "/Lib/utf8display.lua")
      and fs.exists(target .. "/icons/Home.lua") then
      installed = true
      if i > 1 then log("  note: the chosen source failed; using another mirror") end
      break
    end
    log("  bundle incomplete; trying another mirror ...")
    rmrf(target)
  end
end
if not installed then
  die("could not install a complete bundle from any mirror")
end

-- 3. verify the files startup.lua loads and print the run instruction.
log("[3/3] Verifying ...")
local checks = {
  "startup.lua",
  "Lib/basalt.lua",
  "Lib/utf8display.lua",
  "icons/Home.lua",
}
local allOk = true
for _, rel in ipairs(checks) do
  local ok = fs.exists(target .. "/" .. rel)
  log("  %s %s", ok and "OK  " or "MISS", rel)
  if not ok then allOk = false end
end
if not allOk then
  die("verification failed: a required file did not land under " .. target)
end

log("")
log("Done. CC-CloudMusicNCM is installed at %s/", target)
log("Run it as:")
log("  ccncm/startup")
log("from the directory that contains ccncm/ (the default install root is /).")
log("For example, at the shell prompt in /, type: ccncm/startup")
