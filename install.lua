--[[
  install.lua - one-click installer for CC-CloudMusicNCM, a CC:Tweaked
  NetEase Cloud Music client (Basalt UI + utf8display CJK bitmaps).

  What it does
    1. checks that the `ncm` library is installed at /ncm; when it is missing,
       offers to download and run the library installer through the ghproxy
       mirror and, once /ncm/init.lua exists, continues automatically,
    2. removes any previous /ccncm install,
    3. checks free disk space,
    4. streams dist/ccncm.tar off the internet straight into the filesystem
       (uncompressed USTAR - no gzip library or temp file needed),
    5. verifies the files that the client's startup.lua requires.

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
    -- or, with a custom base URL for the bundle:
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
  -- Rough size of the extracted client plus file-system slack. The client is
  -- about 425 KB with Basalt; leave room so "Out of space" cannot happen deep
  -- inside the extractor, where it would be impossible to act on.
  needBytes = 600000,
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

local function readN(handle, n)
  local out, got = {}, 0
  while got < n do
    local chunk = handle.read(n - got)
    if not chunk or #chunk == 0 then break end
    out[#out + 1] = chunk
    got = got + #chunk
  end
  return table.concat(out), got
end

-- Wrap a binary HTTP handle so `read(n)` behaves the way the extractor below
-- expects: blocking, returning nil only at end of stream.
--
-- CC:Tweaked's http handle already does this. CraftOS-PC does not: there
-- `read(n)` is a non-blocking readsome() that can return "" while the body is
-- still downloading, so the reference extractor would stop at the first header
-- and extract nothing. On the first empty read we fall back to readAll(), which
-- blocks until the whole (small, ~486 KB) response is buffered, and then serve
-- the remaining reads from memory. Real hardware keeps true streaming.
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

-- Stream a (uncompressed) USTAR archive from an HTTP handle into `root`.
local function untar(handle, root)
  local count = 0
  while true do
    local hdr, n = readN(handle, 512)
    if n < 512 then break end
    local name = hdr:sub(1, 100):match("^[^%z]*") or ""
    if name == "" then break end -- end-of-archive
    local sizeStr = (hdr:sub(125, 136):match("^[^%z]*") or "0"):gsub("%s", "")
    local size = tonumber(sizeStr, 8) or 0
    local typeflag = hdr:sub(157, 157)
    local prefix = hdr:sub(346, 500):match("^[^%z]*") or ""
    local full = prefix ~= "" and (prefix .. "/" .. name) or name
    local dest = root .. full

    if typeflag == "5" then
      mkdirp(dest:gsub("/+$", ""))
    else
      mkdirp(dirname(dest))
      local f = assert(fs.open(dest, "wb"))
      local remaining = size
      while remaining > 0 do
        local chunk = readN(handle, math.min(remaining, 8192))
        if #chunk == 0 then break end
        f.write(chunk)
        remaining = remaining - #chunk
      end
      f.close()
      local pad = (512 - (size % 512)) % 512
      if pad > 0 then readN(handle, pad) end
      count = count + 1
    end
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
-- Same mirror style as the reference installer. No interactive menu: the
-- first usable source wins, and a command-line argument overrides them all.
local MIRRORS = {
  { name = "jsDelivr (recommended)", base = "https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main" },
  { name = "GitHub raw", base = "https://raw.githubusercontent.com/colorgarden/CC-CloudMusicNCM/main" },
  { name = "ghproxy.net (GitHub proxy)", base = "https://ghproxy.net/https://raw.githubusercontent.com/colorgarden/CC-CloudMusicNCM/main" },
}

if args[1] and args[1] ~= "" then
  CONFIG.base = args[1]:gsub("/+$", "")
  print("Using command-line source: " .. CONFIG.base)
end

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

-- 2. check free space before touching the bundle.
log("[2/4] Checking free space ...")
if fs.getFreeSpace then
  local free = fs.getFreeSpace(root)
  log("  free space: %d bytes", free)
  if free < CONFIG.needBytes then
    die(string.format(
      "not enough disk space: %d bytes free, about %d needed.\n"
        .. "  Delete files on the computer, or raise computer_space_limit in\n"
        .. "  config/computercraft-server.toml (then restart the world), and retry.",
      free, CONFIG.needBytes))
  end
else
  log("  free-space check unavailable on this build, continuing")
end

-- 3. download + extract, falling through mirrors until a bundle verifies.
local sources = { CONFIG.base }
for _, m in ipairs(MIRRORS) do
  if m.base ~= CONFIG.base then sources[#sources + 1] = m.base end
end

log("[3/4] Downloading and extracting ...")
local installed = false
for i = 1, #sources do
  local base = sources[i]
  log("  source %d/%d: %s", i, #sources, base)

  local handle, err = plainGet(base .. "/" .. CONFIG.bundle)
  if not handle then
    log("  download failed: %s", tostring(err))
  else
    local files = untar(blockingHandle(handle), root)
    handle.close()
    log("  extracted %d files", files)

    if fs.exists(target .. "/startup.lua") and fs.exists(target .. "/Lib/basalt.lua") then
      installed = true
      if i > 1 then log("  note: an earlier source did not serve a usable bundle") end
      break
    end
    log("  bundle incomplete; trying another mirror ...")
    rmrf(target)
  end
end
if not installed then
  die("could not install a complete bundle from any mirror")
end

-- 4. verify the files startup.lua loads and print the run instruction.
log("[4/4] Verifying ...")
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
