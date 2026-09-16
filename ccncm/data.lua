-- ccncm/data.lua
-- Data layer: everything that talks to the local `ncm` library.
--
-- The UI never sees a raw API response.  Each function returns either a
-- normalised value or (nil, human-readable-error).  Every ncm call is wrapped
-- in pcall because a missing network or a non-200 status raises a table.

local M = {}

local COOKIE_FILE = "/ncm_cookie"

local ncm = nil
M.available = false
M.reason = nil

-- Single source of truth for the login state every UI gate reads:
--   { state = "in" | "out" | "unknown", uid = ..., nickname = ... }
M.session = { state = "unknown", uid = nil, nickname = nil }

-- The speaker program lives next to ncm's dependencies.  ncm.lib resolves that
-- directory at runtime; fall back to the documented install path.
local SPEAKER_PROGRAM = "/ncm/lib/speaker.lua"

-- The id carried by every speakerlib event.  The same id is passed to the
-- program with -id and to all control events, so speakerlib knows the events
-- belong to this client.
M.SPEAKER_ID = "ccncm"

-- ============================================================================
-- Initialisation
-- ============================================================================

function M.init()
  -- /ncm is a sibling of the root, so require needs an absolute template.
  package.path = "/?.lua;/?/init.lua;" .. package.path

  local ok, mod = pcall(require, "ncm")
  if not ok then
    M.available = false
    M.reason = "cannot load the ncm library (is it installed at /ncm?): " .. tostring(mod)
    return false, M.reason
  end
  ncm = mod
  M.available = true

  local okLib, lib = pcall(require, "ncm.lib")
  if okLib and type(lib) == "table" and type(lib.dir) == "string" then
    SPEAKER_PROGRAM = lib.dir .. "/speaker.lua"
  end

  M.cookie = M.loadCookie()
  return true
end

-- ============================================================================
-- Cookie persistence
-- ============================================================================

-- Set-Cookie attributes: never part of the cookie header that is sent back.
local COOKIE_ATTRS = {
  Expires = true,
  ["Max-Age"] = true,
  Path = true,
  Domain = true,
  Secure = true,
  HttpOnly = true,
  SameSite = true,
  Version = true,
  Comment = true,
  Priority = true,
}

-- Keep only `name=value` cookie pairs.  The QR check responses include the
-- whole Set-Cookie line (Path/Expires/Max-Age x many), which bloats the saved
-- file and is not needed by the API.  MUSIC_U and __csrf are ordinary pairs and
-- survive; bare attribute tokens (Secure/HttpOnly) are dropped too.
function M.sanitizeCookie(str)
  if type(str) ~= "string" then return nil end
  local parts = {}
  for token in str:gmatch("[^;]+") do
    local trimmed = token:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      local key = trimmed:match("^([^=]+)") or trimmed
      key = key:gsub("^%s+", ""):gsub("%s+$", "")
      if not COOKIE_ATTRS[key] then parts[#parts + 1] = trimmed end
    end
  end
  return table.concat(parts, "; ")
end

function M.loadCookie()
  if not fs.exists(COOKIE_FILE) then return nil end
  local f = fs.open(COOKIE_FILE, "r")
  if not f then return nil end
  local data = f.readAll()
  f.close()
  if type(data) == "string" and data ~= "" then return data end
  return nil
end

-- Write the (sanitised) cookie and prove the write actually landed: a silent
-- zero-byte write previously cost the user a login.  Writes to a temp file and
-- moves it into place, so a failed write can never clobber a good cookie.
-- Returns ok, err.
function M.saveCookie(str)
  str = M.sanitizeCookie(str)
  if type(str) ~= "string" or str == "" then
    return false, "empty cookie after sanitising"
  end
  local tmp = COOKIE_FILE .. ".tmp"
  if fs.exists(tmp) then pcall(fs.delete, tmp) end
  local f = fs.open(tmp, "w")
  if not f then return false, "cannot open " .. tmp .. " for writing" end
  local okW, errW = pcall(function() f.write(str) end)
  local okC, errC = pcall(function() f.close() end)
  if not okW then pcall(fs.delete, tmp); return false, "write failed: " .. tostring(errW) end
  if not okC then pcall(fs.delete, tmp); return false, "close failed: " .. tostring(errC) end

  local size = fs.exists(tmp) and (fs.getSize(tmp) or 0) or 0
  if size <= 0 then pcall(fs.delete, tmp); return false, "cookie file is empty after write" end
  local rf = fs.open(tmp, "r")
  if not rf then pcall(fs.delete, tmp); return false, "cannot reopen " .. tmp end
  local back = rf.readAll()
  rf.close()
  if back ~= str then pcall(fs.delete, tmp); return false, "cookie read-back mismatch" end

  if fs.exists(COOKIE_FILE) then pcall(fs.delete, COOKIE_FILE) end
  local okM, errM = pcall(fs.move, tmp, COOKIE_FILE)
  if not okM then pcall(fs.delete, tmp); return false, "move failed: " .. tostring(errM) end

  M.cookie = str
  return true
end

function M.clearCookie()
  M.cookie = nil
  M.uid = nil
  M.session = { state = "out", uid = nil, nickname = nil }
  if fs.exists(COOKIE_FILE) then pcall(fs.delete, COOKIE_FILE) end
end

-- Facts for the startup diagnostic line.
function M.cookieInfo()
  local bytes = 0
  if fs.exists(COOKIE_FILE) then bytes = fs.getSize(COOKIE_FILE) or 0 end
  local present = type(M.cookie) == "string" and M.cookie ~= ""
  local musicU = present and (M.cookie:find("MUSIC_U", 1, true) ~= nil) or false
  return { present = present, bytes = bytes, musicU = musicU }
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- Turn a raised ncm answer (a table) into a short message.
function M.errText(e)
  if type(e) == "table" then
    local body = e.body
    if type(body) == "table" and body.msg then return tostring(body.msg) end
    if e.message then return tostring(e.message) end
    return "request failed (status " .. tostring(e.status) .. ")"
  end
  return tostring(e)
end

local function artistsText(s)
  local arr = s.artists or s.ar or {}
  local names = {}
  for _, a in ipairs(arr) do
    if a.name then names[#names + 1] = a.name end
  end
  return table.concat(names, "/")
end

-- Normalise the various song shapes (search / song_detail / playlist) into one.
function M.songInfo(s)
  local album = s.album or s.al
  return {
    kind = "song",
    id = s.id,
    name = s.name or "?",
    artist = artistsText(s),
    album = (album and album.name) or "",
    duration = tonumber(s.duration or s.dt) or 0,
  }
end

function M.formatTime(ms)
  ms = tonumber(ms) or 0
  local total = math.floor(ms / 1000)
  local m = math.floor(total / 60)
  local s = total % 60
  return string.format("%02d:%02d", m, s)
end

function M.speakerProgram()
  return SPEAKER_PROGRAM
end

function M.hasSpeaker()
  if peripheral and peripheral.find then
    return peripheral.find("speaker") ~= nil
  end
  return false
end

-- ============================================================================
-- Login
-- ============================================================================

function M.qrKey()
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.login_qr_key, {})
  if not ok then return nil, M.errText(res) end
  local key = res.body and res.body.data and res.body.data.unikey
  if not key then return nil, "no unikey in the response" end
  return key
end

-- The library already knows how to build the login URL; the plain URL is the
-- documented fallback.
function M.qrUrl(key)
  if ncm then
    local ok, res = pcall(ncm.login_qr_create, { key = key })
    if ok and res and res.body and res.body.data and res.body.data.qrurl then
      return res.body.data.qrurl
    end
  end
  return "https://music.163.com/login?codekey=" .. tostring(key)
end

-- Returns code, cookie.  800 expired / 802 scanned / 803 confirmed.
function M.qrCheck(key)
  if not ncm then return nil, nil end
  local ok, res = pcall(ncm.login_qr_check, { key = key })
  if not ok then return nil, nil end
  local body = res.body or {}
  local cookie = body.cookie
  if (type(cookie) ~= "string" or cookie == "") and type(res.cookie) == "table" then
    cookie = table.concat(res.cookie, "; ")
  end
  return body.code, cookie
end

-- Pull account/profile out of either the login_status wrapper (body.data) or a
-- raw user_account body.  Both endpoints answer with the same top-level fields.
local function accountParts(body)
  if type(body) ~= "table" then return nil, nil end
  local d = body.data
  if type(d) == "table" and (d.account ~= nil or d.profile ~= nil) then
    return d.account, d.profile
  end
  return body.account, body.profile
end

function M.account()
  if not ncm then return nil, "ncm unavailable" end
  if type(M.cookie) ~= "string" or M.cookie == "" then return nil, "no cookie" end
  local ok, res = pcall(ncm.user_account, { cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  local account, profile = accountParts(res.body)
  if profile then
    M.uid = profile.userId or (account and account.id)
    return profile
  end
  return nil, "no profile in the response"
end

-- True login state.  ncm.login_status calls /api/w/nuser/account/get and, when
-- the response code is 200, wraps the raw body under body.data, so the real
-- fields are body.data.account / body.data.profile.  Returns a table
-- { loggedIn, account, profile, uid, vip, code }, or (nil, err) when the check
-- itself could not run (no library / network failure) so the caller can tell a
-- network error apart from a genuine "logged out".
function M.loginStatus()
  if not ncm then return nil, "ncm unavailable" end
  if type(M.cookie) ~= "string" or M.cookie == "" then
    return { loggedIn = false, reason = "no_cookie" }
  end
  local ok, res = pcall(ncm.login_status, { cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  local body = res.body or {}
  local account, profile = accountParts(body)
  local uid = (account and (account.id or account.userId)) or (profile and profile.userId)
  local loggedIn = (account ~= nil and uid ~= nil) or (profile ~= nil and profile.userId ~= nil)
  if loggedIn then M.uid = uid end
  return {
    loggedIn = loggedIn,
    account = account,
    profile = profile,
    uid = uid,
    vip = account and (account.vipType or account.vipRights) or (profile and profile.vipType),
    code = body.code or (body.data and body.data.code),
    reason = loggedIn and nil or "not_logged_in",
  }
end

-- Log out on the server when possible, then always drop the local cookie.
function M.logout()
  if ncm and type(M.cookie) == "string" and M.cookie ~= "" then
    pcall(ncm.logout, { cookie = M.cookie })
  end
  M.clearCookie()
end

-- Resolve and store the one session state every UI gate reads.  Three-way and
-- never conflated:
--   no cookie                          -> "out"
--   verification succeeded, account    -> "in"
--   verification FAILED (raise/timeout)-> "unknown" (cookie kept!)
--   verification succeeded, no account -> "out" (definitive; cookie cleared)
function M.resolveSession()
  if not ncm then
    M.session = { state = "unknown", uid = M.session.uid, nickname = M.session.nickname }
    return M.session, "ncm unavailable"
  end
  if type(M.cookie) ~= "string" or M.cookie == "" then
    M.session = { state = "out", uid = nil, nickname = nil }
    return M.session
  end
  local st, err = M.loginStatus()
  if not st then
    -- The check itself could not run: keep the cookie and stay "unknown" so the
    -- UI never renders the user as logged out because of a network hiccup.
    M.session = { state = "unknown", uid = M.session.uid, nickname = M.session.nickname }
    return M.session, err
  end
  if st.loggedIn then
    M.session = {
      state = "in",
      uid = st.uid,
      nickname = (st.profile and st.profile.nickname) or nil,
    }
    return M.session
  end
  -- A successful call that reports no account is a definitive "out".
  M.clearCookie()
  M.session = { state = "out", uid = nil, nickname = nil }
  return M.session
end

-- ============================================================================
-- Search
-- ============================================================================

function M.search(keywords, limit)
  if not ncm then return nil, "ncm unavailable" end
  if type(keywords) ~= "string" or keywords == "" then return nil, "empty keyword" end
  local ok, res = pcall(ncm.search, {
    keywords = keywords,
    type = 1,
    limit = limit or 30,
    cookie = M.cookie,
  })
  if not ok then return nil, M.errText(res) end
  local songs = (res.body and res.body.result and res.body.result.songs) or {}
  local out = {}
  for _, s in ipairs(songs) do out[#out + 1] = M.songInfo(s) end
  return out
end

-- ============================================================================
-- Content pages
-- ============================================================================

local function playlistsFrom(list)
  local out = {}
  for _, p in ipairs(list or {}) do
    out[#out + 1] = {
      kind = "playlist",
      id = p.id,
      name = p.name or "?",
      -- Only trackCount is a real song count; playCount is plays, not songs.
      count = tonumber(p.trackCount) or 0,
      creator = (p.creator and p.creator.nickname) or "",
    }
  end
  return out
end

function M.personalized()
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.personalized, { limit = 30, cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  return playlistsFrom(res.body and res.body.result)
end

function M.recommendResource()
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.recommend_resource, { cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  return playlistsFrom(res.body and res.body.recommend)
end

function M.toplist()
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.toplist, { cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  return playlistsFrom(res.body and res.body.list)
end

function M.userPlaylist(uid)
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.user_playlist, { uid = uid, limit = 50, cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  return playlistsFrom(res.body and res.body.playlist)
end

-- All songs of a playlist / toplist (id is the same kind of id).
function M.playlistSongs(id, limit)
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.playlist_track_all, {
    id = id,
    limit = limit or 200,
    cookie = M.cookie,
  })
  if not ok then return nil, M.errText(res) end
  local songs = (res.body and res.body.songs) or {}
  local out = {}
  for _, s in ipairs(songs) do out[#out + 1] = M.songInfo(s) end
  return out
end

function M.dailySongs()
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.recommend_songs, { cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  local data = res.body and res.body.data
  local songs = (data and data.dailySongs) or (res.body and res.body.recommend) or {}
  local out = {}
  for _, s in ipairs(songs) do out[#out + 1] = M.songInfo(s) end
  return out
end

-- Liked songs: ids first, then one batched detail call.
function M.likedSongs(uid)
  if not ncm then return nil, "ncm unavailable" end
  local ok, res = pcall(ncm.likelist, { uid = uid, cookie = M.cookie })
  if not ok then return nil, M.errText(res) end
  local ids = (res.body and res.body.ids) or {}
  if #ids == 0 then return {} end
  local parts = {}
  for i = 1, math.min(#ids, 500) do parts[#parts + 1] = tostring(ids[i]) end
  local ok2, res2 = pcall(ncm.song_detail, {
    ids = table.concat(parts, ","),
    cookie = M.cookie,
  })
  if not ok2 then return nil, M.errText(res2) end
  local songs = (res2.body and res2.body.songs) or {}
  local out = {}
  for _, s in ipairs(songs) do out[#out + 1] = M.songInfo(s) end
  return out
end

-- ============================================================================
-- Playback
-- ============================================================================

-- Resolve a playable URL for `id`.  Returns url, type, err.
function M.songUrl(id, level)
  if not ncm then return nil, nil, "ncm unavailable" end
  local ok, res = pcall(ncm.song_url_v1, {
    id = id,
    level = level or "lossless",
    cookie = M.cookie,
  })
  if not ok then return nil, nil, M.errText(res) end
  local d = res.body and res.body.data and res.body.data[1]
  if not d or not d.url or d.url == "" then
    return nil, nil, "no playable url (VIP / region / copyright?)"
  end
  return d.url, d.type, nil
end

-- Can playback start at all?  Separated from runSpeaker so the UI can report a
-- missing program / speaker before it schedules the background run.
function M.canPlay()
  if not fs.exists(SPEAKER_PROGRAM) then
    return false, "speaker program missing: " .. SPEAKER_PROGRAM
  end
  if not M.hasSpeaker() then
    return false, "no speaker attached"
  end
  return true
end

-- Run the speaker program for `url`.  This blocks the *calling coroutine* until
-- playback ends, so the UI must call it through basalt.schedule(), which pumps
-- the coroutine with the Basalt event loop and keeps the UI responsive.
--   -noui  speakerlib never paints its own page over the client.
--   -id    every speakerlib_* event carries this client's id.
function M.runSpeaker(url)
  if not fs.exists(SPEAKER_PROGRAM) then
    return false, "speaker program missing: " .. SPEAKER_PROGRAM
  end
  if not M.hasSpeaker() then
    return false, "no speaker attached"
  end
  local ok, res = pcall(shell.run, SPEAKER_PROGRAM, url, "-id", M.SPEAKER_ID, "-noui")
  if not ok then return false, tostring(res) end
  if res == false then return false, "speaker program exited with an error" end
  return true
end

-- Control events.  speakerlib expects (event, id, ...) and ignores events whose
-- id is not its own, so every one of these carries M.SPEAKER_ID.
function M.pauseSpeaker()
  os.queueEvent("speakerlib_pause", M.SPEAKER_ID)
end

function M.resumeSpeaker()
  os.queueEvent("speakerlib_resume", M.SPEAKER_ID)
end

function M.stopSpeaker()
  os.queueEvent("speakerlib_stop", M.SPEAKER_ID)
end

function M.seekSpeaker(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 0 then seconds = 0 end
  os.queueEvent("speakerlib_seek", M.SPEAKER_ID, seconds)
end

function M.setSpeakerVolume(level)
  level = tonumber(level) or 0
  if level < 0 then level = 0 elseif level > 3 then level = 3 end
  os.queueEvent("speakerlib_volume", M.SPEAKER_ID, level)
end

return M
