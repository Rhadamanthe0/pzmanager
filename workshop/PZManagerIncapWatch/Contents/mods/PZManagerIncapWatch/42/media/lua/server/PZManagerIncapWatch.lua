--[[
  PZManagerIncapWatch.lua  --  SERVER-SIDE ONLY (media/lua/server/)

  Detecte l'entree en etat d'incapacite (mod "REVIVAL by Jaxe" / JaxeRevival) de
  chaque joueur connecte et l'ecrit dans Zomboid/Logs/<session>_pzmanager.txt via
  writeLog(). Le bot Discord PZManager taile ce fichier pour annoncer les
  incapacites NON-PvP (les incapacites/morts PvP viennent deja de pvp.txt).

  Ce fichier vit dans media/lua/server/ : il n'est JAMAIS charge cote client. Le
  mod est publie sur le Workshop uniquement pour que les clients le possedent
  (obligatoire : toute entree de Mods= doit exister sur le client), mais il
  n'execute rien chez eux.

  Detection : on relit toutes les 5 s l'etat pose par JaxeRevival sur le serveur
  (moddata JaxeRevival_Incapacitated, sinon seuil de vie IncapacitatedHealth, la
  meme condition que le OnTick du mod). On ne logge que la TRANSITION (entree en
  incapacite), une fois par joueur, jusqu'a sa reanimation/mort/deconnexion.
]]

if isClient() and not isServer() then return end  -- garde-fou : jamais sur un client pur

local POLL_MS = 5000
local INCAP_KEY = "JaxeRevival_Incapacitated"

local wasIncap = {}   -- username -> true : incapacites deja loggues (anti-repetition)
local lastPoll = 0

local function incapHealthThreshold()
  if SandboxVars and SandboxVars.JaxeRevival and SandboxVars.JaxeRevival.IncapacitatedHealth then
    return SandboxVars.JaxeRevival.IncapacitatedHealth
  end
  return 25
end

local function isIncapacitated(player)
  if player:isDead() then return false end
  local md = player:getModData()
  if md and md[INCAP_KEY] then return true end
  local bd = player:getBodyDamage()
  return bd ~= nil and bd:getHealth() < incapHealthThreshold()
end

local function positionOf(player)
  local sq = player:getSquare()
  if sq then return sq:getX(), sq:getY(), sq:getZ() end
  return math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
end

local function poll()
  local players = getOnlinePlayers()
  if not players then return end

  local seen = {}
  for i = 0, players:size() - 1 do
    local player = players:get(i)
    if player then
      local username = player:getUsername()
      if username then
        seen[username] = true
        if isIncapacitated(player) then
          if not wasIncap[username] then
            wasIncap[username] = true
            local x, y, z = positionOf(player)
            writeLog("pzmanager", string.format('INCAPACITATED "%s" @ %d,%d,%d', username, x, y, z))
          end
        else
          wasIncap[username] = nil  -- reanime / mort / plus incapacite -> re-armable
        end
      end
    end
  end

  for username in pairs(wasIncap) do            -- purge des deconnectes
    if not seen[username] then wasIncap[username] = nil end
  end
end

local function onTick()
  local now = getTimestampMs()
  if now - lastPoll < POLL_MS then return end
  lastPoll = now
  poll()
end

Events.OnTick.Add(onTick)
print("[PZManagerIncapWatch] Server-side incapacitation watcher loaded (poll " .. POLL_MS .. " ms).")
