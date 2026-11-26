# Changelog

## 1.8.0 (2026-11-25)

- Targets the JavaScript SDK 1.8.0 (additive). The constant that reports the SDK release now reads `"1.8.0"` (`zokogames.VERSION`).
- `zoko.banner.hide_all_banners(callback)` and `zoko.banner.show_all_banners(callback)`: hide or show every banner without clearing it.
- `zoko.user.encrypt_score(score, key, callback, earned_at)`: `callback(err, payload)` gives the payload for `submit_score`; guests get `userNotAuthenticated`, a bad score or key `invalidArgument`. The simulator answers with `simulated-score.<base64>`.
- `zoko.game.get_game_id()` (`game.gameId`; simulator `simulated-game`), `zoko.data.mirror_indexeddb(databases, callback)` and `zoko.data.stop_mirror_indexeddb()` (`data.mirrorIndexedDB`): `sys.save` files on HTML5 live in IndexedDB, so call the mirror right after init and wait for its callback before `sys.load`.

## 1.7.0 (2026-11-23)

- Targets the JavaScript SDK 1.7.0 (additive). The constant that reports the SDK release now reads `"1.7.0"` (`zokogames.VERSION`).
- Room left event: `zoko.game.room.add_left_listener(fn)` / `remove_left_listener(fn)` with `fn(reason, room_id)` (reason `"left"`, `"kicked"`, `"closed"` or `"disconnected"`), and the event `"left"` (`data = { reason, room_id }`) for `room.set_listener`.
- `zoko.analytics.track(name, params)` (fire and forget; the simulator checks the name).
- `data.mirrorIndexedDB` is not bound yet: it must run in the page before the engine boots. `game.gameId` is still not bound.

## 1.6.4 of the JavaScript SDK (source only, 2026-11-23)

- No plugin change: targets SDK 1.6.4 (delayed scores are not wrapped). The only SDK change a plugin can notice: in local mode the mock now refuses a midgame ad with `adCooldown` until the game has called gameplay start (or 30 seconds of visible page time have passed), so call `gameplayStart` when play begins, before the first midgame ad. The wrapper constant that reports the SDK version now reads `"1.6.4"` in this source; the published zips keep reporting the version they were built with until the next plugin release. Nothing to do for games already built with the plugin.

## 1.6.3 of the JavaScript SDK (source only, 2026-11-22)

- Targets the JavaScript SDK 1.6.3 (messages and console warnings only, plus one fix: `ad.requestAd` resolves when the callbacks object cannot be read; no wrapper API change and no wrapper change is needed). The wrapper constant that reports the SDK version now reads `"1.6.3"` in this source; the published zips keep reporting the version they were built with until the next plugin release. Nothing to do for games already built with the plugin.

## Unreleased

- Targets the JavaScript SDK 1.6.2 (additive: one-time console notices, reserved host labels at any depth, read-only `SDK.game.gameId`, which the wrapper does not expose yet; no wrapper change is needed). The wrapper constant that reports the SDK version now reads `"1.6.2"` in this source; the published zips report `"1.6.1"` until the next plugin release. Nothing to do for games already built with this plugin.

## 1.6.2 (2026-11-21)

- Targets the JavaScript SDK 1.6.1 (a security hardening of the SDK itself: init is answered only by portal pages, a local page counts only for a local game; no wrapper API change). The constant that reports the SDK release now reads `"1.6.1"` (`zokogames.VERSION`). Nothing to do for games already built with this plugin.
- The shared bridge core (`web/zokogames_bridge.js` and `bridge_js.lua`) validates like the SDK: store page `limit` / `offset` reach the SDK unchanged (an invalid one is now `invalidArgument` instead of the default page), the user-token call passes the key type on (`""` keeps the default), a room send target must be a member id, a room state change refuses a `remove` that is not a list of keys and a `patch` that is not an object, and the store sandbox flag must be a boolean (the wrapper converts its own argument).
- Fix: a second ad request while an ad plays is refused by the SDK with an ad error ("Another ad request is already in progress"). That refused request released the wrapper's mute of the "master" sound group, so the game was heard again under the ad still on screen. Only the request whose ad started releases it now; the refused request still reports its error.
- Simulator fixes found by checking every wrapper against the SDK source:
- Fix: the simulator rejected `submit_score("", score)`; the SDK accepts an empty `encrypted_score` (boards without an encryption key) and only requires a string and a finite number. The simulator now applies the same rule.
- Fix: in the simulator `store.set_sandbox()` and `store.get_purchase_token()` failed when `sim.store_available` was false; in the SDK neither depends on store availability (the token only needs a signed-in player).
- Fix: the simulator's 30 s banner cooldown was measured with `os.clock()` (CPU time, which runs slower than real time); it uses `socket.gettime()` now.

## 1.6.1 (2026-11-20)

- Still targets the JavaScript SDK 1.6.0 (`zokogames.VERSION` stays `"1.6.0"`); this release fixes extension code only. Built with the official bob 1.14.1 (`wasm-web`: the library resolves as a dependency, the Lua compiles, a bundle without the native extension passes every call in headless Chrome) and the C++ checked against the 1.14.1 SDK headers; the native extension itself was not compiled, as that needs Defold's build server (see `VERIFY.md`). The plugin version is now in `game.project` (`[project] version`).
- Fix: the Lua listener ran without a script instance (a raw registry ref and `lua_pcall`), so callbacks that use `go.*` or a relative `msg.post` failed. It is now a `dmScript::LuaCallbackInfo` (`CreateCallback`, `SetupCallback` + `PCall` + `TeardownCallback`, `DestroyCallback`). The Lua `on_native` accepts both `(self, json)` and `(json)`.
- Fix: `lib/web/lib_zokogames.js` uses `addToLibrary` when the toolchain has it and falls back to `mergeInto`.
- Fix: `zokogames_ext.cpp` defines `DLIB_LOG_DOMAIN` before including `dmsdk/sdk.h`; without it the build log warned "DLIB_LOG_DOMAIN is not defined" and engine log lines from the extension had no `ZokoGames` domain.
- Docs: copy `/builtins/manifests/web/engine_template.html`, point **.html Shell** at the copy and add the SDK tag to it.

## 1.6.0 (2026-11-19)

- Matches the JavaScript SDK 1.6.0 (additive): `update_room` passes `isPublic` (bool) through like every other key (doc comment only, no code change).

## 1.5.0 (2026-11-19)

- Matches the JavaScript SDK 1.5.0 (additive): `game.settings` carries `kidsMode` (true when the game runs in kids mode: no chat, rooms, sign-in prompts or personalised ads). A portal that predates it does not send the field; keep honouring `disableChat`. The simulator/editor mock reports `kidsMode: false` unless kids mode is switched on, and then also turns chat off, like the portal. The SDK's new `LeaderboardEntry` type (leaderboard rows: `isYou`, opaque per-game `userId`) is type only and has no wrapper binding, as the SDK has no leaderboard read call. No existing API changes.
- `zoko.settings.kidsMode` (nil on older portals: test `== true`); simulator `zoko.sim.kids_mode`.

## 1.4.1 (2026-11-19)

- Matches the JavaScript SDK 1.4.1 (a fix release with no API change: inside the portal the handshake waits up to 15 s instead of 1.5 s, per-key user tokens, game calls that resolve with a warning when the portal does not answer, cheaper cloud-save writes with retried syncs). No wrapper API change from the SDK side.

- After an ad, the sign-in or account-link prompt or a checkout, keyboard focus is handed back to the game frame and its canvas (shared bridge core), so keys work without a click.
- New `zoko.mute_audio_during_ads` and `zoko.follow_portal_mute` (both default true): the "master" sound group gain is set to 0 while an ad plays and while the portal asks for mute, and the game's gain is restored afterwards.
- `tools/sync-core.mjs` now regenerates `bridge_js.lua` with the bridge, so the embedded copy cannot lag behind.
- README: rows for the ad callbacks, `ERROR_CODE_DESCRIPTIONS`, `SDK_VERSION`; `ERROR_CODES.room` listed. New `TESTING.md`.

## 1.4.0

- Matches the JavaScript SDK 1.4.0 (`game.reportChat`, `game.onScreenshotRequest`, `data.mirrorLocalStorage`, all additive). Real engine bindings for all three: chat reports, a screenshot provider (with a default end-of-frame capture) and the localStorage mirror, each with editor/mock behaviour and tests. The mirror only sees browser localStorage, not the IndexedDB saves most engines use. No existing API changes.

## 1.3.1

- Matches the JavaScript SDK 1.3.1 (a fix release: the ad request times out after 30 s when the host never answers, malformed host messages are ignored, `SDK.init()` is safe without `window`, loading the script twice keeps the first instance, and `ERROR_CODE_DESCRIPTIONS` is exported). No wrapper API change.

## 1.3.0

- Matches the JavaScript SDK 1.3.0: adds the room data channel (`game.room`): `zoko.game.room` with `send`, `send_to`, `set_state`, `remove_state`, `get_state`, `members`, `is_host`, `self_id`, `set_listener(self, fn)` (`fn(self, event, data)`) and the per-event `add_*_listener` / `remove_*_listener` pairs, a Lua simulator that loops messages back, and `examples/room.script`. `ERROR_CODES` gains `room`.

## 1.2.0

- Matches the JavaScript SDK 1.2.0: adds offline awareness, a read-only offline flag plus a change notification (see the README coverage table for `game.isOffline`, `game.addOfflineListener`, `game.removeOfflineListener`).
- Adds the achievements module (additive): list, unlock and an unlock notification (see the README coverage table for `achievements.list`, `achievements.unlock`, `achievements.onUnlock`).

## 1.1.1

- Matches the JavaScript SDK 1.1.1: the banner refresh floor now holds across clear and request cycles, and local mode reads invite parameters from the page URL.

## 1.1.0

- Matches the JavaScript SDK 1.1.0: `store.getPurchaseToken` (`user.getXsollaUserToken` stays as a deprecated alias) and the `ERROR_CODES` tables, with a purchases example.

## 1.0.0

- Full coverage of the JavaScript SDK 1.0.0: ad, banner, game, user, data, store, analytics, events and error codes.
- New in this release: `game.loadingProgress`, `game.showInviteButton` / `hideInviteButton`, `game.isInstantJoin`,
  `store.getPurchaseToken` (`user.getXsollaUserToken` kept as a deprecated alias), the `ERROR_CODES` tables, the whole `store` module (catalogue, inventory, buy, consume, sandbox).
- Added the native extension (`ext.manifest`, `src/zokogames_ext.cpp`, `lib/web/lib_zokogames.js`) with a polling fallback, store module, loading progress and payment token.
- Coverage is enforced: `node tools/check-coverage.mjs` fails when this README's API table misses a JS SDK member.
