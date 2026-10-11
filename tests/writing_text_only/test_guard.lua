local registered = 0
Events = setmetatable({}, { __index = function()
    return { Add = function() registered = registered + 1 end }
end })
isServer = function() return true end
dofile("PZManagerWritingTextOnly.lua")
dofile("PZManagerWritingTextOnly.lua")
assert(registered == 0)
assert(PZManagerWritingTextOnly == nil)
print("PASS: legacy Lua entry point is inert; no continuous cleanup callback")
