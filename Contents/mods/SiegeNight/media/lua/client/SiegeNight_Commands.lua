--[[
    SiegeNight_Commands.lua
    Player-facing chat commands for Siege Night. CLIENT-SIDE.

    Commands (type in chat):
    !siege start     Start a siege immediately (admin only in MP)
    !siege stop      End the current siege (admin only in MP)
    !siege status    Show current siege state and stats
    !siege next      Show when the next siege is scheduled
    !siege vote      Start a vote to trigger a siege (any player)
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
    -- Defensive: some chat messages come through with non-string text (java null)
    if type(text) ~= "string" then return end

    -- Some servers/overlays prepend text (ex: /say) or add formatting, so search for !siege anywhere.
    local lowered = text:lower()
    local idx = lowered:find("!siege")
    if not idx then return end
    lowered = lowered:sub(idx)

    local player = getPlayer()
    if not player then return end

    local parts = {}
    if type(lowered) ~= "string" then return end
    for word in lowered:gmatch("%S+") do
        table.insert(parts, word:lower())
    end

    local subcommand = parts[2] or "help"

    -- Aliases: allow !siegestop / !siegestart / !siegevote
    if parts[1] == "!siegestop" then subcommand = "stop" end
    if parts[1] == "!siegestart" then subcommand = "start" end
    if parts[1] == "!siegevote" then subcommand = "vote" end


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
                player:Say("Siege #" .. siegeData.siegeCount .. "  " .. kills .. " killed, " .. spawned .. "/" .. target .. " spawned")
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
        if siegeData and siegeData.nextSiegeDay and siegeData.nextSiegeDay > 0 then
            local currentDay = math.floor(SN.getActualDay())
            local daysUntil = siegeData.nextSiegeDay - currentDay
            if daysUntil <= 0 then
                player:Say("Siege is scheduled for today!")
            else
                player:Say("Next siege in " .. daysUntil .. " day" .. (daysUntil > 1 and "s" or "") .. " (day " .. siegeData.nextSiegeDay .. ")")
            end
        else
            player:Say("Siege schedule not synced yet -- try again in a minute!")
        end
        suppressMessage(chatMessage)

    elseif subcommand == "vote" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeVote", {})
        suppressMessage(chatMessage)

    elseif subcommand == "yes" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeVoteYes", {})
        suppressMessage(chatMessage)

    elseif subcommand == "optout" or subcommand == "opt-out" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeOptOut", {})
        suppressMessage(chatMessage)

    elseif subcommand == "optin" or subcommand == "opt-in" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeOptIn", {})
        suppressMessage(chatMessage)

    elseif subcommand == "skipbreak" or subcommand == "skip" then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdSiegeSkipBreak", {})
        suppressMessage(chatMessage)

    elseif subcommand == "testoutfits" then
        player:Say("Testing all outfits... check console for results.")
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdTestOutfits", {})
        suppressMessage(chatMessage)

    else
        player:Say("Commands: !siege start, stop, status, next, vote, skip, optout, optin")
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
        player:Say("Vote failed  not enough votes in time.")
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
    SN.log("WARNING: No chat event found  commands will not work!")
end
if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end
