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
local topFrame, pageTitle, backButton, userButton, searchInput, searchButton
local contentFrame, contentList
local playerFrame, playerTitle, playPauseButton
local popupFrame, popupLabel
local loginFrame, loginQrLabel, loginStatus, loginRefresh, loginCancel
local logoutFrame, logoutLabel, logoutConfirm, logoutCancel, logoutBackdrop

local timerHandlers = {}
local currentQueue = {}
local currentIndex = 0
local history = {}
local currentItems = {}
local currentTitle = ""
local currentPageKey = nil

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
-- the next song is launched with the same id.  Holding the queued song here (and
-- never launching it anywhere else) is what stops a burst of stop/end events
-- from spawning more than one instance.
local pendingLaunch = nil
local launchSeq = 0
-- Launch sequence of the instance we believe is running.  Every launch takes a
-- new value.  speakerlib events carry this client's *shared* id, not a per-run
-- one, so the sequence is how we tell a current acknowledgement apart from a
-- late one belonging to an instance we already gave up on.
local activeSeq = 0
-- Sequence of the instance we have asked to stop.  Cleared once its
-- speakerlib_play_stop/_play_end arrives; if that never happens the 4 s safety
-- timer moves on and a mismatched value marks the later event as stale.
local stopRequestSeq = nil
-- True from scheduleSpeaker() until the instance emits a terminal event.  This
-- is what makes a song change stop the previous one even while it is still
-- downloading (when neither playing nor ready is set yet).
local speakerAlive = false
-- Bounded wait for the old instance to acknowledge speakerlib_stop.
local STOP_ACK_TIMEOUT = 4

local GLYPH_H = 3

-- The user (login) button is the rightmost widget in the top bar.  It never
-- shrinks below the historical 11 cells, so a longer nickname is not clipped
-- worse than before.
local USER_BTN_MIN_W = 11

-- Logout confirmation dialog state (the widgets are built in buildLayout).
local logoutConfirmOpen = false
local logoutShownCount = 0
local lastLogoutQuestion = nil

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
  if type(b) == "string" then
    -- The monitor exists only to show the UI; every notification-backed message
    -- (errors included) is mirrored to the computer's own terminal as a log.
    pcall(data.printNative, "notice: " .. b)
    b = bmp(b)
  end
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

-- Basalt's own LOGGER writes through the current terminal, which is the monitor
-- once the UI is redirected.  Wrap the human-facing levels so their output is
-- also written to the computer's own terminal.
local loggerRouted = false
local function routeLoggerToNative(logger)
  if loggerRouted or type(logger) ~= "table" then return end
  loggerRouted = true
  for _, level in ipairs({ "info", "warn", "error" }) do
    local orig = logger[level]
    if type(orig) == "function" then
      logger[level] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        pcall(data.printNative, "basalt." .. level .. ": " .. table.concat(parts, " "))
        return orig(...)
      end
    end
  end
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

-- The play/pause button icon, derived from the one mirrored state: a live,
-- unpaused song offers "pause", anything else (paused or stopped) offers "play".
local function playerIconName()
  return (player.playing and not player.paused) and "icons.PauseCircle" or "icons.PlayCircle"
end

-- Push the mirrored state into the player bar.
local function refreshPlayerUI()
  if playerTitle then
    playerTitle:setImage(bmp(playerLabelText()))
  end
  if playPauseButton then
    local ok, ib = pcall(require, playerIconName())
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
  speakerAlive = true
  refreshPlayerUI()

  local can, why = data.canPlay()
  if not can then
    speakerAlive = false
    player.stopped = true
    notify(why or S.no_speaker)
    refreshPlayerUI()
    return
  end

  launchSeq = launchSeq + 1
  local mySeq = launchSeq
  activeSeq = mySeq
  if type(basalt.schedule) ~= "function" then
    speakerAlive = false
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
      speakerAlive = false
      player.stopped = true
      player.playing = false
      player.ready = false
      player.paused = false
      pcall(refreshPlayerUI)
    end
  end)
end

-- True while a song is loaded and has not ended/stopped.  A pause/resume is only
-- meaningful in this window, so all three pause sources below funnel through
-- setPaused(), which no-ops outside it.
local function playbackLive()
  return player.title ~= nil and not player.stopped
end

-- Flip the single paused bit the UI reads.  Called from our own control events
-- (speakerlib_pause/_resume), from the program's acknowledgements
-- (speakerlib_play_pause/_play_resume) and from speakerlib_state's JSON, so all
-- three sources of truth land in the same place.
local function setPaused(paused)
  if not playbackLive() then return end
  player.paused = paused and true or false
  if not paused then player.playing = true end
  refreshPlayerUI()
end

-- Apply a parsed speakerlib_state payload (progress/total/volume/paused/mode/
-- format) to the mirrored state.  speakerlib_state is the periodic full snapshot
-- (stateEvent() in speaker.lua), so it is authoritative for `paused` too.
local function applySpeakerState(st)
  if type(st) ~= "table" then return end
  if st.total ~= nil then player.total = tonumber(st.total) or player.total end
  if st.progress ~= nil then player.progress = tonumber(st.progress) or player.progress end
  if st.volume ~= nil then player.volume = tonumber(st.volume) or player.volume end
  if st.format ~= nil then player.format = st.format end
  -- A stopped/finished snapshot wins outright: paused must not survive it.
  if st.stopped or st.finished then
    player.stopped = true
    player.playing = false
    player.ready = false
    player.paused = false
  else
    if st.paused ~= nil and playbackLive() then
      player.paused = st.paused and true or false
    end
    if st.playing ~= nil and playbackLive() then
      player.playing = st.playing and true or false
    end
  end
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

-- Drop the safety timer of a queued song change, if it has one.
local function cancelPendingTimer(pend)
  pend = pend or pendingLaunch
  if pend and pend.timerId then pcall(os.cancelTimer, pend.timerId) end
end

-- A launched instance emitted a terminal event.  If a song change is queued,
-- this event is its acknowledgement: consume the queue and start the song right
-- now.  scheduleSpeaker() is reached from nowhere else for a queued song, so a
-- burst of stop/end events can never launch two instances.
local function instanceStopped()
  speakerAlive = false
  stopRequestSeq = nil
  local pend = pendingLaunch
  if pend then
    pendingLaunch = nil
    cancelPendingTimer(pend)
    scheduleSpeaker(pend.url, pend.song)
  end
end

-- Shared handling for speakerlib_play_stop and speakerlib_play_end.  speaker.lua
-- sends exactly one of them per instance (controlLoop's stop branch sends
-- play_stop + stateEvent({stopped=true}); program end sends play_end unless the
-- stop branch already ran), so this is the single place an instance is retired.
local function onTerminalEvent()
  if pendingLaunch then
    -- The instance we asked to stop has acknowledged; release the queued song.
    instanceStopped()
    return
  end
  if stopRequestSeq ~= nil and stopRequestSeq ~= activeSeq then
    -- Late acknowledgement from an instance the safety timer already gave up on.
    -- A newer instance is alive, so do not overwrite its state.
    stopRequestSeq = nil
    return
  end
  stopRequestSeq = nil
  speakerAlive = false
  -- Clear the track like playerStop does, so the player bar shows the existing
  -- not-playing label instead of a title with a stale progress readout.
  player.title = nil
  player.playing = false
  player.ready = false
  player.stopped = true
  player.paused = false
  refreshPlayerUI()
end

local function registerSpeakerEvents()
  onSpeakerEvent("speakerlib_downloading", function()
    player.ready = false; player.playing = false; player.stopped = false
    player.paused = false
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_ready", function(format, total)
    player.ready = true
    player.stopped = false
    player.format = format
    player.total = tonumber(total) or player.total
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_start", function()
    player.playing = true; player.paused = false; player.stopped = false
    -- By the time a fresh instance starts, any outstanding request belonged to
    -- an older instance we already moved past; stop treating it as pending.
    if stopRequestSeq ~= nil and stopRequestSeq ~= activeSeq then stopRequestSeq = nil end
    refreshPlayerUI()
  end)
  onSpeakerEvent("speakerlib_play_pause", function() setPaused(true) end)
  onSpeakerEvent("speakerlib_play_resume", function() setPaused(false) end)
  -- Our own control events are a source of truth too: the play/pause button must
  -- flip as soon as we queue speakerlib_pause/_resume, not only on the
  -- acknowledgement.
  onSpeakerEvent("speakerlib_pause", function() setPaused(true) end)
  onSpeakerEvent("speakerlib_resume", function() setPaused(false) end)
  onSpeakerEvent("speakerlib_play_end", onTerminalEvent)
  onSpeakerEvent("speakerlib_play_stop", onTerminalEvent)
  -- speakerlib_state is JSON, so parse it instead of using the (id, a, b) shape.
  -- A malformed payload must not break the dispatcher: unserializeJSON and
  -- applySpeakerState are both pcall-wrapped.
  basalt.onEvent("speakerlib_state", function(id, json)
    if id ~= nil and id ~= data.SPEAKER_ID then return end
    local ok, st = pcall(textutils.unserializeJSON, json)
    if ok and type(st) == "table" then pcall(applySpeakerState, st) end
  end)
end

-- Player controls.  Each queues the matching speakerlib control event with the
-- client's id; the state flips on our own event and is confirmed by the
-- program's speakerlib_play_* acknowledgement.
function M.playerToggle()
  -- Pausing/resuming with nothing loaded is a no-op, not a state change.
  if not playbackLive() then return end
  if player.paused then data.resumeSpeaker() else data.pauseSpeaker() end
end

function M.playerStop()
  local pend = pendingLaunch
  pendingLaunch = nil
  cancelPendingTimer(pend)
  data.stopSpeaker()
  -- Keep the instance marked alive until its acknowledgement so a song chosen
  -- right after Stop waits for it instead of overlapping it.
  if speakerAlive then stopRequestSeq = activeSeq end
  player.stopped = true
  player.playing = false
  player.ready = false
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

-- The icon the play/pause button currently shows (same source as refreshPlayerUI).
function M.playerIcon()
  return playerIconName()
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

  -- A speaker instance is already alive (playing, ready, still downloading, or a
  -- previous change is queued): stop it first.  Only its own
  -- speakerlib_play_stop/_play_end may launch the queued song (see
  -- onTerminalEvent), so A->B->C ends with C alone.  The old instance is waited
  -- for so the previous audio really stops before the new one starts; if it
  -- never acknowledges, the bounded timer proceeds and logs on the terminal.
  if speakerAlive or pendingLaunch or player.playing or player.ready then
    cancelPendingTimer()
    local token = {}
    pendingLaunch = { url = url, song = song, token = token }
    stopRequestSeq = activeSeq
    data.stopSpeaker()
    pendingLaunch.timerId = after(STOP_ACK_TIMEOUT, function()
      local pend = pendingLaunch
      if not pend or pend.token ~= token then return end
      pendingLaunch = nil
      -- ASCII only: this is the computer's terminal log, not the monitor UI.
      pcall(data.printNative,
        "speaker: previous instance did not acknowledge stop within " ..
        STOP_ACK_TIMEOUT .. "s; starting the next song anyway")
      scheduleSpeaker(url, song)
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
  if fn then
    currentPageKey = key
    fn()
  end
end

-- ============================================================================
-- Login (QR) and verified login state
-- ============================================================================

-- Width of the user button for `label`: fit the label, but never below the
-- historical 11 cells and never so wide that it covers the back button (one
-- blank column is kept between them).
local function userButtonWidth(label)
  local w = bimg.widthOf(bmp(label or S.login))
  if w < USER_BTN_MIN_W then w = USER_BTN_MIN_W end
  local frameW = topFrame and topFrame:getWidth() or w
  local maxW = frameW
  if backButton then
    local backRight = backButton:getX() + backButton:getWidth() - 1
    maxW = frameW - backRight - 1
  end
  if maxW < USER_BTN_MIN_W then maxW = USER_BTN_MIN_W end
  if w > maxW then w = maxW end
  return w
end

-- Keep the user button flush against the top bar's right edge on row 1 (the
-- same row as the title and the back button).  Called whenever the label
-- changes, because the width follows the label.
local function layoutUserButton(label)
  local w = userButtonWidth(label)
  local frameW = topFrame and topFrame:getWidth() or w
  userButton:setWidth(w)
  userButton:setHeight(GLYPH_H)
  userButton:setX(math.max(1, frameW - w + 1))
  userButton:setY(1)
end

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
  layoutUserButton(label)
end

-- The drawn label is the UI's own record of what the user sees.  It only shows
-- an account (not the login/user placeholder) after a verification succeeded
-- with a nickname, which is the "cookie verified as logged-in" signal.
local function userShowsAccount()
  if lastUserLabel ~= nil and lastUserLabel ~= S.login and lastUserLabel ~= S.user then
    return true
  end
  local st = data.session or {}
  return type(st.nickname) == "string" and st.nickname ~= ""
end

-- ONE decision for a user-button click, derived from what the UI actually shows
-- plus the verified session -- never from a single mutable field that can go
-- stale:
--   live session ("in")            -> logout confirmation
--   verification failed ("unknown")-> retry verification (never the QR panel)
--   logged out but an account is still shown (stale state) -> logout confirmation
--   confirmed logged out ("out")   -> QR panel
local function userButtonAction()
  local st = data.session or {}
  if st.state == "in" then return "logout" end
  if st.state == "unknown" then return "retry" end
  if userShowsAccount() then return "logout" end
  return "login"
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
  local st, err = data.resolveSession({ pending = opts.pending })
  updateUserLabel()
  if opts.notify and st.state == "unknown" and err then
    notify(S.network_error .. ": " .. tostring(err), 4)
  end
  return st.state
end

-- After a confirmed login the session data is live; if the visible page was one
-- gated behind the login, re-run it so its content appears without a manual
-- click.  updateUserLabel() redraws the user area in every case.
local function refreshAfterLogin()
  updateUserLabel()
  if (currentPageKey == "like" or currentPageKey == "favorite") and PAGES[currentPageKey] then
    local fn = PAGES[currentPageKey]
    pcall(fn)
  end
end

local function stopLoginPoll()
  loginPolling = false
  loginKey = nil
end

local lastLoginStatus = nil
local function setLoginStatus(text)
  lastLoginStatus = text
  loginStatus:setImage(bmp(text))
end

-- The server can lag a few seconds behind the 803 confirmation, so a 200 that
-- still reports "no account" is inconclusive, not a logout.  Retry every 1.5 s
-- (bounded to ~15 s) and never settle on "out": the cookie stays on disk the
-- whole time and the state stays "unknown" until it is truly verified.
local verifyAttempts = 0
local verifyLoginTick
verifyLoginTick = function()
  verifyAttempts = verifyAttempts + 1
  local state = refreshLoginState({ pending = true })
  if state == "in" then
    local st = data.session or {}
    setLoginStatus(S.scan_success)
    data.printNative(string.format(
      "login: verified, state=in uid=%s nickname=%s",
      tostring(st.uid), tostring(st.nickname)))
    refreshAfterLogin()
    after(1.2, function() showFrame(loginFrame, false) end)
    return
  end
  if verifyAttempts < 10 then
    setLoginStatus(S.scan_verifying)
    after(1.5, verifyLoginTick)
  else
    -- Keep the cookie and the "unknown" state; the user may press refresh.
    setLoginStatus(S.network_error)
  end
end

local function beginLoginVerification()
  verifyAttempts = 0
  setLoginStatus(S.scan_verifying)
  data.printNative("login: QR confirmed, verifying session...")
  verifyLoginTick()
end

local function pollLogin()
  if not loginPolling or not loginKey then return end
  local code, cookie = data.qrCheck(loginKey)
  if code == 803 then
    stopLoginPoll()
    local saved, saveErr = data.saveCookie(cookie)
    if saved then
      setLoginStatus(S.scan_success)
      -- The same refresh the startup path runs: saveCookie -> refreshLoginState
      -- -> updateUserLabel, plus the session state and any gated page.  It keeps
      -- retrying until the endpoint catches up, instead of trusting the first
      -- (possibly stale) answer.
      beginLoginVerification()
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

-- Logout confirmation --------------------------------------------------------
-- A small centred modal.  Only the confirm button logs out; Cancel (or just
-- letting the dialog sit there) leaves the session and cookie untouched.  The
-- full-screen backdrop swallows every click outside the dialog, so the page
-- underneath can never be triggered while the confirmation is open.
local function showLogoutConfirm()
  local w = 26
  local h = GLYPH_H * 2 + 3
  logoutFrame:setWidth(w)
  logoutFrame:setHeight(h)
  logoutFrame:setX(math.max(1, math.floor((root:getWidth() - w) / 2) + 1))
  logoutFrame:setY(math.max(1, math.floor((root:getHeight() - h) / 2) + 1))
  logoutLabel:setWidth(math.max(1, w - 4))
  logoutLabel:setY(1)
  logoutConfirm:setY(GLYPH_H + 2)
  logoutCancel:setY(GLYPH_H + 2)
  logoutCancel:setX(math.max(1, w - logoutCancel:getWidth() - 1))
  logoutBackdrop:setWidth(root:getWidth())
  logoutBackdrop:setHeight(root:getHeight())
  logoutBackdrop:setX(1)
  logoutBackdrop:setY(1)
  lastLogoutQuestion = S.confirm_logout
  logoutConfirmOpen = true
  logoutShownCount = logoutShownCount + 1
  showFrame(logoutBackdrop, true)
  showFrame(logoutFrame, true)
end

local function hideLogoutConfirm()
  showFrame(logoutFrame, false)
  showFrame(logoutBackdrop, false)
  logoutConfirmOpen = false
end

local function confirmLogout()
  hideLogoutConfirm()
  data.logout()
  updateUserLabel()
  notify(S.logout)
end

local function cancelLogout()
  -- Close without touching the session or the cookie.
  hideLogoutConfirm()
end

local function openLogout()
  showLogoutConfirm()
end

-- The real click path (the button's onClick and the verification harness both
-- call this) so the behaviour under test is exactly the behaviour shipped.
local function onUserButtonClick()
  local action = userButtonAction()
  if action == "logout" then
    openLogout()
  elseif action == "retry" then
    -- Verification failed earlier: retry instead of logging in again.
    refreshLoginState({ notify = true })
  else
    -- Confirmed logged out (or no cookie): the QR panel opens on request.
    openLogin()
  end
  return action
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

function M.loginStatusText()
  return lastLoginStatus
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
-- Verification accessors (UI geometry / click behaviour)
-- ============================================================================

-- The user button's geometry relative to the top bar, plus the top bar's own
-- size and the button's absolute position, so the harness can assert the
-- right edge is flush and dispatch a real click at the button.
function M.userButtonGeometry()
  if not userButton then return nil end
  local x, y = userButton:getX(), userButton:getY()
  local w, h = userButton:getWidth(), userButton:getHeight()
  local fx = topFrame and topFrame:getX() or 0
  local fy = topFrame and topFrame:getY() or 0
  local fw = topFrame and topFrame:getWidth() or 0
  return {
    x = x, y = y, width = w, height = h,
    right = x + w - 1,
    frameWidth = fw,
    flush = (x + w - 1) == fw,
    globalX = fx + x - 1,
    globalY = fy + y - 1,
  }
end

-- Every top-bar box, so the harness can prove the user button does not overlap
-- the search input or the search button.
function M.topBarGeometry()
  local function box(el)
    if not el then return nil end
    local x, y = el:getX(), el:getY()
    local w, h = el:getWidth(), el:getHeight()
    return {
      x = x, y = y, width = w, height = h,
      right = x + w - 1, bottom = y + h - 1,
    }
  end
  return {
    frameWidth = topFrame and topFrame:getWidth() or 0,
    pageTitle = box(pageTitle),
    backButton = box(backButton),
    userButton = box(userButton),
    searchInput = box(searchInput),
    searchButton = box(searchButton),
  }
end

-- What a user-button click decides from the single source of truth.
function M.userButtonAction()
  return userButtonAction()
end

-- Run the exact click path the button uses and return the chosen action.
function M.clickUserButton()
  return onUserButtonClick()
end

function M.logoutConfirmVisible()
  return logoutConfirmOpen and true or false
end

function M.logoutConfirmShowCount()
  return logoutShownCount
end

function M.logoutConfirmQuestion()
  return lastLogoutQuestion
end

-- The confirmation dialog's boxes, so the harness can dispatch real clicks on
-- its buttons (coordinates are relative to the dialog frame; the frame itself
-- is a root child, so a button's absolute position is frame.x + button.x - 1).
function M.logoutDialogGeometry()
  local function box(el)
    if not el then return nil end
    local x, y = el:getX(), el:getY()
    local w, h = el:getWidth(), el:getHeight()
    return {
      x = x, y = y, width = w, height = h,
      right = x + w - 1, bottom = y + h - 1,
    }
  end
  return {
    frame = box(logoutFrame),
    label = box(logoutLabel),
    confirm = box(logoutConfirm),
    cancel = box(logoutCancel),
    backdrop = box(logoutBackdrop),
  }
end

function M.confirmLogout()
  confirmLogout()
end

function M.cancelLogout()
  cancelLogout()
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
    x = contentW - USER_BTN_MIN_W + 1, y = 1, width = USER_BTN_MIN_W, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  userButton:setImage(bmp(S.login))
  userButton:onClick(onUserButtonClick)

  searchInput = topFrame:addInput({
    x = 1, y = GLYPH_H + 1, width = contentW - 7, height = 1,
    background = colors.lightGray, foreground = colors.black,
    placeholder = S.search_placeholder, placeholderColor = colors.gray,
  })
  searchInput:onSubmit(function() doSearch() end)

  searchButton = topFrame:addButton({
    x = contentW - 6, y = GLYPH_H + 1, width = 7, height = 1,
    foreground = colors.white, background = colors.pink,
  })
  searchButton:setImage(bmp(S.search))
  searchButton:onClick(doSearch)

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

  -- Logout confirmation.  The backdrop is added just before the dialog and
  -- carries a high z, so while the dialog is open it is the first thing the
  -- root dispatches to and it swallows every click that misses the dialog.
  logoutBackdrop = root:addFrame({
    x = 1, y = 1, width = W, height = H,
    background = colors.black, visible = false, enabled = false, z = 500,
  })
  -- Registering the click makes the backdrop a mouse target: Basalt only
  -- dispatches an event to a frame that listens for it, and a silent click sink
  -- is exactly what stops a click outside the dialog reaching the page behind.
  logoutBackdrop:onClick(function() end)
  logoutFrame = root:addFrame({
    x = 1, y = 1, width = 26, height = GLYPH_H * 2 + 3,
    background = colors.gray, visible = false, enabled = false, z = 501,
  })
  logoutLabel = logoutFrame:addLabel({
    x = 2, y = 1, width = 22, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.gray,
  })
  logoutLabel:setImage(bmp(S.confirm_logout))
  logoutConfirm = logoutFrame:addButton({
    x = 2, y = GLYPH_H + 2, width = 8, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  logoutConfirm:setImage(bmp(S.confirm))
  logoutConfirm:onClick(confirmLogout)
  logoutCancel = logoutFrame:addButton({
    x = 16, y = GLYPH_H + 2, width = 8, height = GLYPH_H,
    foreground = colors.white, background = colors.pink,
  })
  logoutCancel:setImage(bmp(S.cancel))
  logoutCancel:onClick(cancelLogout)
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

  -- Multi-speaker notes are emitted by data.runSpeaker() when playback starts:
  -- all detected speakers are passed as ONE group (no drift), and >8 speakers
  -- warn there because Minecraft drops the extra streams.  Nothing to print at
  -- build time.

  -- Resolve the session synchronously BEFORE the UI gates are built, so the
  -- very first paint already knows whether the user is logged in (previously
  -- the account was only checked ~0.3 s after the layout existed).
  data.resolveSession()

  buildLayout()
  -- The user label is derived from the resolved session, so it must be applied
  -- once the button exists.  Without this the button stays on the "login" label
  -- even though data.session is already "in".
  updateUserLabel()
  registerSpeakerEvents()

  basalt.onEvent("timer", onTimer)
  showPage(S.recommend_playlists, {})
  -- Load the default page once the UI is on screen, so a slow network never
  -- delays the first paint.
  after(0.2, function() switchPage("home") end)

  -- One-line startup login diagnostic.  It is a log, not a UI element: it is
  -- written to the computer's own terminal (never the monitor) and Basalt's own
  -- logger is re-routed there too.
  routeLoggerToNative(basalt.LOGGER)
  data.printNative(loginDiagnostic())
  return true
end

function M.run()
  basalt.run()
end

return M
