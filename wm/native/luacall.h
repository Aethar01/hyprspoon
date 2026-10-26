// wm/native/luacall.h: Calling Lua back from native callbacks (event taps,
// WindowServer notifications), which run on the main thread between Lua's
// own calls.

#pragma once

#include "lauxlib.h"
#include "lua.h"

// Reads the list of window ids at `index` into `out` (room for `max`);
// returns how many.
static inline int luaWindowIds(lua_State *L, int index, uint32_t *out, int max) {
    int count = 0;
    lua_Integer n = luaL_len(L, index);
    for (lua_Integer i = 1; i <= n && count < max; i++) {
        lua_rawgeti(L, index, i);
        uint32_t wid = (uint32_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (wid) out[count++] = wid;
    }
    return count;
}

// A Lua function kept for a callback: the state it lives in and its
// registry reference.
typedef struct {
    lua_State *L;
    int ref;
} LuaCallback;

#define LUA_CALLBACK_NONE { NULL, LUA_NOREF }

// Keeps the function at `index` (or forgets the callback if it isn't one).
static inline void luaCallbackSet(LuaCallback *cb, lua_State *L, int index) {
    if (cb->L && cb->ref != LUA_NOREF) luaL_unref(cb->L, LUA_REGISTRYINDEX, cb->ref);
    cb->L = NULL;
    cb->ref = LUA_NOREF;
    if (lua_isfunction(L, index)) {
        lua_pushvalue(L, index);
        cb->ref = luaL_ref(L, LUA_REGISTRYINDEX);
        cb->L = L;
    }
}

static inline void luaCallbackClear(LuaCallback *cb) {
    if (cb->L && cb->ref != LUA_NOREF) luaL_unref(cb->L, LUA_REGISTRYINDEX, cb->ref);
    cb->L = NULL;
    cb->ref = LUA_NOREF;
}

// Pushes the callback's function; false (nothing pushed) if there is none.
static inline bool luaCallbackPush(LuaCallback *cb) {
    if (!cb->L || cb->ref == LUA_NOREF) return false;
    lua_rawgeti(cb->L, LUA_REGISTRYINDEX, cb->ref);
    return true;
}

static inline int luaCallbackTraceback(lua_State *L) {
    luaL_traceback(L, L, lua_tostring(L, 1), 1);
    return 1;
}

// Calls the function pushed below `nargs` arguments. An error is printed to
// the console rather than raised: there is no Lua caller to raise it to.
static inline void luaCallbackCall(LuaCallback *cb, int nargs) {
    lua_State *L = cb->L;
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, luaCallbackTraceback);
    lua_insert(L, base);
    if (lua_pcall(L, nargs, 0, base) != LUA_OK) {
        lua_getglobal(L, "print");
        lua_pushvalue(L, -2);
        lua_pcall(L, 1, 0, 0);
        lua_pop(L, 1);
    }
    lua_remove(L, base);
}
