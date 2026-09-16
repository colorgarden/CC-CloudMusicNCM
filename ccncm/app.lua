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
local playerFrame, playerTitle
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
  playerTitle:setImage(bmp(S.now_playing_prefix .. song.name))
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
    playerTitle:setImage(bmp(S.not_playing))
    return
  end

  addRecent(song)
  local ok, lerr = data.launchSpeaker(url)
  forceFullRedraw()
  if not ok then
    notify(tostring(lerr))
    playerTitle:setImage(bmp(S.not_playing))
  else
    playerTitle:setImage(bmp(S.stopped))
  end
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
  if data.cookie then return false end
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
-- Login (QR)
-- ============================================================================

local function refreshUserLabel()
  local label = S.login
  if data.cookie then
    local profile = data.account()
    if profile and profile.nickname then label = profile.nickname end
  end
  userButton:setImage(bmp(label))
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
    if data.saveCookie(cookie) then
      setLoginStatus(S.scan_success)
      refreshUserLabel()
      after(1.2, function() showFrame(loginFrame, false) end)
    else
      setLoginStatus(S.scan_failed)
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
  data.clearCookie()
  refreshUserLabel()
  notify(S.logout)
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
  local PLAYER_H = GLYPH_H + 1
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
    if data.cookie then
      openLogout()
    else
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
    x = 2, y = 1, width = W - 20, height = GLYPH_H,
    autoSize = false, backgroundEnabled = true,
    foreground = colors.white, background = colors.gray,
  })
  playerTitle:setImage(bmp(S.not_playing))

  local ctrlY = 1
  local function ctrlButton(x, icon, fn)
    local b = playerFrame:addButton({
      x = x, y = ctrlY, width = 4, height = GLYPH_H,
      foreground = colors.purple, background = colors.gray,
    })
    local ok, ib = pcall(require, icon)
    if ok and type(ib) == "table" then b:setImage(ib) end
    if fn then b:onClick(fn) end
  end
  local ctrlX = math.max(2, W - 15)
  ctrlButton(ctrlX, "icons.PreviousSong", function() playQueueOffset(-1) end)
  ctrlButton(ctrlX + 5, "icons.PlayCircle", function() playQueueOffset(0) end)
  ctrlButton(ctrlX + 10, "icons.NextSong", function() playQueueOffset(1) end)

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

  buildLayout()

  basalt.onEvent("timer", onTimer)
  showPage(S.recommend_playlists, {})
  -- Load the default page once the UI is on screen, so a slow network never
  -- delays the first paint.  The account check is deferred for the same
  -- reason: it must not block boot when a cookie is present.
  after(0.2, function() switchPage("home") end)
  after(0.3, refreshUserLabel)
  return true
end

function M.run()
  basalt.run()
end

return M
