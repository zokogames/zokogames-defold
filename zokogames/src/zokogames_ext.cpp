// ZokoGames SDK native extension for Defold (HTML5 only does real work; other platforms report is_supported() == false).
//
// Lua API (module `zokogames_native`, used by zokogames/zokogames.lua):
//   zokogames_native.is_supported()                        -> boolean
//   zokogames_native.set_listener(fn(self, json_string))   -- registers fn and the JS sink; fn gets one JSON message at a time
//   zokogames_native.invoke(id, method, args_json)         -- asynchronous call; answers arrive through the listener
//   zokogames_native.invoke_sync(method, args_json)        -> json_string  ({ok=true,result=...} | {ok=false,error=...})
//
// Messages travel JS -> C++ through a queue that is flushed to Lua from the extension's Update, so Lua callbacks always
// run on the engine's own update tick and never re-entrantly. The listener is kept as a dmScript::LuaCallbackInfo
// (CreateCallback / SetupCallback + PCall + TeardownCallback / DestroyCallback, as the Defold SDK documents), so it runs
// with the script instance that called set_listener as the current instance (go.*, msg.post with relative urls work);
// `self` is its first argument. If that instance is gone, the function is still called through a plain registry ref.

#define EXTENSION_NAME ZokoGames
#define LIB_NAME "ZokoGames"
#define MODULE_NAME "zokogames_native"
#define DLIB_LOG_DOMAIN LIB_NAME // before dmsdk/sdk.h, or every dmLog line says "DEFAULT" and the build log warns

#include <dmsdk/sdk.h>

#include <stdlib.h>
#include <string>
#include <vector>

#if defined(DM_PLATFORM_HTML5)

extern "C" {
typedef void (*ZokoMessageFn)(const char* json);
// Implemented in lib/web/lib_zokogames.js
void ZokoGames_JsRegister(ZokoMessageFn fn);
void ZokoGames_JsInvoke(int id, const char* method, const char* args_json);
char* ZokoGames_JsInvokeSync(const char* method, const char* args_json); // malloc'd, caller frees
}

static const bool kSupported = true;

#else

static const bool kSupported = false;

#endif

static dmScript::LuaCallbackInfo* g_listener = 0;
static int g_listener_ref = LUA_NOREF; // the same function, for when the script instance behind g_listener is deleted
static lua_State* g_listener_state = 0;
static std::vector<std::string> g_queue;

static void ClearListener()
{
    if (g_listener != 0)
    {
        dmScript::DestroyCallback(g_listener);
        g_listener = 0;
    }
    if (g_listener_ref != LUA_NOREF && g_listener_state != 0)
        luaL_unref(g_listener_state, LUA_REGISTRYINDEX, g_listener_ref);
    g_listener_ref = LUA_NOREF;
    g_listener_state = 0;
}

#if defined(DM_PLATFORM_HTML5)
static void OnJsMessage(const char* json)
{
    if (json != 0) g_queue.push_back(json);
}
#endif

static int IsSupported(lua_State* L)
{
    lua_pushboolean(L, kSupported ? 1 : 0);
    return 1;
}

static int SetListener(lua_State* L)
{
    luaL_checktype(L, 1, LUA_TFUNCTION);
    ClearListener();
    g_listener = dmScript::CreateCallback(L, 1); // 0 when called outside a script instance
    lua_pushvalue(L, 1);
    g_listener_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    g_listener_state = L;
#if defined(DM_PLATFORM_HTML5)
    ZokoGames_JsRegister(OnJsMessage);
#endif
    return 0;
}

static int Invoke(lua_State* L)
{
#if defined(DM_PLATFORM_HTML5)
    int id = (int)luaL_checkinteger(L, 1);
    const char* method = luaL_checkstring(L, 2);
    const char* args = luaL_optstring(L, 3, "{}");
    ZokoGames_JsInvoke(id, method, args);
#else
    (void)L;
#endif
    return 0;
}

static int InvokeSync(lua_State* L)
{
#if defined(DM_PLATFORM_HTML5)
    const char* method = luaL_checkstring(L, 1);
    const char* args = luaL_optstring(L, 2, "{}");
    char* result = ZokoGames_JsInvokeSync(method, args);
    if (result != 0)
    {
        lua_pushstring(L, result);
        free(result);
        return 1;
    }
#else
    (void)L;
#endif
    lua_pushstring(L, "{\"ok\":false,\"error\":{\"code\":\"sdkNotLoaded\",\"message\":\"Native bridge unavailable\"}}");
    return 1;
}

static const luaL_reg Module_methods[] = {
    {"is_supported", IsSupported},
    {"set_listener", SetListener},
    {"invoke", Invoke},
    {"invoke_sync", InvokeSync},
    {0, 0}};

static void LuaInit(lua_State* L)
{
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, Module_methods);
    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

static dmExtension::Result AppInitializeZoko(dmExtension::AppParams* params) { return dmExtension::RESULT_OK; }

static dmExtension::Result InitializeZoko(dmExtension::Params* params)
{
    LuaInit(params->m_L);
    return dmExtension::RESULT_OK;
}

static dmExtension::Result UpdateZoko(dmExtension::Params* params)
{
    if (g_queue.empty() || g_listener_ref == LUA_NOREF) return dmExtension::RESULT_OK;
    // Messages pushed while we deliver are handled on the next tick.
    std::vector<std::string> batch;
    batch.swap(g_queue);
    for (size_t i = 0; i < batch.size(); ++i)
    {
        if (g_listener != 0 && dmScript::IsCallbackValid(g_listener))
        {
            lua_State* L = dmScript::GetCallbackLuaContext(g_listener);
            DM_LUA_STACK_CHECK(L, 0);
            if (dmScript::SetupCallback(g_listener)) // pushes the function and self, makes the instance current
            {
                lua_pushlstring(L, batch[i].c_str(), batch[i].size());
                dmScript::PCall(L, 2, 0); // self + the message; logs a traceback on error
                dmScript::TeardownCallback(g_listener);
                continue;
            }
        }
        // No usable script instance: call the function directly with self = nil.
        lua_State* L = g_listener_state != 0 ? g_listener_state : params->m_L;
        lua_rawgeti(L, LUA_REGISTRYINDEX, g_listener_ref);
        lua_pushnil(L);
        lua_pushlstring(L, batch[i].c_str(), batch[i].size());
        dmScript::PCall(L, 2, 0); // on error PCall logs the traceback and pops the message itself
    }
    return dmExtension::RESULT_OK;
}

static dmExtension::Result AppFinalizeZoko(dmExtension::AppParams* params) { return dmExtension::RESULT_OK; }

static dmExtension::Result FinalizeZoko(dmExtension::Params* params)
{
    ClearListener();
    g_queue.clear();
    return dmExtension::RESULT_OK;
}

DM_DECLARE_EXTENSION(EXTENSION_NAME, LIB_NAME, AppInitializeZoko, AppFinalizeZoko, InitializeZoko, UpdateZoko, 0, FinalizeZoko)
