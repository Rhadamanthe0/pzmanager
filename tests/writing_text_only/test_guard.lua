local registered = {}
local names = { "OnTickEvenPaused", "LoadGridsquare", "OnObjectAdded", "OnFillContainer", "OnClientCommand", "OnContainerUpdate" }
Events = {}
for _, name in ipairs(names) do
    registered[name] = {}
    Events[name] = { Add = function(f) table.insert(registered[name], f) end }
end
isServer = function() return true end
instanceof = function(v, class) return v and v.classes and v.classes[class] or false end
getTimestampMs = function() return 10000 end
local function list(data)
    return { size = function() return #data end, get = function(_, i) return data[i + 1] end }
end
local function book(doc)
    return { classes = { Literature = true }, vanilla = { [1] = "Texte français préservé" },
        getContainer = function() return {} end,
        hasModData = function() return doc ~= nil end,
        getModData = function() return { NeatWriting = doc } end }
end
local function container(items)
    return { getItems = function() return list(items) end }
end
local function bag(inv)
    return { classes = { InventoryContainer = true }, getInventory = function() return inv end }
end
local synced = 0
syncItemModData = function(player, item)
    assert(item:getModData().NeatWriting.p["1"].ink == nil)
    synced = synced + 1
end
local square = nil
getCell = function() return { getGridSquare = function() return square end } end
getOnlinePlayers = function() return list({}) end

dofile("PZManagerWritingTextOnly.lua")
local G = PZManagerWritingTextOnly
local note = { { t = "Merci beaucoup!", x = 20, y = 30, r = 12, s = 1.5 } }
local extra = { ["20"] = "Extra text" }
local pos = { x = 100, y = 300 }
local doc = { v = 1, t = extra, p = { ["1"] = { ink = { { p = { 1, 2, 3, 4 } } }, sym = { { id = "Star" } }, note = note, tc = "red", textpos = pos }, ["2"] = {} } }
local b = book(doc)
assert(G.cleanItem(b, {}))
assert(synced == 1 and doc.p["1"].ink == nil and doc.p["1"].sym == nil)
assert(doc.t == extra and doc.p["1"].note == note and doc.p["1"].textpos == pos and doc.p["1"].tc == "red")
assert(b.vanilla[1] == "Texte français préservé")
assert(not G.cleanItem(b, {}))
assert(synced == 1)
-- A loose ground book has no container identity: clean it without a sync packet.
local groundDoc = { t = { ["20"] = "Texte supplémentaire au sol" },
    p = { ["1"] = { ink = { { p = { 1, 2 } } }, sym = { { id = "Star" } }, note = note } } }
local groundBook = book(groundDoc)
groundBook.getContainer = function() return nil end
local beforeGroundSync = synced
assert(G.cleanItem(groundBook, {}))
assert(groundDoc.p["1"].ink == nil and groundDoc.p["1"].sym == nil)
assert(synced == beforeGroundSync)
assert(groundBook.vanilla[1] == "Texte français préservé")
assert(groundDoc.t["20"] == "Texte supplémentaire au sol" and groundDoc.p["1"].note == note)
-- Paper/world-map drawing layout has no doc.p: leave map annotations alone.
local mapdoc = { ink = { { p = { 1, 2 } } }, sym = { { id = "Town" } } }
assert(not G.cleanDoc(mapdoc) and mapdoc.ink and mapdoc.sym)
assert(not G.cleanItem({ classes = { MapItem = true } }, {}))
assert(not G.cleanItem(book(nil), {}))
assert(not G.cleanDoc(false))
assert(not G.cleanDoc({p = { ["1"] = false }}))
-- Purge malformed legacy lists without iterating their contents.
local legacy = { p = { ["1"] = { ink = "oversized string", sym = false, note = note } }, ink = {}, sym = {} }
assert(G.cleanDoc(legacy) and legacy.ink == nil and legacy.sym == nil and legacy.p["1"].note == note)
-- Nested inventories, plus a cycle caused by an imperfect command double.
local nestedDoc = { p = { ["1"] = { ink = {} } }, t = extra }
local nestedItems = { book(nestedDoc) }
local nested = container(nestedItems)
table.insert(nestedItems, bag(nested))
local inv = container({bag(container({bag(nested)}))})
G.cleanContainer(inv, nil)
assert(nestedDoc.p["1"].ink == nil)
-- New client edit is caught before ordinary player autosave by tick hook.
doc.p["1"].ink = {}
local player = { getInventory = function() return container({b}) end,
    getX = function() return 100 end, getY = function() return 100 end, getZ = function() return 0 end }
getOnlinePlayers = function() return list({player}) end
registered.OnTickEvenPaused[1]()
assert(doc.p["1"].ink == nil)
-- World dropped item, nested dropped bag and corpse/container contents.
local worlddoc = { p = { ["1"] = { ink = {}, sym = {} } } }
local worldbook = book(worlddoc)
local worldObj = { classes = { IsoWorldInventoryObject = true, IsoObject = true }, getItem = function() return worldbook end,
    getContainerCount = function() return 0 end }
square = { getObjects = function() return list({worldObj}) end, getStaticMovingObjects = function() return list({}) end }
registered.LoadGridsquare[1](square)
assert(worlddoc.p["1"].ink == nil and worlddoc.p["1"].sym == nil)
worlddoc.p["1"].sym = {}
registered.OnObjectAdded[1](worldObj)
assert(worlddoc.p["1"].sym == nil)
worlddoc.p["1"].ink = {}
registered.OnTickEvenPaused[1]()
assert(worlddoc.p["1"].ink == nil)
worlddoc.p["1"].ink = {}
registered.OnFillContainer[1]("room", "shelf", container({worldbook}))
assert(worlddoc.p["1"].ink == nil)
-- Idempotent load: no doubled callbacks.
dofile("PZManagerWritingTextOnly.lua")
for _, name in ipairs(names) do assert(#registered[name] == 1) end
assert(G.failures == 0)
print("PASS: preservation, idempotence, nested/cyclic inventory, ticks and world events")
