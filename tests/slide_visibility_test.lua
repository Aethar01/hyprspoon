-- The native bridge must not re-enter Lua from run/begin. Check the bridge
-- source without loading it into Hammerspoon or creating overlay windows.
local file = assert(io.open("hyprspoon/native/slide.m"))
local source = file:read("*a")
file:close()
for _, name in ipairs({ "run", "begin" }) do
    local body = assert(source:match("static int l_" .. name .. "%b()%s*(%b{})"))
    assert(not body:find("notifyVisibility", 1, true), name .. " must return before visibility reaches Lua")
    assert(not body:find("luaCallback", 1, true), name .. " must not call Lua inline")
end
local _, count = source:gsub("notifyVisibility", "")
assert(count == 2, "visibility delivery has one definition and one dispatch-source handler")
assert(source:find("dispatch_source_set_event_handler_f(visibility, notifyVisibility);", 1, true))
local order = assert(source:match("static void orderWindow%b()%s*(%b{})"))
assert(order:find("dispatch_source_merge_data(visibility, 1)", 1, true),
    "overlay transitions must still enqueue visibility delivery")
print("Slide visibility bridge tests passed")
