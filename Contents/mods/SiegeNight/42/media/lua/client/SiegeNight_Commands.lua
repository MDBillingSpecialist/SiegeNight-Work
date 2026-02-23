--[[
    SiegeNight_Commands.lua
    Player-facing chat commands for Siege Night. CLIENT-SIDE.

    Commands (type in chat):
    !siege start    â€” Start a siege immediately (admin only in MP)
    !siege stop     â€” End the current siege (admin only in MP)
    !siege status   â€” Show current siege state and stats
    !siege next     â€” Show when the next siege is scheduled
    !siege vote     â€” Start a vote to trigger a siege (any player)
]]

local SN = require("SiegeNight_Shared")

-- ==========================================
-- VOTE STATE
-- ==========================================
local voteActive = false
local voteYes = {}
local voteTotal = 0
local voteStartTime = 0
local VOTE_TIMEOUT_MS = 60000  -- 60 seconds to vote

-- ==========================================
-- CHAT COMMAND HANDLER
-- ==========================================

-- Safely suppress chat message display (methods may not exist in all PZ versions)
local function suppressMessage(chatMessage)
    if chatMessage.setOverHeadSpeech then chatMessage:setOverHeadSpeech(false) end
    if chatMessage.setShowInChat then chatMessage:setShowInChat(false) end
end

local function onChatMessage(chatMessage)
    if not chatMessage then return end

    local text = chatMessage:getText()
    if not text then return end

    -- Only process !siege commands (using ! prefix because PZ intercepts / as built-in commands)
    if not luautils.stringStarts(text, "!siege") then return end

    local player = getPlayer()
    if not player then return end

    local parts = {}
    for word in text:gmatch("%S+") do
        table.insert(parts, word:lower())
    end

    local subcommand = parts[2] or "help"

    if subcommand == "start" then
        -- Send start request to server
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeStart", {})
        suppressMessage(chatMessage)

    elseif subcommand == "stop" or subcommand == "end" then
        -- Send stop request to server
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeStop", {})
        suppressMessage(chatMessage)

    elseif subcommand == "status" then
        local siegeData = SN.getWorldData()
        if siegeData then
            local kills = siegeData.killsThisSiege or 0
            local spawned = siegeData.spawnedThisSiege or 0
            local target = siegeData.targetZombies or 0
            local state = siegeData.siegeState or "UNKNOWN"
            if state == SN.STATE_ACTIVE then
                player:Say("Siege #" .. siegeData.siegeCount .. " â€” " .. kills .. " killed, " .. spawned .. "/" .. target .. " spawned")
            elseif state == SN.STATE_IDLE then
                player:Say("No siege active. Next: day " .. (siegeData.nextSiegeDay or "?"))
            else
                player:Say("Siege state: " .. state)
            end
        else
            player:Say("Siege Night not loaded yet.")
        end
        suppressMessage(chatMessage)

    elseif subcommand == "next" then
        local siegeData = SN.getWorldData()
        if siegeData then
            local currentDay = math.floor(SN.getActualDay())
            local daysUntil = (siegeData.nextSiegeDay or 0) - currentDay
            if daysUntil <= 0 then
                player:Say("Siege is scheduled for today!")
            else
                player:Say("Next siege in " .. daysUntil .. " day" .. (daysUntil > 1 and "s" or "") .. " (day " .. siegeData.nextSiegeDay .. ")")
            end
        end
        suppressMessage(chatMessage)

    elseif subcommand == "vote" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeVote", {})
        suppressMessage(chatMessage)

    elseif subcommand == "yes" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeVoteYes", {})
        suppressMessage(chatMessage)

    else
        player:Say("Commands: !siege start, stop, status, next, vote")
        suppressMessage(chatMessage)
    end
end

-- ==========================================
-- SERVER RESPONSE HANDLER
-- ==========================================

local function onServerCommand(module, command, args)
    if module ~= SN.CLIENT_MODULE then return end

    local player = getPlayer()
    if not player then return end

    if command == "CmdResponse" then
        local msg = args and args["message"] or "..."
        player:Say(msg)

    elseif command == "VoteStarted" then
        local needed = args and args["needed"] or "?"
        player:Say("Siege vote started! Type !siege yes to vote. Need " .. needed .. " votes.")

    elseif command == "VoteUpdate" then
        local current = args and args["current"] or 0
        local needed = args and args["needed"] or 0
        player:Say("Vote: " .. current .. "/" .. needed)

    elseif command == "VotePassed" then
        player:Say("Vote passed! Siege incoming!")

    elseif command == "VoteFailed" then
        player:Say("Vote failed â€” not enough votes in time.")
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
-- B42 uses OnAddMessage instead of OnChatMessage
if Events.OnAddMessage then
    Events.OnAddMessage.Add(function(message, tabID)
        onChatMessage(message)
    end)
    SN.log("Commands module loaded (OnAddMessage). Type !siege for help.")
elseif Events.OnChatMessage then
    Events.OnChatMessage.Add(onChatMessage)
    SN.log("Commands module loaded (OnChatMessage). Type !siege for help.")
else
    SN.log("WARNING: No chat event found â€” commands will not work!")
end
if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end
