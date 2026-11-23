// Emscripten JS library for the ZokoGames Defold extension (HTML5 only).
// The browser side (window.ZokoDefold) is evaluated by zokogames.lua before set_listener() runs; this file only connects
// it to the C++ side: results are pushed to `sink` as JSON strings and handed to a C function pointer.
var LibZokoGames = {
  ZokoGames_JsRegister: function (fnPtr) {
    var z = window.ZokoDefold;
    if (!z) return;
    z.sink = function (json) {
      var length = lengthBytesUTF8(json) + 1;
      var buffer = _malloc(length);
      stringToUTF8(json, buffer, length);
      {{{ makeDynCall('vi', 'fnPtr') }}}(buffer);
      _free(buffer);
    };
    // Messages the bridge queued before the sink existed (poll mode data) would otherwise never reach Lua.
    var queued = typeof z.poll === 'function' ? z.poll() : '';
    if (queued) {
      var list = JSON.parse(queued);
      for (var i = 0; i < list.length; i++) z.sink(JSON.stringify(list[i]));
    }
  },

  ZokoGames_JsInvoke: function (id, methodPtr, argsPtr) {
    var z = window.ZokoDefold;
    if (z) z.invoke(id, UTF8ToString(methodPtr), UTF8ToString(argsPtr));
  },

  ZokoGames_JsInvokeSync: function (methodPtr, argsPtr) {
    var z = window.ZokoDefold;
    var json = z ? z.invokeSync(UTF8ToString(methodPtr), UTF8ToString(argsPtr))
                 : '{"ok":false,"error":{"code":"sdkNotLoaded","message":"Bridge not loaded"}}';
    var length = lengthBytesUTF8(json) + 1;
    var buffer = _malloc(length);
    stringToUTF8(json, buffer, length);
    return buffer; // freed by the C++ caller
  }
};

// addToLibrary is the current Emscripten API (used by Defold's own HTML5 extension example); mergeInto is its older name,
// kept for toolchains that predate it.
if (typeof addToLibrary === 'function') addToLibrary(LibZokoGames);
else mergeInto(LibraryManager.library, LibZokoGames);
