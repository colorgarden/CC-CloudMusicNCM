-- ccncm/app.lua
-- The Basalt UI.  Layout and interaction mirror the reference client
-- (left navigation, top bar, bottom player), but every piece of data comes
-- from the local `ncm` library through ccncm/data.lua.

-- /ncm lives at the filesystem root, so its modules need the absolute
-- template before anything under ncm.* is required (ccncm/qr.lua does that).
package.path = "/?.lua;/?/init.lua;" .. package.path

local basalt = require("Lib.basalt")
local utf8display = require("Lib.utf8display")
local bimg = require("ccncm.bimg")
local qr = require("ccncm.qr")
local data = require("ccncm.data")
local S = require("ccncm.strings")

local M = {}

-- Local font override: a full CJK font is large, so if the user drops one at
-- /ccncm_font.lua we use it instead of downloading on every boot.
local LOCAL_FONT = "/ccncm_font.lua"
local RECENT_FILE = "/ccncm_recent"

-- ============================================================================
-- Font / configuration
-- ============================================================================

local function tryFont(fn)
  local ok, a, b = pcall(fn)
  if ok and a ~= false then return true end
  if not ok then return false, tostring(a) end
  return false, tostring(b)
end

local function loadFontSafe()
  if fs.exists(LOCAL_FONT) then
    utf8display.config.fontPath = LOCAL_FONT
    local ok, err = tryFont(utf8display.loadFont)
    if ok then return true end
    utf8display.config.fontPath = nil
    -- fall through to the remote font rather than failing outright
  end
  return tryFont(utf8display.loadFont)
end

-- ============================================================================
-- Small helpers
-- ============================================================================

local PSTR = bimg.ProcessStrToBimg
local CIMG = bimg.ConcatBimg

local function bmp(text, fg, bg)
  return PSTR(text, fg or "Q", bg or "B")
end

local function showFrame(frame, on)
  frame:setVisible(on)
  frame:setEnabled(on)
end

-- Basalt only blits dirty rectangles.  The speaker program paints over the
-- terminal while it runs, so after it returns we must mark the whole screen
-- dirty or most of the UI would stay blank.
local function forceFullRedraw()
  -- Resolve the live frame explicitly: `root` is declared further down, so
  -- referring to it here would capture the (nil) global instead and silently
  -- skip the redraw.
  local frame = basalt.getMainFrame()
  if not frame then return end
  local r = frame._render
  if r and r.addDirtyRect then
    r:addDirtyRect(1, 1, frame:getWidth(), frame:getHeight())
    frame._renderUpdate = true
  end
end

-- ============================================================================
-- State
-- ============================================================================

local root
local navFrame, navList
local topFrame, pageTitle, backButton, userButton, searchInput
local contentFrame, contentList
local playerFrame, playerTitle, playPauseButton
local popupFrame, popupLabel
local loginFrame, loginQrLabel, loginStatus, loginRefresh, loginCancel

local timerHandlers = {}
local currentQueue = {}
local currentIndex = 0
local history = {}
local currentItems = {}
local currentTitle = ""

local loginKey = nil
local loginPolling = false
local lastUserLabel = nil

-- Playback state mirrored from speakerlib's events.  The UI reads and writes
-- only this table; the speaker program itself runs in the background.
local player = {
  title = nil,
  total = 0,
  progress = 0,
  volume = 1,
  paused = false,
  playing = false,
  ready = false,
  stopped = true,
  format = nil,
}
-- Set while waiting for a previous speaker to acknowledge speakerlib_stop before
-- the next song is launched with the same id.
local pendingLaunch = nil
local launchSeq = 0

local GLYPH_H = 3

-- ============================================================================
-- Timers
-- ============================================================================

local function after(seconds, fn)
  local id = os.startTimer(seconds)
  timerHandlers[id] = fn
  return id
end

-- ============================================================================
-- Notifications
-- ============================================================================

local function notify(bimgOrText, seconds)
  local b = bimgOrText
  if type(b) == "string" then b = bmp(b) end
  if type(b) ~= "table" then return end
  local w = bimg.widthOf(b)
  local pw = math.min(w + 2, root:getWidth() - 2)
  popupFrame:setWidth(math.max(pw, 6))
  popupFrame:setHeight(GLYPH_H)
  popupFrame:setX(math.max(1, math.floor((root:getWidth() - popupFrame:getWidth()) / 2) + 1))
  popupFrame:setY(math.max(1, root:getHeight() - GLYPH_H - 1))
  popupLabel:setX(2)
  popupLabel:setY(1)
  popupLabel:setWidth(math.max(1, popupFrame:getWidth() - 2))
  popupLabel:setImage(b)
  showFrame(popupFrame, true)
  after(seconds or 2.5, function()
    showFrame(popupFrame, false)
  end)
end

-- ============================================================================
-- Timer dispatch
-- ============================================================================

-- A user callback must not take the event loop down.  Basalt pcall-wraps its
-- own frame dispatch, but a callback registered with basalt.onEvent runs
-- unprotected, so an error here would abort the rest of that event.  Catch it
-- and surface it instead of failing silently.
local function onTimer(id)
  local fn = timerHandlers[id]
  if not fn then return end
  timerHandlers[id] = nil
  local ok, err = pcall(fn)
  if not ok then
    pcall(notify, "timer: " .. tostring(err), 4)
  end
end

-- ============================================================================
-- Playback state (mirrored from speakerlib events)
-- ============================================================================

local function fmtClock(seconds)
  local total = math.floor(tonumber(seconds) or 0)
  if total < 0 then total = 0 end
  return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

local function playerLabelText()
  if not player.title then return S.not_playing end
  local text = S.now_playing_prefix .. player.title
  if player.total and player.total > 0 then
    text = text .. "  " .. fmtClock(player.progress) .. "/" .. fmtClock(player.total)
  end
  if player.paused then
    text = text .. "  [" .. S.paused_flag .. "]"
  elseif not player.playing and not player.stopped then
    text = text .. "  " .. S.buffering
  end
  return text
end

-- Push the mirrored state into the player bar.
local function refreshPlayerUI()
  if playerTitle then
    playerTitle:setImage(bmp(playerLabelText()))
  end
  if playPauseButton then
    local icon = (player.playing and not player.paused) and "icons.PauseCircle" or "icons.PlayCircle"
    local ok, ib = pcall(require, icon)
    if ok and type(ib) == "table" then playPauseButton:setImage(ib) end
  end
end

-- Run the speaker program for `url` in a Basalt-scheduled coroutine.  shell.run
-- blocks that coroutine, not the UI: Basalt resumes it as events arrive, so the
-- Basalt event loop keeps running and already-queued speakerlib events reach the
-- client's own handlers.
local function scheduleSpeaker(url, song)
  player.title = (song and song.name) or player.title
  player.total = 0
  player.progress = 0
  player.ready = false
  player.playing = false
  player.paused = false
  player.stopped = false
  player.format = nil
  refreshPlayerUI()

  local can, why = data.canPlay()
  if not can then
    player.stopped = true
    notify(why or S.no_speaker)
    refreshPlayerUI()
    return
  end

  launchSeq = launchSeq + 1
  local mySeq = launchSeq
  if type(basalt.schedule) ~= "function" then
    player.stopped = true
    notify(S.play_failed .. ": background scheduler unavailable")
    refreshPlayerUI()
    return
  end
  basalt.schedule(function()
    local ok, err = data.runSpeaker(url)
    -- -noui means the speaker never paints, but if it ever did (or another
    -- program shared the terminal) repaint the whole frame rather than leaving
    -- stale cells behind.
    forceFullRedraw()
    if not ok and mySeq == launchSeq then
      pcall(notify, S.play_failed .. ": " .. tostring(err), 4)
      player.stopped = true
      player.playing = false
      pcall(refreshPlayerUI)
    end
  end)
end

-- Apply a parsed speakerlib_state payload (progress/total/volume/paused/mode/
-- format) to the mirrored state.
local function applySpeakerState(st)
  if type(st) ~= "table" then return end
  if st.total ~= nil then player.total = tonumber(st.total) or player.total end
  if st.progress ~= nil then player.progress = tonumber(st.progress) or player.progress end
  if st.volume ~= nil then player.volume = tonumber(st.volume) or player.volume end
  if st.paused ~= nil then player.paused = st.paused and true or false end
  if st.playing ~= nil then player.playing = st.playing and true or false end
  if st.format ~= nil then player.format = st.format end
  if st.stopped then player.stopped = true; player.playing = false end
  if st.finished then player.stopped = true; player.playing = false end
  refreshPlayerUI()
end

-- Register one speakerlib event handler.  A nil id is tolerated (some emitters
-- omit it) but an id for another player is ignored.
local function onSpeakerEvent(name, fn)
  basalt.onEvent(name, function(id, a, b)
    if id ~= nil and id ~= data.SPEAKER_ID then return end
    local ok, err = pcall(fn, a, b)
    if not ok then pcall(notify, name .. ": " .. tostring(err), 3) end
  end)
end

local function registerSpeakerEvents()
  onSpeakerEvent("speakerlib_downloading", function()
    player.ready = false; player.playing = false; player.stopped = false
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_ready", function(format, total)
    player.ready = true
    player.format = format
    player.total = tonumber(total) or player.total
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_start", function()
    player.playing = true; player.paused = false; player.stopped = false
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_pause", function()
    player.paused = true; refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_resume", function()
    player.paused = false; player.playing = true; refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_end", function()
    player.playing = false; player.stopped = true; refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_stop", function()
    player.playing = false; player.stopped = true
    refreshPlayerUI()
    local pend = pendingLaunch
    pendingLaunch = nil
    if pend then
      if pend.timerId then pcall(os.cancelTimer, pend.timerId) end
      scheduleSpeaker(pend.url, pend.song)
    end
  end)
  -- speakerlib_state is JSON, so parse it instead of using the (id, a, b) shape.
  basalt.onEvent("speakerlib_state", function(id, json)
    if id ~= nil and id ~= data.SPEAKER_ID then return end
    local ok, st = pcall(textutils.unserializeJSON, json)
    if ok and type(st) == "table" then pcall(applySpeakerState, st) end
  end)
end

-- Player controls.  Each queues the matching speakerlib control event with the
-- client's id; the player UI updates only when speakerlib acknowledges.
function M.playerToggle()
  if not player.title then return end
  if player.paused then data.resumeSpeaker() else data.pauseSpeaker() end
end

function M.playerStop()
  data.stopSpeaker()
  pendingLaunch = nil
  player.stopped = true
  player.playing = false
  player.paused = false
  player.title = nil
  refreshPlayerUI()
end

function M.playerSeek(delta)
  if not player.title then return end
  local target = (tonumber(player.progress) or 0) + (tonumber(delta) or 0)
  if target < 0 then target = 0 end
  if player.total and player.total > 0 and target > player.total then target = player.total end
  player.progress = target
  data.seekSpeaker(target)
  refreshPlayerUI()
end

function M.playerVolumeCycle()
  local levels = { 0, 1, 2, 3 }
  local current = tonumber(player.volume) or 1
  local nextLevel = 0
  for i = 1, #levels do
    if levels[i] > current then
      nextLevel = levels[i]
      break
    end
    if i == #levels then nextLevel = 0 end
  end
  player.volume = nextLevel
  data.setSpeakerVolume(nextLevel)
  notify(S.volume .. ": " .. tostring(nextLevel), 1.2)
  refreshPlayerUI()
end

-- The exact text currently shown in the player bar (same source as the label).
function M.playerLabel()
  return playerLabelText()
end

-- Verification/debug accessor for the mirrored state (read-only copy).
function M.playerState()
  return {
    title = player.title,
    total = player.total,
    progress = player.progress,
    volume = player.volume,
    paused = player.paused,
    playing = player.playing,
    ready = player.ready,
    stopped = player.stopped,
    format = player.format,
  }
end

-- ============================================================================
-- Recent-play history (CC serializer, no hand-written JSON)
-- ============================================================================

local function loadRecent()
  if not fs.exists(RECENT_FILE) then return {} end
  local f = fs.open(RECENT_FILE, "r")
  if not f then return {} end
  local raw = f.readAll()
  f.close()
  local ok, list = pcall(textutils.unserialize, raw)
  if ok and type(list) == "table" then return list end
  return {}
end

local function saveRecent(list)
  local f = fs.open(RECENT_FILE, "w")
  if not f then return end
  f.write(textutils.serialize(list))
  f.close()
end

local function addRecent(song)
  local list = loadRecent()
  local out = { song }
  for _, s in ipairs(list) do
    if s.id ~= song.id and #out < 50 then out[#out + 1] = s end
  end
  saveRecent(out)
end

-- ============================================================================
-- List item factories
-- ============================================================================

local function songItems(songs)
  local items = {}
  for i, s in ipairs(songs) do
    local label = i .. ". " .. s.name
    if s.artist ~= "" then label = label .. " - " .. s.artist end
    if s.duration > 0 then label = label .. "  " .. data.formatTime(s.duration) end
    local index = i
    items[i] = {
      image = bmp(label),
      bg = colors.black,
      fg = colors.white,
      selectedBg = colors.pink,
      selectedFg = colors.white,
      callback = function()
        currentQueue = songs
        currentIndex = index
        M.playSong(songs[index])
      end,
    }
  end
  return items
end

local function playlistItems(pls)
  local items = {}
  for i, p in ipairs(pls) do
    local label = i .. ". " .. p.name
    if p.count and p.count > 0 then
      label = label .. " (" .. p.count .. S.songs_count .. ")"
    end
    items[i] = {
      image = bmp(label),
      bg = colors.black,
      fg = colors.white,
      selectedBg = colors.purple,
      selectedFg = colors.white,
      callback = function()
        M.openPlaylist(p)
      end,
    }
  end
  return items
end

-- ============================================================================
-- Content helpers
-- ============================================================================

local function setContent(titleText, items)
  currentTitle = titleText or ""
  currentItems = items or {}
  pageTitle:setImage(bmp(currentTitle))
  contentList:setItems(currentItems)
  pcall(function() contentList:scrollToTop() end)
  pcall(function() contentList:clearItemSelection() end)
end

local function showPage(titleText, items)
  history = {}
  setContent(titleText, items)
end

function M.openPlaylist(p)
  local songs, err = data.playlistSongs(p.id, 300)
  if not songs then
    notify(err or S.loading_failed)
    return
  end
  if #songs == 0 then
    notify(S.no_data)
    return
  end
  history[#history + 1] = { title = currentTitle, items = currentItems }
  setContent(p.name, songItems(songs))
end

local function goBack()
  local prev = table.remove(history)
  if prev then setContent(prev.title, prev.items) end
end

-- ============================================================================
-- Playback
-- ============================================================================

function M.playSong(song)
  if type(song) ~= "table" then return end
  if not data.available then
    notify(S.network_error)
    return
  end

  local url, _, err = data.songUrl(song.id, "lossless")
  if not url then
    url, _, err = data.songUrl(song.id, "standard")
  end
  if not url then
    notify(S.play_failed .. ": " .. tostring(err))
    player.title = nil
    player.stopped = true
    refreshPlayerUI()
    return
  end

  addRecent(song)

  -- A speaker is already active: stop it first and remember this song for the
  -- speakerlib_play_stop handler.  The id is shared, so the stale stop event
  -- must be consumed before the next instance starts.
  if player.playing or player.ready or pendingLaunch then
    local token = {}
    pendingLaunch = { url = url, song = song, token = token }
    data.stopSpeaker()
    pendingLaunch.timerId = after(3, function()
      local pend = pendingLaunch
      if pend and pend.token == token then
        pendingLaunch = nil
        scheduleSpeaker(url, song)
      end
    end)
    return
  end

  scheduleSpeaker(url, song)
end

local function playQueueOffset(delta)
  if #currentQueue == 0 then
    notify(S.no_data)
    return
  end
  local i = currentIndex + delta
  if i < 1 then i = #currentQueue end
  if i > #currentQueue then i = 1 end
  currentIndex = i
  M.playSong(currentQueue[i])
end

-- ============================================================================
-- Pages
-- ============================================================================

local function requireLogin()
  local st = data.session or {}
  if st.state == "in" then return false end
  if st.state == "unknown" then
    notify(S.network_error)
    return true
  end
  notify(S.need_login)
  return true
end

local function pageHome()
  local pls, err = data.personalized()
  if not pls then notify(err or S.loading_failed) return end
  if #pls == 0 then notify(S.no_data) return end
  showPage(S.recommend_playlists, playlistItems(pls))
end

local function pageDiscover()
  local pls, err = data.toplist()
  if not pls then notify(err or S.loading_failed) return end
  if #pls == 0 then notify(S.no_data) return end
  showPage(S.toplists, playlistItems(pls))
end

local function pageRoam()
  -- The anonymous endpoint returns a usable daily list, so don't gate this.
  local songs, err = data.dailySongs()
  if not songs then notify(err or S.loading_failed) return end
  if #songs == 0 then notify(S.no_data) return end
  showPage(S.daily_songs, songItems(songs))
end

local function pagePodcast()
  notify(S.podcast_todo)
end

local function pageLike()
  if requireLogin() then return end
  local profile, err = data.account()
  if not profile then notify(err or S.loading_failed) return end
  local songs, err2 = data.likedSongs(profile.userId)
  if not songs then notify(err2 or S.loading_failed) return end
  if #songs == 0 then notify(S.no_data) return end
  showPage(S.my_like, songItems(songs))
end

local function pageFavorite()
  if requireLogin() then return end
  local profile, err = data.account()
  if not profile then notify(err or S.loading_failed) return end
  local pls, err2 = data.userPlaylist(profile.userId)
  if not pls then notify(err2 or S.loading_failed) return end
  if #pls == 0 then notify(S.no_data) return end
  showPage(S.my_playlists, playlistItems(pls))
end

local function pageRecent()
  local list = loadRecent()
  if #list == 0 then notify(S.no_data) return end
  showPage(S.recent_play, songItems(list))
end

local PAGES = {
  home = pageHome,
  discover = pageDiscover,
  roam = pageRoam,
  podcast = pagePodcast,
  like = pageLike,
  favorite = pageFavorite,
  recent = pageRecent,
}

local function doSearch()
  local kw = searchInput:getText()
  if type(kw) ~= "string" or kw == "" then
    notify(S.search_hint)
    return
  end
  local songs, err = data.search(kw, 30)
  if not songs then notify(err or S.loading_failed) return end
  if #songs == 0 then notify(S.no_data) return end
  showPage(S.search_result .. ": " .. kw, songItems(songs))
end

local function switchPage(key)
  local fn = PAGES[key]
  if fn then fn() end
end

-- ============================================================================
-- Login (QR) and verified login state
-- ============================================================================

local function updateUserLabel()
  local st = data.session or {}
  local label = S.login
  if st.state == "in" then
    label = st.nickname or S.user
  elseif st.state == "unknown" then
    -- The cookie could not be verified: never render this as logged out.
    label = st.nickname or S.user
  end
  lastUserLabel = label
  userButton:setImage(bmp(label))
end

-- One-line startup diagnostic: cookie present? bytes? MUSIC_U? state + uid.
local function loginDiagnostic()
  local info = data.cookieInfo()
  local st = data.session or {}
  return string.format(
    "login: cookie=%s bytes=%d MUSIC_U=%s state=%s uid=%s",
    info.present and "yes" or "no",
    info.bytes,
    info.musicU and "yes" or "no",
    tostring(st.state),
    tostring(st.uid)
  )
end

-- Re-resolve the session through the single data.session state.
--   "in"      -> user area shows the nickname
--   "out"     -> user area shows the login label
--   "unknown" -> keep the cookie, surface the error, retry later
local function refreshLoginState(opts)
  opts = opts or {}
  local st, err = data.resolveSession()
  updateUserLabel()
  if opts.notify and st.state == "unknown" and err then
    notify(S.network_error .. ": " .. tostring(err), 4)
  end
  return st.state
end

local function stopLoginPoll()
  loginPolling = false
  loginKey = nil
end

local function setLoginStatus(text)
  loginStatus:setImage(bmp(text))
end

local function pollLogin()
  if not loginPolling or not loginKey then return end
  local code, cookie = data.qrCheck(loginKey)
  if code == 803 then
    stopLoginPoll()
    local saved, saveErr = data.saveCookie(cookie)
    if saved then
      setLoginStatus(S.scan_success)
      -- Re-verify immediately, refresh nickname/uid, then close the panel.
      refreshLoginState()
      if (data.session or {}).state ~= "in" then
        -- The server can lag a moment behind the confirmation; retry briefly.
        after(1, function() refreshLoginState() end)
        after(2.5, function() refreshLoginState() end)
      end
      after(1.2, function() showFrame(loginFrame, false) end)
    else
      setLoginStatus(S.scan_failed .. ": " .. tostring(saveErr))
    end
    return
  elseif code == 800 then
    stopLoginPoll()
    setLoginStatus(S.scan_expired)
    return
  elseif code == 802 then
    setLoginStatus(S.scan_scanned)
  elseif code == nil then
    setLoginStatus(S.network_error)
  else
    setLoginStatus(S.scan_wait)
  end
  after(1.5, pollLogin)
end

local function startLogin()
  stopLoginPoll()
  setLoginStatus(S.loading)
  local key, err = data.qrKey()
  if not key then
    setLoginStatus(S.scan_failed .. ": " .. tostring(err))
    return
  end
  loginKey = key
  local url = data.qrUrl(key)
  local okQr, qbimg = pcall(qr.toBimg, url, { ecl = "L", border = 1 })
  if not okQr or type(qbimg) ~= "table" then
    setLoginStatus(S.scan_failed)
    return
  end
  local qw, qh = bimg.widthOf(qbimg), bimg.heightOf(qbimg)

  -- Resize and centre the panel around the code.
  local pw = math.min(qw + 6, root:getWidth() - 2)
  local ph = math.min(qh + 7, root:getHeight() - 2)
  loginFrame:setWidth(pw)
  loginFrame:setHeight(ph)
  loginFrame:setX(math.max(1, math.floor((root:getWidth() - pw) / 2) + 1))
  loginFrame:setY(math.max(1, math.floor((root:getHeight() - ph) / 2) + 1))

  loginQrLabel:setWidth(qw)
  loginQrLabel:setHeight(qh)
  loginQrLabel:setX(math.max(1, math.floor((pw - qw) / 2) + 1))
  loginQrLabel:setY(1)
  loginQrLabel:setImage(qbimg)

  loginStatus:setX(1)
  loginStatus:setY(math.min(qh + 1, ph - 3))
  loginStatus:setWidth(pw)
  loginStatus:setImage(bmp(S.scan_hint))

  local bw = math.max(6, math.floor((pw - 6) / 2))
  loginRefresh:setX(2)
  loginRefresh:setY(ph - 3)
  loginRefresh:setWidth(bw)
  loginCancel:setX(pw - bw - 1)
  loginCancel:setY(ph - 3)
  loginCancel:setWidth(bw)

  showFrame(loginFrame, true)
  loginPolling = true
  after(1.5, pollLogin)
end

local function openLogin()
  startLogin()
end

local function openLogout()
  data.logout()
  updateUserLabel()
  notify(S.logout)
end

-- Read-only accessors for the pages and the verification harness.
function M.loginState()
  local st = data.session or {}
  local info = data.cookieInfo()
  return {
    state = st.state,
    loggedIn = st.state == "in",
    nickname = st.nickname,
    uid = st.uid,
    hasCookie = info.present,
    cookieBytes = info.bytes,
    musicU = info.musicU,
  }
end

function M.loginDiagnostic()
  return loginDiagnostic()
end

function M.refreshLoginState(opts)
  return refreshLoginState(opts)
end

-- Harness accessors: whether the QR overlay is shown / polling, the label text
-- currently on the user button, and a way to open the QR panel like a click.
function M.loginPanelVisible()
  return loginFrame ~= nil and loginFrame.visible and true or false
end

function M.loginPolling()
  return loginPolling and true or false
end

function M.userLabel()
  return lastUserLabel
end

function M.startLogin()
  startLogin()
end

-- ============================================================================
-- Build
-- ============================================================================

local function buildLayout()
  root = basalt.getMainFrame()
  root:setBackground(colors.black)
  local W, H = root:getWidth(), root:getHeight()

  GLYPH_H = bimg.glyphHeight()

  local NAV_W = 16
  local TOP_H = 4
  -- Two text rows: the now-playing line and the control row underneath it.
  local PLAYER_H = GLYPH_H * 2
  local contentX = NAV_W + 1
  local contentW = W - NAV_W
  local midH = H - PLAYER_H

  -- Left navigation ------------------------------------------------------
  navFrame = root:addFrame({
    x = 1, y = 1, width = NAV_W, height = midH,
    background = colors.gray,
  })
  navFrame:addLabel({
    x = 1, y = 1, width = NAV_W, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.purple, background = colors.gray,
  }):setImage(bmp(S.app_title))

  navList = navFrame:addList({
    x = 1, y = GLYPH_H + 1, width = NAV_W, height = midH - GLYPH_H,
    background = colors.gray, foreground = colors.white,
    selectedBackground = colors.pink, selectedForeground = colors.white,
    showScrollBar = true,
  })

  local navDefs = {
    { key = "home", label = S.nav_home, icon = "icons.Home" },
    { key = "discover", label = S.nav_discover, icon = "icons.Discover" },
    { key = "roam", label = S.nav_roam, icon = "icons.Roaming" },
    { key = "podcast", label = S.nav_podcast, icon = "icons.Podcast" },
    { key = "like", label = S.nav_like, icon = "icons.Like" },
    { key = "favorite", label = S.nav_favorite, icon = "icons.Favorite" },
    { key = "recent", label = S.nav_recent, icon = "icons.Recently" },
  }
  local navItems = {}
  for _, def in ipairs(navDefs) do
    local ok, icon = pcall(require, def.icon)
    local image
    if ok and type(icon) == "table" then
      image = CIMG(icon, bmp(" " .. def.label))
    else
      image = bmp(def.label)
    end
    navItems[#navItems + 1] = {
      image = image,
      bg = colors.gray, fg = colors.white,
      selectedBg = colors.pink, selectedFg = colors.white,
      callback = function() switchPage(def.key) end,
    }
  end
  navList:setItems(navItems)

  -- Top bar --------------------------------------------------------------
  topFrame = root:addFrame({
    x = contentX, y = 1, width = contentW, height = TOP_H,
    background = colors.black,
  })

  pageTitle = topFrame:addLabel({
    x = 1, y = 1, width = contentW - 18, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.black,
  })
  pageTitle:setImage(bmp(S.app_title))

  backButton = topFrame:addButton({
    x = contentW - 17, y = 1, width = 6, height = GLYPH_H,
    foreground = colors.white, background = colors.black,
  })
  backButton:setImage(bmp(S.back))
  backButton:onClick(goBack)

  userButton = topFrame:addButton({
    x = contentW - 11, y = 1, width = 11, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  userButton:setImage(bmp(S.login))
  userButton:onClick(function()
    local st = data.session or {}
    if st.state == "in" then
      openLogout()
    elseif st.state == "unknown" then
      -- Verification failed earlier: retry instead of logging in again.
      refreshLoginState({ notify = true })
    else
      -- Confirmed logged out (or no cookie): the QR panel opens on request.
      openLogin()
    end
  end)

  searchInput = topFrame:addInput({
    x = 1, y = GLYPH_H + 1, width = contentW - 7, height = 1,
    background = colors.lightGray, foreground = colors.black,
    placeholder = S.search_placeholder, placeholderColor = colors.gray,
  })
  searchInput:onSubmit(function() doSearch() end)

  topFrame:addButton({
    x = contentW - 6, y = GLYPH_H + 1, width = 7, height = 1,
    foreground = colors.white, background = colors.pink,
  }):setImage(bmp(S.search)):onClick(doSearch)

  -- Content --------------------------------------------------------------
  contentFrame = root:addFrame({
    x = contentX, y = TOP_H + 1, width = contentW,
    height = H - TOP_H - PLAYER_H,
    background = colors.black,
  })
  contentList = contentFrame:addList({
    x = 1, y = 1, width = contentW, height = H - TOP_H - PLAYER_H,
    background = colors.black, foreground = colors.white,
    selectedBackground = colors.pink, selectedForeground = colors.white,
    showScrollBar = true,
  })

  -- Player ---------------------------------------------------------------
  playerFrame = root:addFrame({
    x = 1, y = H - PLAYER_H + 1, width = W, height = PLAYER_H,
    background = colors.gray,
  })
  playerTitle = playerFrame:addLabel({
    x = 2, y = 1, width = W - 2, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.gray,
  })
  playerTitle:setImage(bmp(S.not_playing))

  -- One control row under the title.  The controls only queue speakerlib
  -- events; speakerlib acknowledges each with speakerlib_play_* / _state, which
  -- is what actually moves the UI.
  local ctrlY = GLYPH_H + 1
  local function addCtrl(x, label, icon, fn)
    local b = playerFrame:addButton({
      x = x, y = ctrlY, width = 4, height = GLYPH_H,
      foreground = colors.purple, background = colors.gray,
    })
    if icon then
      local ok, ib = pcall(require, icon)
      if ok and type(ib) == "table" then
        b:setImage(ib)
      else
        b:setImage(bmp(label or ""))
      end
    else
      b:setImage(bmp(label or ""))
    end
    if fn then b:onClick(fn) end
    return b
  end
  local nCtrl, ctrlW, ctrlGap = 7, 4, 1
  local ctrlTotal = nCtrl * ctrlW + (nCtrl - 1) * ctrlGap
  local ctrlX = math.max(2, math.floor((W - ctrlTotal) / 2) + 1)
  local function ctrlPos(i) return ctrlX + (i - 1) * (ctrlW + ctrlGap) end

  addCtrl(ctrlPos(1), "-10", nil, function() M.playerSeek(-10) end)
  addCtrl(ctrlPos(2), nil, "icons.PreviousSong", function() playQueueOffset(-1) end)
  playPauseButton = addCtrl(ctrlPos(3), nil, "icons.PlayCircle", function() M.playerToggle() end)
  addCtrl(ctrlPos(4), nil, "icons.NextSong", function() playQueueOffset(1) end)
  addCtrl(ctrlPos(5), "+10", nil, function() M.playerSeek(10) end)
  addCtrl(ctrlPos(6), "VOL", nil, function() M.playerVolumeCycle() end)
  addCtrl(ctrlPos(7), "STOP", nil, function() M.playerStop() end)

  -- Popup -----------------------------------------------------------------
  popupFrame = root:addFrame({
    x = 1, y = H - GLYPH_H - 1, width = 20, height = GLYPH_H,
    background = colors.purple, visible = false, enabled = false,
  })
  popupLabel = popupFrame:addLabel({
    x = 2, y = 1, width = 18, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.purple,
  })

  -- Login overlay ---------------------------------------------------------
  loginFrame = root:addFrame({
    x = 1, y = 1, width = 28, height = 18,
    background = colors.gray, visible = false, enabled = false,
  })
  loginQrLabel = loginFrame:addLabel({
    x = 1, y = 1, width = 18, height = 12,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.black, background = colors.white,
  })
  loginStatus = loginFrame:addLabel({
    x = 1, y = 13, width = 28, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.gray,
  })
  loginRefresh = loginFrame:addButton({
    x = 2, y = 15, width = 8, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  loginRefresh:setImage(bmp(S.refresh))
  loginRefresh:onClick(function() startLogin() end)
  loginCancel = loginFrame:addButton({
    x = 13, y = 15, width = 8, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  loginCancel:setImage(bmp(S.cancel))
  loginCancel:onClick(function()
    stopLoginPoll()
    showFrame(loginFrame, false)
  end)
end

-- ============================================================================
-- Entry points
-- ============================================================================

function M.build()
  local okFont, ferr = loadFontSafe()
  if not okFont then
    return false, "font: " .. tostring(ferr)
  end
  local okN, nerr = data.init()
  if not okN then
    return false, tostring(nerr)
  end

  -- Resolve the session synchronously BEFORE the UI gates are built, so the
  -- very first paint already knows whether the user is logged in (previously
  -- the account was only checked ~0.3 s after the layout existed).
  data.resolveSession()

  buildLayout()
  registerSpeakerEvents()

  basalt.onEvent("timer", onTimer)
  showPage(S.recommend_playlists, {})
  -- Load the default page once the UI is on screen, so a slow network never
  -- delays the first paint.
  after(0.2, function() switchPage("home") end)

  -- One-line startup login diagnostic, routed through the log/notify path.
  local diag = loginDiagnostic()
  if basalt.LOGGER and type(basalt.LOGGER.info) == "function" then
    pcall(basalt.LOGGER.info, diag)
  end
  notify(diag, 6)
  return true
end

function M.run()
  basalt.run()
end

return M
