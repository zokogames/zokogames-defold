--- ZokoGames SDK for Defold (HTML5).
--
-- How it works: the JS bridge (bridge_js.lua, embedded from web/zokogames_bridge.js) is evaluated once
-- with html5.run(). With our native extension (ext.manifest, src/, lib/web/) built into the game, JavaScript
-- pushes results straight into Lua (module `zokogames_native`) with no polling. Without the extension
-- (for example when the project was bundled without native extensions) calls go through html5.run and results are
-- polled from ZokoDefold.poll() every 50 ms. Outside HTML5 (editor, desktop) a Lua simulator answers.
--
-- Callbacks have the shape callback(err, result). `err` is nil on success, otherwise a table
-- { code = "...", message = "..." }. JS camelCase names map to snake_case:
-- SDK.game.gameplayStart() -> zokogames.game.gameplay_start().
-- Dictionaries you pass are JSON-encoded; an empty Lua table is sent as {}.

local bridge_source = require "zokogames.bridge_js"

local M = {}
M.VERSION = "1.7.0"
--- Every error code an SDK call can raise, grouped by module (the JS SDK's ERROR_CODES).
M.ERROR_CODES = {
	ad = { "adsDisabled", "unfilled", "adblock", "adCooldown", "other" },
	banner = { "bannersDisabled", "unfilled", "missingId", "notVisible", "noAvailableSizes", "notCreated", "videoAdPlaying", "invalidSize", "bannerCooldown", "maxRefreshReached", "other" },
	user = { "userNotAuthenticated", "userAlreadySignedIn", "userCancelled", "showAuthPromptInProgress", "showAccountLinkPromptInProgress", "rateLimited", "requestInProgress", "unexpectedError" },
	data = { "dataLimitExceeded", "dataModuleDisabled", "other" },
	store = { "catalogFetchFailed", "inventoryFetchFailed", "purchaseInitFailed", "purchaseInProgress", "purchaseCancelled", "consumeItemFailed", "itemNotConsumable", "itemNotInInventory", "insufficientItemQuantity", "userNotAuthenticated", "invalidArgument", "requestInProgress", "unexpectedError", "other" },
	room = { "notInRoom", "notHost", "payloadTooLarge", "stateTooLarge", "unknownMember", "rateLimited", "roomUnavailable", "invalidArgument" },
	general = { "sdkNotInitialized", "sdkNotLoaded", "sdkDisabled", "invalidArgument", "timeout" },
}
--- True when err (the first callback argument) carries the given code: zoko.is_error(err, "purchaseCancelled")
function M.is_error(err, code) return err ~= nil and err.code == code end
M.SDK_SCRIPT_URL = "https://sdk.zokogames.com/zokogames-sdk-v1.js"
M.ad, M.banner, M.game, M.user, M.data, M.store, M.analytics, M.achievements = {}, {}, {}, {}, {}, {}, {}, {}
--- Room data channel (SDK 1.3.0): zokogames.game.room, also reachable as zokogames.room.
M.game.room = {}
M.room = M.game.room

--- Simulator settings (non-HTML5 only). Change before calling init().
M.sim = {
	disabled = false,
	account_available = true,
	logged_in = true,
	username = "SimPlayer",
	user_id = "sim-user-1",
	friend_count = 12,
	ad_behaviour = "fill", -- "fill" | "no_fill" | "error"
	ad_duration = 1.5,
	adblock = false,
	mute_audio = false,
	offline = false,
	disable_chat = false,
	kids_mode = false, -- SDK 1.5.0: settings.kidsMode; like the portal it also turns chat off
	store_available = true,
	verbose = true,
}

M.environment = "disabled"
M.is_qa_tool = false
M.is_initialized = false
M.is_simulated = false
M.is_user_account_available = false
M.is_instant_multiplayer = false
--- True while the player has no connection (JS: game.isOffline). False on older SDKs and portals.
M.is_offline = false
M.is_store_available = false
--- True when the native extension delivers results (no polling).
M.is_native = false
M.system_info = {}
M.invite_params = nil
--- Portal settings: disableChat, muteAudio and, from SDK 1.5.0, kidsMode (nil on older portals: test
-- `M.settings.kidsMode == true` and keep honouring disableChat).
M.settings = { disableChat = false, kidsMode = false, muteAudio = false }
--- Silence the "master" sound group while an ad plays (ad started .. finished / error); the game's gain comes back after.
-- Set to false to handle audio in your own `started` / `finished` / `error` handlers. Pausing the game stays yours.
M.mute_audio_during_ads = true
--- Apply the portal's mute setting (settings.muteAudio) to the "master" sound group after init and on every change.
M.follow_portal_mute = true

local STATIC_SIZES = { ["728x90"] = true, ["300x250"] = true, ["320x50"] = true, ["468x60"] = true, ["320x100"] = true }

local native -- the zokogames_native module when the extension is built in
local pending = {}
local next_id = 1
local initializing = false
local init_waiters = {}
local poll_timer
local settings_listeners, join_listeners, auth_listeners, offline_listeners = {}, {}, {}, {}
local achievement_listeners, sim_achievements = {}, {}
local mirror_error_listeners = {}
local screenshot_provider -- function() -> data URL | nil, or nil for the built-in canvas capture
local screenshot_registered, screenshot_off, screenshot_wanted, screenshot_timer = false, false, false, nil
local room_listeners = { message = {}, state = {}, members = {}, host = {}, left = {}, error = {} }
local room_subscriber -- { self = ..., fn = ... } from room.set_listener, called as fn(self, event, data)
local SIM_ROOM_SELF = "sim-player"
local sim_room_state, sim_room_rev, sim_room_seq = {}, 0, 0
local sim_data, sim_logged_in, sim_ad_playing, sim_auth_open, sim_banner_at = {}, false, false, false, {}

local function err(code, message) return { code = code, message = message } end

-- Audio held silent by the wrapper: during an ad (mute_audio_during_ads) or while the portal asks for mute (follow_portal_mute).
local audio = { ad = false, forced = false, gain = 1 }
local function group_gain(gain)
	local snd = rawget(_G, "sound")
	if not (snd and snd.set_group_gain) then return nil end
	if gain == nil then
		local ok, g = pcall(snd.get_group_gain, "master")
		return ok and g or 1
	end
	pcall(snd.set_group_gain, "master", gain)
end
local function update_audio()
	local want = (audio.ad and M.mute_audio_during_ads) or (M.follow_portal_mute and M.settings and M.settings.muteAudio == true)
	if want and not audio.forced then
		audio.gain = group_gain() or 1
		audio.forced = true
		group_gain(0)
	elseif not want and audio.forced then
		audio.forced = false
		group_gain(audio.gain)
	end
end

local function is_web()
	local h = rawget(_G, "html5")
	return h ~= nil and h.run ~= nil and sys.get_sys_info().system_name == "HTML5"
end

local function encode(t)
	if t == nil or next(t) == nil then return "{}" end
	return json.encode(t)
end

local function js_str(s)
	return '"' .. (tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end)) .. '"'
end

local function emit(list, value)
	for _, fn in ipairs(list) do fn(value) end
end

local function log(text)
	if M.sim.verbose then print("[ZokoGames simulator] " .. text) end
end

-- ------------------------------------------------------------------ dispatch

local function finish(id, e, result)
	local p = pending[id]
	if not p then return end
	pending[id] = nil
	if p.cb then p.cb(e, result) end
end

local function on_event(id, name, data)
	local p = pending[id]
	if p and p.ev then p.ev(name, data) end
end

local function on_global(name, data)
	if name == "settingsChange" then
		if type(data) == "table" then M.settings = data end
		update_audio()
		emit(settings_listeners, M.settings)
	elseif name == "offlineChange" then
		local off = data == true
		if off ~= M.is_offline then
			M.is_offline = off
			emit(offline_listeners, off)
		end
	elseif name == "auth" then
		emit(auth_listeners, data)
	elseif name == "achievementUnlocked" then
		emit(achievement_listeners, data)
	elseif name == "joinRoom" then
		M.invite_params = data
		emit(join_listeners, data)
	elseif name == "roomMessage" then
		emit(room_listeners.message, data)
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "message", data) end
	elseif name == "roomState" then
		local state, change = data.state or {}, data.change or {}
		for _, fn in ipairs(room_listeners.state) do fn(state, change) end
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "state", { state = state, change = change }) end
	elseif name == "roomMembers" then
		emit(room_listeners.members, data)
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "members", data) end
	elseif name == "roomHost" then
		local host_id, is_host = data.hostId, data.isHost == true
		for _, fn in ipairs(room_listeners.host) do fn(host_id, is_host) end
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "host_changed", { host_id = host_id, is_host = is_host }) end
	elseif name == "roomLeft" then
		local reason, room_id = data.reason, data.roomId
		for _, fn in ipairs(room_listeners.left) do fn(reason, room_id) end
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "left", { reason = reason, room_id = room_id }) end
	elseif name == "roomError" then
		emit(room_listeners.error, data)
		if room_subscriber then room_subscriber.fn(room_subscriber.self, "error", data) end
	elseif name == "screenshotRequest" then
		M.game._on_screenshot_request()
	elseif name == "mirrorError" then
		emit(mirror_error_listeners, data)
	end
end

local function on_message(m)
	if type(m) ~= "table" then return end
	if m.kind == "global" then on_global(m.name, m.data)
	elseif m.kind == "event" then on_event(m.id, m.name, m.data)
	elseif m.kind == "done" then
		if m.ok then finish(m.id, nil, m.result) else finish(m.id, m.error or err("other", "Unknown error"), nil) end
	end
end

local function poll()
	local raw = html5.run("ZokoDefold.poll()")
	if raw == nil or raw == "" then return end
	local ok, messages = pcall(json.decode, raw)
	if not ok then return end
	for _, m in ipairs(messages) do on_message(m) end
end

-- Called by the native extension with one JSON message at a time: on_native(self, raw) from extension builds that use
-- dmScript callbacks (self is the script instance that ran zokogames.init), on_native(raw) from older ones.
local function on_native(a, b)
	local raw = b
	if raw == nil and type(a) == "string" then raw = a end
	if type(raw) ~= "string" then return end
	local ok, m = pcall(json.decode, raw)
	if ok then on_message(m) end
end

local sim -- forward declaration

local function call(method, args, cb, ev)
	if method ~= "init" then
		if not M.is_initialized then
			timer.delay(0, false, function() if cb then cb(err("sdkNotInitialized", "Call zokogames.init() and wait for its callback"), nil) end end)
			return
		end
		if M.environment == "disabled" then
			timer.delay(0, false, function() if cb then cb(err("sdkDisabled", "The SDK is disabled in this environment"), nil) end end)
			return
		end
	end
	local id = next_id
	next_id = next_id + 1
	pending[id] = { cb = cb, ev = ev }
	if M.is_simulated then
		sim(id, method, args or {})
	elseif M.is_native then
		native.invoke(id, method, encode(args))
	else
		html5.run(string.format("ZokoDefold.invoke(%d,%s,%s)", id, js_str(method), js_str(encode(args))))
	end
end

local function call_sync(method, args)
	if not M.is_initialized then return false, err("sdkNotInitialized", "Call zokogames.init() first") end
	if M.environment == "disabled" then return false, err("sdkDisabled", "The SDK is disabled in this environment") end
	if M.is_simulated then return sim.sync(method, args or {}) end
	local raw
	if M.is_native then raw = native.invoke_sync(method, encode(args))
	else raw = html5.run(string.format("ZokoDefold.invokeSync(%s,%s)", js_str(method), js_str(encode(args)))) end
	local ok, res = pcall(json.decode, raw)
	if not ok or type(res) ~= "table" then return false, err("other", "Bad bridge response") end
	if res.ok then return true, res.result end
	return false, res.error or err("other", "Unknown error")
end

-- ------------------------------------------------------------------ init

--- Initialise once at startup; the callback fires after init finishes (also when called repeatedly).
function M.init(callback)
	if M.is_initialized then
		if callback then callback(nil, nil) end
		return
	end
	if callback then init_waiters[#init_waiters + 1] = callback end
	if initializing then return end
	initializing = true
	if is_web() then
		M.is_simulated = false
		html5.run(bridge_source)
		html5.run(string.format("ZokoDefold.loadSdk(%s)", js_str(M.SDK_SCRIPT_URL)))
		native = rawget(_G, "zokogames_native")
		if native and native.is_supported() then
			M.is_native = true
			native.set_listener(on_native) -- also registers the JS sink
		else
			M.is_native = false
			poll_timer = timer.delay(0.05, true, poll)
		end
	else
		M.is_simulated = true
		sim.load()
	end
	call("init", {}, function(e, r)
		initializing = false
		if not e then
			M.environment = r.environment or "disabled"
			M.is_qa_tool = r.isQaTool or false
			M.settings = r.settings or M.settings
			M.system_info = r.systemInfo or {}
			M.is_user_account_available = r.isUserAccountAvailable or false
			M.is_instant_multiplayer = r.isInstantMultiplayer or false
			M.is_offline = r.isOffline == true
			M.is_store_available = r.storeAvailable or false
			M.invite_params = r.inviteParams
			M.is_initialized = true
			update_audio()
			M.game._register_screenshot_provider()
		end
		local waiters = init_waiters
		init_waiters = {}
		for _, w in ipairs(waiters) do w(e, r) end
	end)
end

--- True once initialised and not disabled.
function M.is_available() return M.is_initialized and M.environment ~= "disabled" end

-- ------------------------------------------------------------------ ad

--- Request an ad ("midgame" or "rewarded"). handlers = { started = fn(), finished = fn(), error = fn(err) }.
-- Pause your game in `started`, resume in `finished` / `error`. The "master" sound group is silenced meanwhile
-- (M.mute_audio_during_ads).
function M.ad.request_ad(ad_type, handlers)
	handlers = handlers or {}
	-- Only a request whose ad started releases the mute: a second request refused while an ad plays
	-- ("Another ad request is already in progress") must not bring the sound back under the first ad.
	local started = false
	local function ended()
		if not started then return end
		started = false
		audio.ad = false
		update_audio()
	end
	call("ad.requestAd", { type = ad_type }, function(e)
		if e then
			ended()
			if handlers.error then handlers.error(e) end
		end
	end, function(name, data)
		if name == "adStarted" then
			started = true
			audio.ad = true
			update_audio()
			if handlers.started then handlers.started() end
		elseif name == "adFinished" then
			ended()
			if handlers.finished then handlers.finished() end
		elseif name == "adError" then
			ended()
			if handlers.error then handlers.error(data) end
		end
	end)
end

function M.ad.has_adblock(callback) call("ad.hasAdblock", {}, callback) end

-- ------------------------------------------------------------------ banner
-- Rectangles are { x, y, w, h } in window pixels with the origin at the TOP-left, relative to a window of
-- area_w x area_h (default window.get_size()). rect_from_gui_node() builds one from a GUI node.

local function norm_rect(rect)
	local ww, wh = window.get_size()
	local aw, ah = rect.area_w or ww, rect.area_h or wh
	if not aw or aw <= 0 then aw = 1 end
	if not ah or ah <= 0 then ah = 1 end
	return { nx = rect.x / aw, ny = rect.y / ah, nw = rect.w / aw, nh = rect.h / ah }
end

--- Window-pixel rectangle (top-left origin) of a GUI node; assumes a centred pivot.
function M.banner.rect_from_gui_node(node)
	local pos = gui.get_screen_position(node)
	local size = gui.get_size(node)
	local scale = gui.get_scale(node)
	local _, wh = window.get_size()
	local w, h = size.x * scale.x, size.y * scale.y
	return { x = pos.x - w / 2, y = wh - (pos.y + h / 2), w = w, h = h }
end

function M.banner.request_banner(id, width, height, rect, callback)
	call("banner.requestBanner", { id = id, width = width, height = height, rect = norm_rect(rect) }, callback)
end

function M.banner.request_responsive_banner(id, rect, callback)
	call("banner.requestResponsiveBanner", { id = id, rect = norm_rect(rect) }, callback)
end

function M.banner.clear_banner(id, callback) call("banner.clearBanner", { id = id }, callback) end
function M.banner.clear_all_banners(callback) call("banner.clearAllBanners", {}, callback) end

-- ------------------------------------------------------------------ game

local function simple(method) return function(callback) call(method, {}, callback) end end

M.game.gameplay_start = simple("game.gameplayStart")
M.game.gameplay_stop = simple("game.gameplayStop")
M.game.loading_start = simple("game.loadingStart")
M.game.loading_stop = simple("game.loadingStop")
M.game.hide_invite_button = simple("game.hideInviteButton") -- deprecated: update_room({ isJoinable = false })

--- Optional in-game load progress, 0 to 100, between loading_start and loading_stop. Safe to call every frame.
function M.game.loading_progress(percentage, callback)
	call("game.loadingProgress", { percentage = percentage }, callback)
end

--- Deprecated: use update_room({ isJoinable = true, inviteParams = ... }). callback(err, link)
function M.game.show_invite_button(params, callback) call("game.showInviteButton", { params = params }, callback) end
M.game.happytime = simple("game.happytime")
M.game.left_room = simple("game.leftRoom")
M.game.clear_game_context = simple("game.clearGameContext")

--- 0 to 100.
function M.game.report_game_completed_percentage(percentage, callback)
	call("game.reportGameCompletedPercentage", { percentage = percentage }, callback)
end

--- context values must be string, number or boolean.
function M.game.set_game_context(context, callback) call("game.setGameContext", { context = context }, callback) end

--- update = { roomId = "...", isJoinable = true, isPublic = true, inviteParams = { key = "value" } }
--- isPublic (SDK 1.6.0): friends can join from their friends list; private by default, host only, ignored in kids mode.
function M.game.update_room(update, callback) call("game.updateRoom", { update = update }, callback) end

--- callback(err, link)
function M.game.invite_link(params, callback) call("game.inviteLink", { params = params }, callback) end

--- Synchronous: one invite parameter or nil.
function M.game.get_invite_param(key)
	local ok, v = call_sync("game.getInviteParam", { key = key })
	if ok then return v end
	return nil
end

function M.game.get_settings() return M.settings end
function M.game.is_instant_multiplayer() return M.is_instant_multiplayer end
--- Deprecated alias of is_instant_multiplayer (JS: isInstantJoin).
function M.game.is_instant_join() return M.is_instant_multiplayer end
function M.game.is_offline() return M.is_offline end
function M.game.add_offline_listener(fn) offline_listeners[#offline_listeners + 1] = fn end
function M.game.add_settings_change_listener(fn) settings_listeners[#settings_listeners + 1] = fn end
function M.game.add_join_room_listener(fn) join_listeners[#join_listeners + 1] = fn end

local function remove(list, fn)
	for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
end
function M.game.remove_settings_change_listener(fn) remove(settings_listeners, fn) end
function M.game.remove_offline_listener(fn) remove(offline_listeners, fn) end
function M.game.remove_join_room_listener(fn) remove(join_listeners, fn) end


-- ------------------------------------------------------------------ chat reports and screenshots (SDK 1.4.0)

--- Report one chat message to the portal's moderators (JS: game.reportChat). `report` keys: reportedName (1 to 40 characters),
--- message (1 to 500), reason ("abuse", "spam", "cheating" or "other"), optional reportedUserId, roomId (at most 64) and
--- context (a list of { name = "...", text = "..." }, oldest first, the newest 10 are kept).
--- The callback gets an error table on invalidArgument, rateLimited or unexpectedError.
function M.game.report_chat(report, callback) call("game.reportChat", { report = report }, callback) end

--- Capture a picture now: the provider's data URL, or (HTML5, no provider) the canvas, or nil. callback(data_url_or_nil).
--- In Defold the canvas is only readable right after a frame was drawn, so call it from M.game.screenshot_tick() or the render script.
function M.game.capture_screenshot(callback)
	local url
	if screenshot_provider then
		local ok, v = pcall(screenshot_provider)
		if ok and type(v) == "string" and v:sub(1, 11) == "data:image/" then url = v end
	elseif is_web() then
		local raw = html5.run("ZokoDefold.capture()")
		if type(raw) == "string" and raw ~= "" then url = raw end
	end
	if callback then callback(url) end
	return url
end

local function answer_screenshot(url)
	screenshot_wanted = false
	if screenshot_timer then timer.cancel(screenshot_timer); screenshot_timer = nil end
	call_sync("game.answerScreenshot", { dataUrl = url })
end

function M.game._register_screenshot_provider()
	if screenshot_off or not M.is_available() then return end
	local ok = call_sync("game.setScreenshotProvider", { enabled = true })
	screenshot_registered = ok and true or false
end

--- Supply the picture the portal's feedback form attaches (JS: game.onScreenshotRequest). `provider` is a function that takes no
--- arguments and returns a "data:image/...;base64,..." string (or nil for no picture); it runs the moment the portal asks.
--- With no provider (the default, registered by init) the canvas is read by M.game.screenshot_tick().
function M.game.set_screenshot_provider(provider)
	screenshot_provider = type(provider) == "function" and provider or nil
	screenshot_off = false
	M.game._register_screenshot_provider()
end

--- Stop answering from Defold; the JS SDK then falls back to its own canvas capture, which is usually blank on WebGL.
function M.game.clear_screenshot_provider()
	screenshot_provider = nil
	screenshot_off = true
	if screenshot_registered then
		screenshot_registered = false
		call_sync("game.setScreenshotProvider", { enabled = false })
	end
end

--- Call at the END of your render script's update (after the last render.draw): when the portal asked for a screenshot it reads the finished
--- frame from the canvas and answers. Cheap when nothing is pending. Returns true when it answered with a picture.
function M.game.screenshot_tick()
	if not screenshot_wanted then return false end
	local url = M.game.capture_screenshot()
	answer_screenshot(url)
	return url ~= nil
end

function M.game._on_screenshot_request()
	if screenshot_provider then
		answer_screenshot(M.game.capture_screenshot())
		return
	end
	screenshot_wanted = true
	-- The SDK waits 3 s: when nothing calls screenshot_tick(), read the canvas anyway (it may be blank on WebGL).
	if screenshot_timer then timer.cancel(screenshot_timer) end
	screenshot_timer = timer.delay(1.5, false, function()
		screenshot_timer = nil
		if screenshot_wanted then answer_screenshot(M.game.capture_screenshot()) end
	end)
end

-- ------------------------------------------------------------------ user

function M.user.is_user_account_available() return M.is_user_account_available end
function M.user.get_system_info() return M.system_info end
--- callback(err, user) where user is nil when logged out.
function M.user.get_user(callback) call("user.getUser", {}, callback) end
--- page is 1-based, size 1 to 50. callback(err, { friends, page, size, hasMore, total })
function M.user.list_friends(page, size, callback) call("user.listFriends", { page = page, size = size }, callback) end
--- signing_key_type: nil, "IN_GAME_AUTH" or "IN_GAME_AUTH_LEGACY". callback(err, token)
function M.user.get_user_token(signing_key_type, callback)
	call("user.getUserToken", { signingKeyType = signing_key_type or "" }, callback)
end
--- Deprecated: use zoko.store.get_purchase_token.
function M.user.get_xsolla_user_token(callback) call("store.getPurchaseToken", {}, callback) end
function M.user.show_auth_prompt(callback) call("user.showAuthPrompt", {}, callback) end
--- callback(err, { response = "yes" | "no" })
function M.user.show_account_link_prompt(callback) call("user.showAccountLinkPrompt", {}, callback) end
function M.user.submit_score(encrypted_score, score, callback)
	call("user.submitScore", { encryptedScore = encrypted_score, score = score }, callback)
end
function M.user.add_auth_listener(fn) auth_listeners[#auth_listeners + 1] = fn end
function M.user.remove_auth_listener(fn) remove(auth_listeners, fn) end

-- ------------------------------------------------------------------ data (synchronous, strings)

--- Returns the stored string or nil.
function M.data.get_item(key)
	local ok, v = call_sync("data.getItem", { key = key })
	if ok then return v end
	return nil
end
function M.data.has_key(key) return M.data.get_item(key) ~= nil end
--- Returns true, or false plus an error table (e.g. dataLimitExceeded).
function M.data.set_item(key, value)
	local ok, e = call_sync("data.setItem", { key = key, value = tostring(value) })
	if ok then return true end
	return false, e
end
function M.data.remove_item(key) return (call_sync("data.removeItem", { key = key })) end
function M.data.clear() return (call_sync("data.clear", {})) end

--- Copy the page's localStorage writes into the cloud save and restore newer cloud values into it (JS: data.mirrorLocalStorage, SDK 1.4.0).
--- Only for JavaScript-side storage. Defold's own sys.save files live in the browser's IndexedDB (not localStorage), so they are NOT
--- mirrored: save those with data.set_item. `options` (all optional): keys = { "a", "b" } exact names, prefix = "save_", pattern = "^lvl"
--- (a JavaScript regular expression source; ignored when keys is given). Call it right after init. Returns true, or false plus an error table.
function M.data.mirror_local_storage(options)
	options = options or {}
	local args = {}
	if type(options.keys) == "table" and #options.keys > 0 then args.keys = options.keys end
	if type(options.prefix) == "string" and options.prefix ~= "" then args.prefix = options.prefix end
	if type(options.pattern) == "string" and options.pattern ~= "" then args.pattern = options.pattern end
	local ok, e = call_sync("data.mirrorLocalStorage", args)
	if ok then return true end
	return false, e
end
function M.data.stop_mirror_local_storage() return (call_sync("data.stopMirrorLocalStorage", {})) end
--- fn(error) when a mirrored key cannot be saved, for example dataLimitExceeded when the 1 MB cloud save is full.
function M.data.add_mirror_error_listener(fn) mirror_error_listeners[#mirror_error_listeners + 1] = fn end
function M.data.remove_mirror_error_listener(fn) remove(mirror_error_listeners, fn) end

-- ------------------------------------------------------------------ store

--- In-game purchases. Check store.is_available() before showing purchase UI and verify ownership on your server.
--- True when this host offers purchases (says nothing about sign-in).
function M.store.is_available() return M.is_store_available end

--- Route later store calls to the provider sandbox (test payments). Returns true, or false plus an error table.
function M.store.set_sandbox(sandbox)
	local ok, e = call_sync("store.setSandbox", { sandbox = sandbox and true or false })
	if ok then return true end
	return false, e
end

local function page_args(options)
	options = options or {}
	return { limit = options.limit or 50, offset = options.offset or 0 }
end

--- options = { limit = 1..50, offset = 0.. }. callback(err, items) with items = { { sku, name, description, imageUrl, price = { amount, currency } | nil, consumable } }
function M.store.get_catalog_items(options, callback) call("store.getCatalogItems", page_args(options), callback) end
--- callback(err, items) with items = { { sku, name, description, imageUrl, quantity } } (quantity is nil when not counted)
function M.store.get_player_inventory(options, callback) call("store.getPlayerInventory", page_args(options), callback) end
--- Opens the portal checkout (one purchase at a time). callback(err, { itemId = ... })
function M.store.buy_item(item_id, callback) call("store.buyItem", { itemId = item_id }, callback) end
--- Signed token listing what the player owns, for your server to verify (userNotAuthenticated for guests). callback(err, token)
function M.store.get_purchase_token(callback) call("store.getPurchaseToken", {}, callback) end
function M.store.consume_item(sku, quantity, callback) call("store.consumeItem", { sku = sku, quantity = quantity }, callback) end

-- ------------------------------------------------------------------ room data channel (SDK 1.3.0)
-- Small JSON messages between the players of one room plus a host-written shared state. Game data, not text chat.
-- The room exists after game.update_room(...) (or after joining from an invite) and ends with game.left_room().
-- Limits: 8 KB per message or patch, 20 messages per second, 64 KB of state; state keys are 1 to 40 characters of
-- A-Z a-z 0-9 _ . : -  Payloads are JSON: tables, strings, numbers and booleans (Lua tables cannot hold nil: remove a state
-- key with remove_state). Errors arrive as callback(err) or as the "error" event: notInRoom, notHost, payloadTooLarge,
-- stateTooLarge, unknownMember, rateLimited, roomUnavailable.
local room = M.game.room

--- Send any JSON-encodable value to every other member. callback(err)
function room.send(data, callback) call("room.send", { data = data }, callback) end
--- Send to one member only (an id from room.members()). callback(err)
function room.send_to(member_id, data, callback) call("room.send", { data = data, to = member_id }, callback) end

--- Host only. Merge `patch` (a table of key = value) into the shared state. It applies once the platform confirms it:
-- read it in the "state" event, not straight after this call. callback(err)
function room.set_state(patch, callback) call("room.setState", { patch = patch }, callback) end
--- Host only. Remove one key (a string) or several (an array of strings) from the shared state. callback(err)
function room.remove_state(keys, callback)
	if type(keys) == "string" then keys = { keys } end
	call("room.setState", { remove = keys }, callback)
end

--- Copy of the shared state (empty table when not in a room).
function room.get_state()
	local ok, v = call_sync("room.getState", {})
	if ok and type(v) == "table" then return v end
	return {}
end
--- Array of { id, username, profilePictureUrl }, including this player (empty when not in a room).
function room.members()
	local ok, v = call_sync("room.members", {})
	if ok and type(v) == "table" then return v end
	return {}
end
--- True when this player is the room host (the first member).
function room.is_host()
	local ok, v = call_sync("room.isHost", {})
	return ok and v == true
end
--- Platform id of this player, or nil when not in a room.
function room.self_id()
	local ok, v = call_sync("room.selfId", {})
	if ok and type(v) == "string" then return v end
	return nil
end

--- One listener for every room event with the usual Defold shape fn(self, event, data). Pass the script's `self`.
-- event "message":      data = { from, data, direct, seq, ts }       (never your own messages on the portal)
-- event "state":        data = { state = {...}, change = { by, keys, rev } }
-- event "members":      data = { { id, username, profilePictureUrl }, ... }
-- event "host_changed": data = { host_id, is_host }
-- event "left":         data = { reason, room_id }  (SDK 1.7.0; reason "left" | "kicked" | "closed" | "disconnected")
-- event "error":        data = { code, message }
-- Call set_listener(nil, nil) to remove it.
function room.set_listener(self, fn)
	if fn == nil then room_subscriber = nil else room_subscriber = { self = self, fn = fn } end
end

--- Per-event listeners, same convention as add_join_room_listener. Pass the same function to the matching remove_*.
function room.add_message_listener(fn) room_listeners.message[#room_listeners.message + 1] = fn end         -- fn(message)
function room.add_state_listener(fn) room_listeners.state[#room_listeners.state + 1] = fn end               -- fn(state, change)
function room.add_members_listener(fn) room_listeners.members[#room_listeners.members + 1] = fn end         -- fn(members)
function room.add_host_change_listener(fn) room_listeners.host[#room_listeners.host + 1] = fn end           -- fn(host_id, is_host)
function room.add_left_listener(fn) room_listeners.left[#room_listeners.left + 1] = fn end                 -- fn(reason, room_id), SDK 1.7.0
function room.add_error_listener(fn) room_listeners.error[#room_listeners.error + 1] = fn end               -- fn(err)
function room.remove_message_listener(fn) remove(room_listeners.message, fn) end
function room.remove_state_listener(fn) remove(room_listeners.state, fn) end
function room.remove_members_listener(fn) remove(room_listeners.members, fn) end
function room.remove_host_change_listener(fn) remove(room_listeners.host, fn) end
function room.remove_left_listener(fn) remove(room_listeners.left, fn) end
function room.remove_error_listener(fn) remove(room_listeners.error, fn) end

-- ------------------------------------------------------------------ achievements

--- callback(err, achievements) with { { key, name, description, iconUrl, points, hidden, unlocked, unlockedAt } }
function M.achievements.list(callback) call("achievements.list", {}, callback) end
--- callback(err, result) with { ok = true, unlocked, achievement } or { ok = false, reason } (guests and unknown keys do not fail)
function M.achievements.unlock(key, callback) call("achievements.unlock", { key = key }, callback) end
function M.achievements.on_unlock(listener) achievement_listeners[#achievement_listeners + 1] = listener end
function M.achievements.remove_unlock_listener(listener) remove(achievement_listeners, listener) end

-- ------------------------------------------------------------------ analytics

--- order is any JSON-encodable table.
function M.analytics.track_order(provider, order, callback)
	call("analytics.trackOrder", { provider = provider, order = order }, callback)
end

--- Fire and forget (SDK 1.7.0). name matches ^[a-z][a-z0-9_]{0,39}$; params is a flat table of string, number or boolean values (max 10).
function M.analytics.track(name, params)
	call("analytics.track", { name = name, params = params }, nil)
end

-- ------------------------------------------------------------------ simulator

local SAVE_FILE

local function persist()
	if SAVE_FILE then sys.save(SAVE_FILE, { items = sim_data }) end
end

local function sim_user()
	return { username = M.sim.username, profilePictureUrl = "", __dangerousUserId = M.sim.user_id }
end

local function sim_settings() return { disableChat = M.sim.disable_chat or M.sim.kids_mode, kidsMode = M.sim.kids_mode, muteAudio = M.sim.mute_audio } end

sim = setmetatable({}, { __call = function(_, id, method, args)
	timer.delay(0, false, function() sim.run(id, method, args) end)
end })

function sim.load()
	sim_logged_in = M.sim.logged_in and M.sim.account_available
	SAVE_FILE = sys.get_save_file("zokogames", "sim_data")
	local saved = sys.load(SAVE_FILE)
	sim_data = (saved and saved.items) or {}
end

local SIM_CATALOG = {
	{ sku = "sim_coins_100", name = "100 Coins", description = "A small pile of coins", imageUrl = "", price = { amount = 0.99, currency = "USD" }, consumable = true },
	{ sku = "sim_coins_500", name = "500 Coins", description = "A big pile of coins", imageUrl = "", price = { amount = 1.99, currency = "USD" }, consumable = true },
	{ sku = "sim_no_ads", name = "Remove Ads", description = "One-time purchase", imageUrl = "", price = { amount = 2.99, currency = "USD" }, consumable = false },
}
local sim_inventory = {}

function sim.store(id, method, a)
	local function ok(v) finish(id, nil, v) end
	local function fail(code, message) finish(id, err(code, message), nil) end
	-- Like the JS SDK, the purchase token does not depend on store availability (it only needs a signed-in player).
	if method == "store.getPurchaseToken" then
		if not sim_logged_in then return fail("userNotAuthenticated", "No user is signed in") end
		return ok("simulated-purchase." .. M.sim.user_id)
	end
	if not M.sim.store_available then return fail("other", "The store is not available") end
	local limit, offset = a.limit or 50, a.offset or 0
	if method == "store.getCatalogItems" or method == "store.getPlayerInventory" then
		if type(limit) ~= "number" or math.floor(limit) ~= limit or limit < 1 or limit > 50 then return fail("invalidArgument", "limit must be an integer between 1 and 50") end
		if type(offset) ~= "number" or math.floor(offset) ~= offset or offset < 0 then return fail("invalidArgument", "offset must be an integer >= 0") end
		local all = {}
		for _, c in ipairs(SIM_CATALOG) do
			if method == "store.getCatalogItems" then all[#all + 1] = c
			elseif sim_inventory[c.sku] then
				all[#all + 1] = { sku = c.sku, name = c.name, description = c.description, imageUrl = "", quantity = sim_inventory[c.sku] }
			end
		end
		local out = {}
		for i = offset + 1, math.min(offset + limit, #all) do out[#out + 1] = all[i] end
		ok(out)
	elseif method == "store.buyItem" then
		if type(a.itemId) ~= "string" or a.itemId == "" then return fail("invalidArgument", "itemId must be a non-empty string") end
		for _, c in ipairs(SIM_CATALOG) do
			if c.sku == a.itemId then
				sim_inventory[c.sku] = (sim_inventory[c.sku] or 0) + 1
				log("simulated purchase of " .. c.sku)
				return ok({ itemId = c.sku })
			end
		end
		fail("purchaseInitFailed", "No catalogue item " .. a.itemId)
	elseif method == "store.consumeItem" then
		if type(a.sku) ~= "string" or a.sku == "" then return fail("invalidArgument", "sku must be a non-empty string") end
		if type(a.quantity) ~= "number" or a.quantity < 1 then return fail("invalidArgument", "quantity must be an integer >= 1") end
		if (sim_inventory[a.sku] or 0) < a.quantity then return fail("insufficientItemQuantity", "Not enough of " .. a.sku) end
		sim_inventory[a.sku] = sim_inventory[a.sku] - a.quantity
		if sim_inventory[a.sku] <= 0 then sim_inventory[a.sku] = nil end
		ok()
	else
		fail("unknownMethod", "Unknown store method " .. method)
	end
end

function sim.sync(method, args)
	if method == "game.getSettings" then return true, sim_settings()
	elseif method == "game.getInviteParams" then return true, M.invite_params
	elseif method == "game.getInviteParam" then return true, M.invite_params and M.invite_params[args.key] or nil
	elseif method == "data.getItem" then return true, sim_data[args.key]
	elseif method == "data.setItem" then
		local size = #json.encode(sim_data) + #tostring(args.key) + #tostring(args.value) + 8
		if size > 1048576 then return false, err("dataLimitExceeded", "Saved data would exceed 1048576 bytes") end
		sim_data[args.key] = args.value
		persist()
		return true, nil
	elseif method == "data.removeItem" then sim_data[args.key] = nil; persist(); return true, nil
	elseif method == "data.clear" then sim_data = {}; persist(); return true, nil
	elseif method == "game.setScreenshotProvider" then
		log("game.setScreenshotProvider enabled=" .. tostring(args.enabled ~= false))
		return true, nil
	elseif method == "game.answerScreenshot" then
		log("game.answerScreenshot " .. (type(args.dataUrl) == "string" and "(picture)" or "(none)"))
		return true, nil
	elseif method == "data.mirrorLocalStorage" then
		log("data.mirrorLocalStorage ignored (no browser localStorage outside HTML5)")
		return true, nil
	elseif method == "data.stopMirrorLocalStorage" then return true, nil
	elseif method == "room.selfId" then return true, SIM_ROOM_SELF
	elseif method == "room.isHost" then return true, true
	elseif method == "room.members" then return true, { { id = SIM_ROOM_SELF, username = M.sim.username, profilePictureUrl = "" } }
	elseif method == "room.getState" then
		local copy = {}
		for k, v in pairs(sim_room_state) do copy[k] = v end
		return true, copy
	elseif method == "store.isAvailable" then return true, M.sim.store_available
	elseif method == "store.setSandbox" then
		-- The JS SDK only stores the flag (it does not check store availability).
		return true, nil
	end
	return false, err("unknownMethod", "Unknown sync method " .. tostring(method))
end

function sim.run(id, method, a)
	local s = M.sim
	local function ok(v) finish(id, nil, v) end
	local function fail(code, message) finish(id, err(code, message), nil) end
	if method == "init" then
		if s.disabled then
			return ok({ environment = "disabled", isQaTool = false, settings = sim_settings(), isUserAccountAvailable = false, isInstantMultiplayer = false, isOffline = false, storeAvailable = false })
		end
		log("init (environment local)")
		return ok({
			environment = "local", isQaTool = false, settings = sim_settings(),
			systemInfo = {
				countryCode = "US", locale = "en-US", device = { type = "desktop" },
				os = { name = sys.get_sys_info().system_name, version = sys.get_sys_info().system_version or "" },
				browser = { name = "Defold", version = sys.get_engine_info().version }, applicationType = "web",
			},
			isUserAccountAvailable = s.account_available, isInstantMultiplayer = false, isOffline = s.offline,
			storeAvailable = s.store_available,
		})
	end
	if s.disabled then return fail("sdkDisabled", "The SDK is disabled in this environment") end

	if method == "ad.requestAd" then
		if a.type ~= "midgame" and a.type ~= "rewarded" then return fail("invalidArgument", 'ad type must be "midgame" or "rewarded"') end
		if sim_ad_playing then
			on_event(id, "adError", err("other", "Another ad request is already in progress"))
			return ok()
		end
		if s.ad_behaviour == "no_fill" then
			on_event(id, "adError", err("unfilled", "No ad was available"))
			return ok()
		end
		sim_ad_playing = true
		on_event(id, "adStarted")
		log("ad started (" .. a.type .. ")")
		timer.delay(s.ad_duration, false, function()
			sim_ad_playing = false
			if s.ad_behaviour == "error" then on_event(id, "adError", err("other", "Simulated ad error"))
			else on_event(id, "adFinished") end
			ok()
		end)
	elseif method == "ad.hasAdblock" then ok(s.adblock)
	elseif method == "banner.requestBanner" or method == "banner.requestResponsiveBanner" then
		if not a.id or a.id == "" then return fail("missingId", "A container id is required") end
		if sim_ad_playing then return fail("videoAdPlaying", "A video ad is playing") end
		if method == "banner.requestBanner" and not STATIC_SIZES[string.format("%dx%d", a.width or 0, a.height or 0)] then
			return fail("invalidSize", string.format("%dx%d is not a supported banner size", a.width or 0, a.height or 0))
		end
		-- Wall-clock seconds (os.clock() is CPU time, which runs slower than real time and stretched the cooldown).
		local now = socket.gettime()
		if sim_banner_at[a.id] and now - sim_banner_at[a.id] < 30 then return fail("bannerCooldown", "Banners can refresh at most every 30 seconds") end
		sim_banner_at[a.id] = now
		log("banner shown: " .. a.id)
		ok()
	elseif method == "banner.clearBanner" then sim_banner_at[a.id] = nil; ok()
	elseif method == "banner.clearAllBanners" then sim_banner_at = {}; ok()
	elseif method:sub(1, 5) == "game." and (method == "game.gameplayStart" or method == "game.gameplayStop" or method == "game.loadingStart"
		or method == "game.loadingStop" or method == "game.hideInviteButton" or method == "game.happytime" or method == "game.leftRoom" or method == "game.clearGameContext") then
		log(method)
		ok()
	elseif method == "game.reportGameCompletedPercentage" or method == "game.loadingProgress" then
		if type(a.percentage) ~= "number" or a.percentage < 0 or a.percentage > 100 then return fail("invalidArgument", "percentage must be a number between 0 and 100") end
		ok()
	elseif method == "game.setGameContext" then
		if type(a.context) ~= "table" then return fail("invalidArgument", "context must be an object of string, number or boolean values") end
		ok()
	elseif method == "game.reportChat" then
		local r = a.report
		if type(r) ~= "table" then return fail("invalidArgument", "report must be an object") end
		local name, text = tostring(r.reportedName or ""), tostring(r.message or "")
		if #name < 1 or #name > 40 then return fail("invalidArgument", "reportedName must be 1 to 40 characters") end
		if #text < 1 or #text > 500 then return fail("invalidArgument", "message must be 1 to 500 characters") end
		if r.reason ~= "abuse" and r.reason ~= "spam" and r.reason ~= "cheating" and r.reason ~= "other" then
			return fail("invalidArgument", "reason must be one of abuse, spam, cheating, other")
		end
		if r.roomId ~= nil and (#tostring(r.roomId) < 1 or #tostring(r.roomId) > 64) then return fail("invalidArgument", "roomId must be 1 to 64 characters") end
		log("game.reportChat " .. json.encode(r))
		ok()
	elseif method == "game.updateRoom" then
		if type(a.update) ~= "table" then return fail("invalidArgument", "update must be an object") end
		ok()
	elseif method == "game.inviteLink" or method == "game.showInviteButton" then
		local parts = {}
		for k, v in pairs(a.params or {}) do parts[#parts + 1] = k .. "=" .. tostring(v) end
		table.sort(parts)
		ok("https://zokogames.com/play/simulated" .. (#parts > 0 and ("?" .. table.concat(parts, "&")) or ""))
	elseif method == "user.getUser" then ok(sim_logged_in and sim_user() or nil)
	elseif method == "user.listFriends" then
		local page, size, total = a.page or 0, a.size or 0, s.friend_count
		if page < 1 then return fail("invalidArgument", "page must be an integer >= 1") end
		if size < 1 or size > 50 then return fail("invalidArgument", "size must be an integer between 1 and 50") end
		local friends, start = {}, (page - 1) * size
		for i = start + 1, math.min(start + size, total) do
			friends[#friends + 1] = { id = "sim-friend-" .. i, username = "Friend " .. i, profilePictureUrl = "" }
		end
		ok({ friends = friends, page = page, size = size, hasMore = start + size < total, total = total })
	elseif method == "user.getUserToken" then
		if not sim_logged_in then return fail("userNotAuthenticated", "No user is signed in") end
		ok("simulated." .. s.user_id .. ".unsigned")
	elseif method == "user.getXsollaUserToken" then
		if not sim_logged_in then return fail("userNotAuthenticated", "No user is signed in") end
		ok("simulated-purchase." .. s.user_id)
	elseif method == "user.showAuthPrompt" then
		if sim_auth_open then return fail("showAuthPromptInProgress", "The auth prompt is already open") end
		if sim_logged_in then return fail("userAlreadySignedIn", "A user is already signed in") end
		sim_auth_open = true
		timer.delay(0.4, false, function()
			sim_auth_open, sim_logged_in = false, true
			on_global("auth", sim_user())
			ok(sim_user())
		end)
	elseif method == "user.showAccountLinkPrompt" then ok({ response = sim_logged_in and "yes" or "no" })
	elseif method == "user.submitScore" then
		-- Like the JS SDK: encryptedScore must be a string (an empty one is accepted for boards without an encryption key) and score a finite number.
		local sc = a.score
		if type(a.encryptedScore) ~= "string" or type(sc) ~= "number" or sc ~= sc or sc == math.huge or sc == -math.huge then
			return fail("invalidArgument", "submitScore needs { encryptedScore: string, score: number }")
		end
		ok()
	elseif method:sub(1, 6) == "store." then sim.store(id, method, a)
	elseif method == "achievements.list" then
		local out = {}
		for _, v in pairs(sim_achievements) do out[#out + 1] = v end
		ok(out)
	elseif method == "achievements.unlock" then
		if type(a.key) ~= "string" or not a.key:match("^[a-z0-9_%-]+$") or #a.key > 40 then return fail("invalidArgument", "key must match ^[a-z0-9_-]{1,40}$") end
		if not sim_logged_in then return ok({ ok = false, reason = "guest" }) end
		if sim_achievements[a.key] then return ok({ ok = true, unlocked = false, achievement = sim_achievements[a.key] }) end
		local ach = { key = a.key, name = a.key, description = "", points = 0, hidden = false, unlocked = true, unlockedAt = os.date("!%Y-%m-%dT%H:%M:%SZ") }
		sim_achievements[a.key] = ach
		log("simulated achievement unlocked: " .. a.key)
		on_global("achievementUnlocked", ach)
		ok({ ok = true, unlocked = true, achievement = ach })
	elseif method == "room.send" then
		if a.data == nil then return fail("invalidArgument", "data must be JSON-serializable") end
		local size = #json.encode({ a.data })
		if size > 8192 then return fail("payloadTooLarge", "data is " .. size .. " bytes; the limit is 8192") end
		if a.to ~= nil and (type(a.to) ~= "string" or a.to == "") then return fail("invalidArgument", "to must be a member id") end
		if a.to ~= nil and a.to ~= SIM_ROOM_SELF then return fail("unknownMember", "No member " .. a.to .. " in the simulated room") end
		ok()
		-- Loop back locally (a real portal never echoes your own messages).
		sim_room_seq = sim_room_seq + 1
		on_global("roomMessage", { data = a.data, direct = a.to ~= nil, from = SIM_ROOM_SELF, seq = sim_room_seq, ts = os.time() * 1000 })
	elseif method == "room.setState" then
		local changes, keys = {}, {}
		if type(a.patch) == "table" then for k, v in pairs(a.patch) do changes[tostring(k)] = v end end
		if type(a.remove) == "table" then for _, k in ipairs(a.remove) do changes[tostring(k)] = false end end
		local nkeys = 0
		for k, v in pairs(changes) do
			nkeys = nkeys + 1
			if #k < 1 or #k > 40 or not k:match("^[A-Za-z0-9_.:%-]+$") then return fail("invalidArgument", "keys are 1-40 characters of A-Z a-z 0-9 _ . : -") end
			keys[#keys + 1] = k
		end
		if nkeys == 0 then return fail("invalidArgument", "patch needs at least one key") end
		if #json.encode(a.patch or {}) > 8192 then return fail("payloadTooLarge", "patch is larger than 8192 bytes") end
		local removed = {}
		if type(a.remove) == "table" then for _, k in ipairs(a.remove) do removed[tostring(k)] = true end end
		local nextstate = {}
		for k, v in pairs(sim_room_state) do nextstate[k] = v end
		for k, v in pairs(changes) do
			if removed[k] then nextstate[k] = nil else nextstate[k] = v end
		end
		if #json.encode(nextstate) > 65536 then return fail("stateTooLarge", "The shared state would exceed 65536 bytes") end
		sim_room_state = nextstate
		sim_room_rev = sim_room_rev + 1
		ok()
		local snapshot = {}
		for k, v in pairs(nextstate) do snapshot[k] = v end
		on_global("roomState", { state = snapshot, change = { by = SIM_ROOM_SELF, keys = keys, rev = sim_room_rev } })
	elseif method == "analytics.track" then
		if type(a.name) ~= "string" or not a.name:match("^[a-z][a-z0-9_]*$") or #a.name > 40 then return fail("invalidArgument", "name must match ^[a-z][a-z0-9_]{0,39}$") end
		ok()
	elseif method == "analytics.trackOrder" then
		if not a.provider or a.provider == "" then return fail("invalidArgument", "provider must be a non-empty string") end
		ok()
	else
		local good, v = sim.sync(method, a)
		if good then ok(v) else finish(id, v, nil) end
	end
end

return M
