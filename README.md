# ZokoGames SDK for Defold (HTML5)

A Defold library with a native extension written for ZokoGames (`zokogames/ext.manifest`, `src/zokogames_ext.cpp`, `lib/web/lib_zokogames.js`)
and a Lua API. With the extension built in, the browser SDK pushes results straight into Lua; without it (for example a project bundled without native extensions)
the module falls back to polling `html5.run` every 50 ms. Outside HTML5 a Lua simulator answers. All code is our own; no third-party Defold
extension was read or reused, so no attribution is required.

Version 1.8.0 (written against the JavaScript SDK `@zoko/sdk` 1.8.0). Changes: [CHANGELOG.md](./CHANGELOG.md).
Status: checked with the official build tool for Defold 1.14.1. The project resolves the library and bundles for the
web, the Lua module and JavaScript library pass every call in a browser against the SDK's local mode, and the C++ file
compiles against the 1.14.1 headers. The native extension itself has not been through the engine's build server, and
other Defold releases have not been tried (see `VERIFY.md`). If something fails on first import, send the engine
version and the exact error to developer support.

## Versions

| Wrapper | ZokoGames SDK |
|---|---|
| 1.8.0 | @zoko/sdk 1.8.0 |
| 1.7.0 | @zoko/sdk 1.7.0 |
| 1.6.2 | @zoko/sdk 1.6.1 |
| 1.6.1 | @zoko/sdk 1.6.0 |
| 1.6.0 | @zoko/sdk 1.6.0 |
| 1.5.0 | @zoko/sdk 1.5.0 |
| 1.4.1 | @zoko/sdk 1.4.1 |
| 1.4.0 | @zoko/sdk 1.4.0 |
| 1.3.1 | @zoko/sdk 1.3.1 |

| Defold | Support |
|---|---|
| 1.x with the HTML5 platform | Supported (native extension plus a JavaScript bridge). No minimum 1.x release has been verified. |
| Desktop and mobile builds | Simulator answers; no browser. |

## Install

1. Add the library as a dependency (Project > Fetch Libraries, using the zip or git URL of this folder) or copy `zokogames/` into your project.
   `game.project` shows the library layout (`include_dirs = zokogames`). The extension is compiled by Defold's build server when you bundle.
2. `local zoko = require "zokogames.zokogames"`.
3. Bundle for HTML5. The module injects the SDK script itself, so no HTML template change is needed to run. The upload validator reads
   files statically, so also add the SDK `<script>` tag to the `<head>` of a copy of `/builtins/manifests/web/engine_template.html`
   selected as the **.html Shell** (`[html5] htmlfile` in `game.project`).

## Quick start

```lua
local zoko = require "zokogames.zokogames"

function init(self)
	zoko.init(function(err)
		if err then print("ZokoGames failed:", err.code) return end
		print(zoko.environment, zoko.is_simulated, zoko.is_native)
		zoko.game.loading_stop()
		zoko.game.gameplay_start()
	end)
end

-- ad: pause in started, resume in finished / error ("master" sound is silenced by the wrapper: zoko.mute_audio_during_ads)
zoko.ad.request_ad("rewarded", {
	started = function() msg.post("@system:", "set_time_step", { factor = 0, mode = 0 }) end,
	finished = function() msg.post("@system:", "set_time_step", { factor = 1, mode = 0 }) end,
	error = function(e) msg.post("@system:", "set_time_step", { factor = 1, mode = 0 }) end,
})

zoko.data.set_item("level", 4)                       -- synchronous cloud save (strings)
local level = tonumber(zoko.data.get_item("level")) or 1

if zoko.store.is_available() then
	zoko.store.get_catalog_items({ limit = 20 }, function(err, items)
		if not err then zoko.store.buy_item(items[1].sku, function(e, r) print(e and e.code or r.itemId) end) end
	end)
end
```

Minimal purchase script (attach to a game object; `examples/store.script`). The simulator answers with a three-item test catalogue in the editor:

```lua
local zoko = require "zokogames.zokogames"

function init(self)
	zoko.init(function(err)
		if err or not zoko.store.is_available() then return end   -- hide your shop button here
		zoko.store.get_catalog_items({ limit = 20 }, function(e, items)
			if e or #items == 0 then return end
			zoko.store.buy_item(items[1].sku, function(buy_err, paid)
				if zoko.is_error(buy_err, "purchaseCancelled") then print("closed the checkout")
				elseif zoko.is_error(buy_err, "userNotAuthenticated") then zoko.user.show_auth_prompt()
				elseif buy_err then print(buy_err.code, buy_err.message)
				else print("paid:", paid.itemId) end                      -- verify ownership on your server
			end)
		end)
	end)
end
```

## API coverage

Every member of the JavaScript SDK is available. Names follow Lua snake_case: `SDK.game.gameplayStart()` is `zoko.game.gameplay_start()`. Callbacks have the shape `callback(err, result)`; `err` is nil or `{code=, message=}`.

| JS SDK member | Lua (`zokogames.zokogames`) | Notes |
|---|---|---|
| `init` | `zoko.init(callback)` | `zoko.is_initialized`, `zoko.is_available()`, `zoko.is_native`, `zoko.is_simulated`. |
| `environment` | `zoko.environment` |  |
| `isQaTool` | `zoko.is_qa_tool` |  |
| `ad.requestAd` | `zoko.ad.request_ad(type, handlers)` | `handlers = { started, finished, error }`. |
| `ad.requestAd.adStarted` | `handlers.started()` of `zoko.ad.request_ad(type, handlers)` | Pause your game here. The "master" sound group is silenced by the wrapper (`zoko.mute_audio_during_ads`, default true). |
| `ad.requestAd.adFinished` | `handlers.finished()` | The game's master gain is back (or stays 0 while the portal asks for mute) and focus returns to the canvas. |
| `ad.requestAd.adError` | `handlers.error(err)` | Fires instead of `finished`, also for failures before the ad started. |
| `ad.hasAdblock` | `zoko.ad.has_adblock(callback)` |  |
| `banner.requestBanner` | `zoko.banner.request_banner(id, width, height, rect, callback)` | `rect = {x, y, w, h}` window pixels, top-left origin; `zoko.banner.rect_from_gui_node(node)` builds one. |
| `banner.requestResponsiveBanner` | `zoko.banner.request_responsive_banner(id, rect, callback)` |  |
| `banner.clearBanner` | `zoko.banner.clear_banner(id, callback)` |  |
| `banner.clearAllBanners` | `zoko.banner.clear_all_banners(callback)` |  |
| `banner.hideAllBanners` | `zoko.banner.hide_all_banners(callback)` | Added in SDK 1.8.0. Hides every banner without clearing it. |
| `banner.showAllBanners` | `zoko.banner.show_all_banners(callback)` | Added in SDK 1.8.0. Shows the hidden banners again. |
| `game.settings` | `zoko.game.get_settings()` / `zoko.settings` | `{ disableChat, muteAudio, kidsMode }`; `kidsMode` (1.5.0) is nil on older portals: test `== true`. |
| `game.addSettingsChangeListener` | `zoko.game.add_settings_change_listener(fn)` |  |
| `game.removeSettingsChangeListener` | `zoko.game.remove_settings_change_listener(fn)` |  |
| `game.gameplayStart` | `zoko.game.gameplay_start(callback)` |  |
| `game.gameplayStop` | `zoko.game.gameplay_stop(callback)` |  |
| `game.loadingStart` | `zoko.game.loading_start(callback)` |  |
| `game.loadingStop` | `zoko.game.loading_stop(callback)` |  |
| `game.loadingProgress` | `zoko.game.loading_progress(percentage, callback)` | 0 to 100; safe every frame. |
| `game.happytime` | `zoko.game.happytime(callback)` |  |
| `game.reportGameCompletedPercentage` | `zoko.game.report_game_completed_percentage(p, callback)` |  |
| `game.reportChat` | `game.report_chat(report, callback)` | Added in SDK 1.4.0. `report` table: `reportedName`, `message`, `reason`, optional `reportedUserId`, `roomId`, `context`. |
| `game.onScreenshotRequest` | `game.set_screenshot_provider(fn)` / `clear_screenshot_provider()` / `screenshot_tick()` | Added in SDK 1.4.0. Call `game.screenshot_tick()` at the end of the render script (1.5 s timer fallback). |
| `game.setGameContext` | `zoko.game.set_game_context(table, callback)` |  |
| `game.clearGameContext` | `zoko.game.clear_game_context(callback)` |  |
| `game.isInstantMultiplayer` | `zoko.game.is_instant_multiplayer()` |  |
| `game.isInstantJoin` | `zoko.game.is_instant_join()` | Deprecated alias. |
| `game.isOffline` | `zoko.game.is_offline()` / `zoko.is_offline` | Boolean; false on older SDKs and portals. Simulator: `zoko.sim.offline`. |
| `game.gameId` | `zoko.game.get_game_id()` | Read-only id the portal sends at init (JS SDK 1.6.2); empty before init. Simulator: `simulated-game`. |
| `data.mirrorIndexedDB` | `zoko.data.mirror_indexeddb(databases, callback)` / `zoko.data.stop_mirror_indexeddb()` | Added in SDK 1.7.0. `sys.save` / `sys.load` on HTML5 use IndexedDB: call it right after init and await the callback before `sys.load`. `databases` is a list of names, `nil` for all. Later failures: the mirror error listeners. |
| `game.addOfflineListener` | `zoko.game.add_offline_listener(fn)` | `fn(offline)` with the new boolean. |
| `game.removeOfflineListener` | `zoko.game.remove_offline_listener(fn)` |  |
| `game.updateRoom` | `zoko.game.update_room(table, callback)` |  |
| `game.leftRoom` | `zoko.game.left_room(callback)` |  |
| `game.addJoinRoomListener` | `zoko.game.add_join_room_listener(fn)` |  |
| `game.removeJoinRoomListener` | `zoko.game.remove_join_room_listener(fn)` |  |
| `game.inviteParams` | `zoko.invite_params` | Nil when not launched from an invite. |
| `game.inviteLink` | `zoko.game.invite_link(params, callback)` | `callback(err, link)`. |
| `game.getInviteParam` | `zoko.game.get_invite_param(key)` | Synchronous. |
| `game.showInviteButton` | `zoko.game.show_invite_button(params, callback)` | Deprecated: use `update_room`. |
| `game.hideInviteButton` | `zoko.game.hide_invite_button(callback)` | Deprecated. |
| `game.room` | `zoko.game.room` (also `zoko.room`) | Room data channel (1.3.0): small JSON messages between the players of one room plus a host-written shared state. Game data, not text chat. See [Room data channel](#room-data-channel). Errors: `notInRoom`, `notHost`, `payloadTooLarge`, `stateTooLarge`, `unknownMember`, `roomUnavailable`. |
| `game.room.send` | `zoko.game.room.send(data, cb)`, `send_to(member_id, data, cb)` | `data` is any JSON-encodable value; at most 8 KB, 20 per second. `cb(err)`. |
| `game.room.onMessage` | `room.set_listener(self, fn)` event `"message"`; `room.add_message_listener(fn)` | `data` = `{ from, data, direct, seq, ts }`; `fn(message)`. Never fired for your own messages on the portal. |
| `game.room.addMessageListener` | `zoko.game.room.add_message_listener(fn)` |  |
| `game.room.removeMessageListener` | `zoko.game.room.remove_message_listener(fn)` |  |
| `game.room.setState` | `room.set_state(patch, cb)`, `room.remove_state(keys, cb)` | Host only. Lua tables cannot hold `nil`, so `remove_state` deletes keys. Applies when the platform confirms it. |
| `game.room.getState` | `zoko.game.room.get_state()` | Table copy of the shared state. |
| `game.room.onState` | `set_listener` event `"state"`; `room.add_state_listener(fn)` | `data` = `{ state, change = { by, keys, rev } }`; `fn(state, change)`. |
| `game.room.addStateListener` | `zoko.game.room.add_state_listener(fn)` |  |
| `game.room.removeStateListener` | `zoko.game.room.remove_state_listener(fn)` |  |
| `game.room.members` | `zoko.game.room.members()` | Array of `{ id, username, profilePictureUrl }`, including this player. |
| `game.room.onMembers` | `set_listener` event `"members"`; `room.add_members_listener(fn)` | `fn(members)`. |
| `game.room.addMembersListener` | `zoko.game.room.add_members_listener(fn)` |  |
| `game.room.removeMembersListener` | `zoko.game.room.remove_members_listener(fn)` |  |
| `game.room.isHost` | `zoko.game.room.is_host()` |  |
| `game.room.onHostChange` | `set_listener` event `"host_changed"`; `room.add_host_change_listener(fn)` | `data` = `{ host_id, is_host }`; `fn(host_id, is_host)`. |
| `game.room.addHostChangeListener` | `zoko.game.room.add_host_change_listener(fn)` |  |
| `game.room.removeHostChangeListener` | `zoko.game.room.remove_host_change_listener(fn)` |  |
| `game.room.addLeftListener` | `zoko.game.room.add_left_listener(fn)`; `set_listener` event `"left"` | Added in SDK 1.7.0. `fn(reason, room_id)`; reason is `"left"`, `"kicked"`, `"closed"` or `"disconnected"`; the event `data` = `{ reason, room_id }`. |
| `game.room.removeLeftListener` | `zoko.game.room.remove_left_listener(fn)` | Added in SDK 1.7.0. |
| `game.room.selfId` | `zoko.game.room.self_id()` | `nil` when not in a room. |
| `game.room.onError` | `set_listener` event `"error"`; `room.add_error_listener(fn)` | `{ code, message }`, e.g. `rateLimited`, `notHost`. |
| `game.room.addErrorListener` | `zoko.game.room.add_error_listener(fn)` |  |
| `game.room.removeErrorListener` | `zoko.game.room.remove_error_listener(fn)` |  |
| `user.isUserAccountAvailable` | `zoko.user.is_user_account_available()` |  |
| `user.systemInfo` | `zoko.user.get_system_info()` |  |
| `user.getUser` | `zoko.user.get_user(callback)` | User is nil when signed out. |
| `user.listFriends` | `zoko.user.list_friends(page, size, callback)` |  |
| `user.getUserToken` | `zoko.user.get_user_token(signing_key_type, callback)` | `nil`, `"IN_GAME_AUTH"` or `"IN_GAME_AUTH_LEGACY"`. |
| `user.showAuthPrompt` | `zoko.user.show_auth_prompt(callback)` |  |
| `user.addAuthListener` | `zoko.user.add_auth_listener(fn)` |  |
| `user.removeAuthListener` | `zoko.user.remove_auth_listener(fn)` |  |
| `user.showAccountLinkPrompt` | `zoko.user.show_account_link_prompt(callback)` |  |
| `user.submitScore` | `zoko.user.submit_score(encrypted_score, score, callback)` | Pass `""` as `encrypted_score` for a board without an encryption key. |
| `user.encryptScore` | `zoko.user.encrypt_score(score, key, callback, earned_at)` | Added in SDK 1.8.0. `callback(err, payload)`; pass `payload` to `submit_score`. `earned_at` is Unix ms of a delayed copy, `nil` or `0` for a live run. Guests get `userNotAuthenticated`. |
| `user.getXsollaUserToken` | `zoko.user.get_xsolla_user_token(callback)` | Deprecated alias of `zoko.store.get_purchase_token`. |
| `ERROR_CODES` | `zoko.ERROR_CODES.<module>`, `zoko.is_error(err, code)` | Tables of code strings for `ad`, `banner`, `user`, `data`, `store`, `room`, `general`. |
| `ERROR_CODE_DESCRIPTIONS` | Error codes table below | Not shipped as runtime text. |
| `SDK_VERSION` | `zoko.VERSION` | The JS SDK release this wrapper was written against. |
| `data.getItem` | `zoko.data.get_item(key)`, `zoko.data.has_key(key)` | Synchronous, strings. |
| `data.setItem` | `zoko.data.set_item(key, value)` | Returns `true` or `false, err`. |
| `data.removeItem` | `zoko.data.remove_item(key)` |  |
| `data.clear` | `zoko.data.clear()` |  |
| `data.mirrorLocalStorage` | `data.mirror_local_storage(options)` / `stop_mirror_local_storage()` | Added in SDK 1.4.0. Only `localStorage`; `sys.save` files live in IndexedDB and are not mirrored (use `data.set_item`). |
| `analytics.track` | `zoko.analytics.track(name, params)` | Added in SDK 1.7.0. Fire and forget, no callback. `name` matches `^[a-z][a-z0-9_]{0,39}$`; `params` is a flat table of string, number or boolean values (max 10). |
| `analytics.trackOrder` | `zoko.analytics.track_order(provider, order, callback)` |  |
| `store.isAvailable` | `zoko.store.is_available()` |  |
| `store.getCatalogItems` | `zoko.store.get_catalog_items({limit, offset}, callback)` |  |
| `store.getPlayerInventory` | `zoko.store.get_player_inventory({limit, offset}, callback)` |  |
| `store.buyItem` | `zoko.store.buy_item(item_id, callback)` | Verify ownership on your server. |
| `store.consumeItem` | `zoko.store.consume_item(sku, quantity, callback)` |  |
| `store.getPurchaseToken` | `zoko.store.get_purchase_token(callback)` | `callback(err, token)`: signed token of what the player owns, for your server; `userNotAuthenticated` for guests. |
| `store.setSandbox` | `zoko.store.set_sandbox(bool)` | Returns `true` or `false, err`. |
| `achievements.list` | `zoko.achievements.list(callback)` | `callback(err, achievements)`: array of `{ key, name, description, iconUrl, points, hidden, unlocked, unlockedAt }`. |
| `achievements.unlock` | `zoko.achievements.unlock(key, callback)` | `callback(err, result)` with `{ ok = true, unlocked, achievement }` or `{ ok = false, reason }` (`guest`, `not_found`, `not_live`, `rate_limited`, `error`); `invalidArgument` for a malformed key. |
| `achievements.onUnlock` | `zoko.achievements.on_unlock(fn)`, `zoko.achievements.remove_unlock_listener(fn)` | `fn(achievement)`. |


## Room data channel

`zoko.game.room` (SDK 1.3.0) lets the players of one room exchange small messages and share a tiny host-written state without your own
server. It is for game data, not text chat. The channel exists after `zoko.game.update_room(...)` (or after joining from an invite) and ends with
`zoko.game.left_room()`; it needs a signed-in player and a portal with realtime enabled, otherwise calls fail with `roomUnavailable`.
Limits: 8 KB per message or patch, 20 messages per second, 64 KB of state, state keys of 1 to 40 characters of `A-Z a-z 0-9 _ . : -`.
Payloads are JSON (tables, strings, numbers, booleans); Lua tables cannot hold `nil`, so use `remove_state` to delete a key. Events arrive through
`room.set_listener(self, fn)` with the usual Defold callback shape `fn(self, event, data)` (events `message`, `state`, `members`, `host_changed`, `left`,
`error`) or through the per-event `add_*_listener` functions. The native extension and the polling fallback both deliver on the main script thread.

Outside HTML5 the simulator provides one room with one member (`sim-player`, the host) and **loops your own messages and state changes back**
to the listeners, so one instance can run the whole flow. A real portal never echoes your own messages.

```lua
local zoko = require "zokogames.zokogames"

function init(self)
	zoko.init(function(err)
		if err then return end
		zoko.game.room.set_listener(self, function(self, event, data)
			if event == "message" then
				print(data.from, "played cell", data.data.cell)       -- from the other player
			elseif event == "state" then
				print("turn is", data.state.turn)
			elseif event == "host_changed" and data.is_host then
				zoko.game.room.set_state({ turn = "X" })               -- only the host writes shared state
			elseif event == "error" then
				print("room error", data.code)
			end
		end)
		zoko.game.update_room({ roomId = "match-1", isJoinable = true }) -- the first player is the host
	end)
end

function on_input(self, action_id, action)
	if action_id == hash("touch") and action.pressed then
		zoko.game.room.send({ cell = 4, mark = "X" }, function(err) if err then print(err.code) end end)
		if zoko.game.room.is_host() then zoko.game.room.set_state({ turn = "O" }) end
	end
end
```

## Error codes

Every failure carries a code and a message (the `err` table `{ code, message, containerId? }`). Banner errors also carry the container id.

| Code | Meaning |
|---|---|
| `adCooldown` | An ad was requested too soon after the previous one. |
| `adblock` | An ad blocker prevented the ad. |
| `adsDisabled` | Ads are switched off for this game or session. |
| `bannerCooldown` | The same banner container was refreshed within 30 seconds. |
| `bannersDisabled` | Banners are switched off for this game or session. |
| `catalogFetchFailed` | The store catalogue could not be loaded. |
| `consumeItemFailed` | The provider rejected the consume request. |
| `dataLimitExceeded` | Cloud save would exceed 1 MiB. |
| `dataModuleDisabled` | Cloud save is not enabled for this game. |
| `insufficientItemQuantity` | consumeItem asked for more than the player owns. |
| `inventoryFetchFailed` | The player inventory could not be loaded. |
| `invalidArgument` | An argument failed validation. |
| `invalidSize` | The banner size is not one of the supported sizes. |
| `itemNotConsumable` | consumeItem was used on a non-consumable item. |
| `itemNotInInventory` | consumeItem named an item the player does not own. |
| `maxRefreshReached` | The per-session banner refresh limit was reached. |
| `missingId` | A banner container id was empty. |
| `noAvailableSizes` | No responsive banner size fits the container. |
| `notCreated` | The banner container does not exist. |
| `notVisible` | The banner container is hidden or off screen. |
| `other` | Any other failure; read the message. |
| `purchaseCancelled` | The player closed the checkout. |
| `purchaseInProgress` | A purchase is already running. |
| `purchaseInitFailed` | The checkout could not be opened (for example an unknown item id). |
| `rateLimited` | Friends were requested more often than every 250 ms. |
| `requestInProgress` | A request of the same kind is already running. |
| `sdkDisabled` | The SDK is disabled where the game is embedded. |
| `sdkNotInitialized` | Init has not finished yet. |
| `sdkNotLoaded` | The SDK script did not load (offline, blocked or missing script tag). |
| `showAccountLinkPromptInProgress` | The account-link prompt is already open. |
| `showAuthPromptInProgress` | The login prompt is already open. |
| `timeout` | The portal did not answer in time. |
| `unexpectedError` | The portal failed unexpectedly. |
| `unfilled` | No ad or banner was available. |
| `unknownMethod` | The wrapper called a bridge method the page does not know (version mismatch). |
| `userAlreadySignedIn` | showAuthPrompt was called while signed in. |
| `userCancelled` | The player dismissed a prompt. |
| `userNotAuthenticated` | The call needs a signed-in player. |
| `videoAdPlaying` | A banner was requested while a video ad plays. |

## Local testing and mock mode

Outside HTML5 (editor, desktop bundles) `zoko.is_simulated` is true and a Lua simulator answers. Edit `zoko.sim` before `zoko.init()`: ad behaviour
(`fill`, `no_fill`, `error`) and duration, ad blocker, `disabled`, login state, friend count, mute and chat flags, `store_available`. Cloud save is kept with
`sys.save`; the simulated store has three items and an in-memory inventory; the room data channel is one member that receives its own messages and state changes. In an HTML5 build on `localhost` the JS SDK's own local mode is used.

Serve the export from `localhost` first: the SDK then runs in its in-page local mode (fake ads, a fake player, a
`localStorage` cloud save), so every call works without the portal. To see the real requirements checklist and event log,
open `/preview` on the portal and enter your local address while you play.

## Build and export settings

- Bundle > HTML5: architecture `wasm-web` (add `js-web` only if you need old browsers; it doubles the size). Release, not Debug.
- Keep the engine's `.wasm` unmodified and do not rename files to `.br` / `.gz` (the loader requests plain names).
- Use texture profiles to compress textures (Basis/ASTC for web) and remove unused engine components in `game.project`.
- The native extension is built by the Defold build server: bundle with native extensions enabled (the default).
- Keep the initial download under 50 MB (20 MB for mobile); use collection proxies with excluded resources and live update to load later levels.

Portal limits for an uploaded build: 1,500 files, 250 MB unpacked, about 50 MB initial download (20 MB for mobile),
`index.html` at the archive root, every path relative. Files ending in `.br` or `.gz` are served with the matching
`Content-Encoding`, so an engine that requests exactly those file names (Unity) can ship pre-compressed files; an engine
that requests plain names (Godot, Cocos, Phaser, GameMaker, Defold, Construct) must ship them uncompressed.

Loading: call the loading calls so the portal can show a progress bar: call `zoko.game.loading_start()` when your loading collection starts, `zoko.game.loading_progress(p)` as proxies load, and `zoko.game.loading_stop()` when
the player can act.

## Troubleshooting

- `zoko.is_native` is false in the browser: the bundle was made without native extensions; the polling fallback still works (up to 50 ms latency).
- `module 'zokogames.bridge_js' not found`: copy the whole `zokogames/` folder; regenerate with `node tools/embed-defold-bridge.mjs` after editing `web/zokogames_bridge.js`.
- Callbacks never fire: call `zoko.init` first and keep the objects that own the callbacks alive.
- Build server error in `zokogames_ext.cpp`: report the Defold version and the full log.
- `sdkNotLoaded`: the browser could not load the SDK script (offline or blocked).

## Upload

Bundle for HTML5, zip the bundle folder contents so `index.html` is at the archive root, and upload it in the developer console.
Documentation: `/docs/engines/defold` on the portal.
