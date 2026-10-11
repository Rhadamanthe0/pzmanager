-- Server-only policy for the stock ProjectWriting Workshop mod.
-- Set ProjectWriting.Freehand=false and VanillaMap=true in the server sandbox.
-- Lua server hooks do not intercept SyncItemModDataPacket.parse: this is a
-- normal-use guard, not a packet firewall or a guaranteed pre-save hook.
if not isServer() then return end
if PZManagerWritingTextOnly then return end

local G = { cleaned = 0, failures = 0, column = 0 }
PZManagerWritingTextOnly = G

-- Removing whole stroke/symbol lists avoids walking thousands of coordinates.
-- Keep vanilla pages, extra doc.t pages, notes, text colours and positions.
function G.cleanDoc(doc)
    if type(doc) ~= "table" or type(doc.p) ~= "table" then return false end
    local changed = false
    for _, page in pairs(doc.p) do
        if type(page) == "table" then
            if page.ink ~= nil then page.ink = nil; changed = true end
            if page.sym ~= nil then page.sym = nil; changed = true end
        end
    end
    -- Legacy book documents can also carry these fields at the root.
    if doc.ink ~= nil then doc.ink = nil; changed = true end
    if doc.sym ~= nil then doc.sym = nil; changed = true end
    return changed
end

function G.cleanItem(item, player)
    if not item or not instanceof(item, "Literature") then return false end
    if not item:hasModData() then return false end
    local doc = item:getModData().NeatWriting
    if not G.cleanDoc(doc) then return false end
    G.cleaned = G.cleaned + 1
    -- Server syncItemModData broadcasts the cleaned item to nearby clients.
    -- No fields/pages sync: those remain untouched.
    if player and item:getContainer() and syncItemModData then
        syncItemModData(player, item)
    end
    return true
end

local function visitContainer(container, player, seen)
    if not container or seen[container] then return end
    seen[container] = true
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        G.cleanItem(item, player)
        if instanceof(item, "InventoryContainer") then
            visitContainer(item:getInventory(), player, seen)
        end
    end
end

function G.cleanContainer(container, player)
    visitContainer(container, player, {})
end

function G.cleanObject(object, player)
    if not object then return end
    if instanceof(object, "IsoWorldInventoryObject") then
        local item = object:getItem()
        G.cleanItem(item, player)
        if item and instanceof(item, "InventoryContainer") then
            G.cleanContainer(item:getInventory(), player)
        end
    end
    if instanceof(object, "IsoObject") then
        for i = 0, object:getContainerCount() - 1 do
            G.cleanContainer(object:getContainerByIndex(i), player)
        end
    end
end

function G.cleanSquare(square, player)
    if not square then return end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do G.cleanObject(objects:get(i), player) end
    local bodies = square:getStaticMovingObjects()
    for i = 0, bodies:size() - 1 do G.cleanObject(bodies:get(i), player) end
end

-- Bounded nearby sweep catches new dropped/placed books even when a packet
-- produces no Lua container event. Complete 9x9 sweep in nine update ticks.
local function cleanNearby(player, column)
    local cell = getCell()
    if not cell then return end
    local x = math.floor(player:getX()) + column - 4
    local y = math.floor(player:getY())
    local z = math.floor(player:getZ())
    for dy = -4, 4 do G.cleanSquare(cell:getGridSquare(x, y + dy, z), player) end
end

function G.onTick()
    local players = getOnlinePlayers()
    local column = G.column
    G.column = (column + 1) % 9
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        G.cleanContainer(player:getInventory(), player)
        cleanNearby(player, column)
    end
end

-- Report failures instead of silently losing the policy on an API mismatch.
-- Log only once per minute to avoid log/memory storms on a persistent fault.
local lastErrorAt = nil
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if ok then return end
        G.failures = G.failures + 1
        local now = getTimestampMs()
        if not lastErrorAt or now - lastErrorAt >= 60000 then
            lastErrorAt = now
            print("[PZManagerWritingTextOnly] ERROR: " .. tostring(err))
        end
    end
end

-- OnTickEvenPaused runs near the start of IngameState.update; OnTick runs
-- later, before NetworkPlayerManager.update's ordinary player autosave.
-- ServerMap.preupdate can already save before either event: keep that limit
-- explicit. Enforced Freehand=false prevents stock clients creating strokes.
Events.OnTickEvenPaused.Add(guarded(G.onTick))
Events.LoadGridsquare.Add(guarded(G.cleanSquare))
Events.OnObjectAdded.Add(guarded(G.cleanObject))
Events.OnFillContainer.Add(guarded(function(room, kind, container)
    G.cleanContainer(container, nil)
end))
Events.OnClientCommand.Add(guarded(function(module, command, player)
    if player then G.cleanContainer(player:getInventory(), player) end
end))
Events.OnContainerUpdate.Add(guarded(function(object)
    if object then G.cleanObject(object, nil) end
end))
print("[PZManagerWritingTextOnly] Loaded: book drawings and symbols are removed; text is preserved.")
