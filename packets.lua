-- packets.lua
-- Packet handlers for xpReborn.
-- Pure data module — mutates state only, no UI side effects.
-- Called from xpReborn.lua event handlers.

local dedicationItems = require('data/dedicationItems')

local M = {}

-- Packet IDs
M.ID = {
    XP_MESSAGE = 0x002D,
    ACTION     = 0x0028,
    ZONE_IN    = 0x000A,
    ZONE_OUT   = 0x000B,
}

-- XP/LP message IDs (packet 0x02D)
local XP_MSGS = { [8] = true, [253] = true, [371] = true, [372] = true }

-- Buff ID for dedication effect
local BUFF_DEDICATION = 249

-- Items that grant XP directly on use (not dedication multipliers).
-- XP from these should not count toward dedication bonus accumulation.
local XP_SCROLL_ITEMS = {
    [4198] = true,  -- Page from the Dragon Chronicles
    [4247] = true,  -- Page from Miratete's Memoirs
    [4248] = true,  -- Copy of Ginuva's Battle Theory (Metrics confirms 4248, not 4198)
    [4249] = true,  -- Copy of Schultz Stratagems
    [5415] = true,  -- Page from Balrahn's Reflections
}

-- cmd_no values in the 0x028 bitstream signalling item use
local ITEM_USE_START  = 9
local ITEM_USE_FINISH = 5

-- Byte offset / shift / mask isolating the first target's first result param inside the
-- 0x028 bitstream. On an item-start that param is the item id; cmd_arg holds a four-cc
-- instead, so this is the only place the id appears. Derived from the field widths in
-- XiPackets world/server/0x0028/Reversing.md.
local RESULT_PARAM_OFFSET = 0x1A
local RESULT_PARAM_SHIFT  = 5
local RESULT_PARAM_MASK   = 0x1FFFF

-- cmd_arg four-ccs distinguishing a genuine item-start from a cancelled one. A cancel
-- reuses cmd_no 9 and carries an empty result, so the four-cc is the only thing telling
-- the two apart.
local FOURCC_ITEM_USE       = 0x74696163  -- 'cait'
local FOURCC_ITEM_INTERRUPT = 0x74697073  -- 'spit'

-- cmd_arg spans stream bits 86..117: its low 26 bits sit in the dword at 0x0A, the top 6
-- in the dword at 0x0E. Assembled arithmetically so a set bit 31 stays unsigned.
local function readCmdArg(data)
    if #data < 0x12 then return nil end
    local okLo, wordLo = pcall(struct.unpack, 'I', data, 0x0A + 1)
    local okHi, wordHi = pcall(struct.unpack, 'I', data, 0x0E + 1)
    if not okLo or not okHi or not wordLo or not wordHi then return nil end
    return bit.rshift(wordLo, 6) + bit.band(wordHi, 0x3F) * 0x4000000
end

-- Zone suppression delay (seconds): don't check dedication buff for 10s after zone-in
local ZONE_DELAY = 10

-- Scroll items' server-side onItemUse is level-gated; if the check fails, onItemUse
-- (and its XP grant) never runs, so the XP message this flag waits for never arrives.
-- Without a timeout the flag stays true forever and silently cancels dedication
-- credit for whatever real kill happens next.
local SCROLL_XP_TIMEOUT = 15

-- A scroll's XP message reaches the client before its item-finish packet, never after.
-- The flag above is armed on item-start for that reason; this window backstops it by
-- undoing an accrual that the finish packet then identifies as a scroll's.
local SCROLL_REFUND_WINDOW = 3

-- HorizonXI: "Highwind" NM spawns on all 4 nation airships, grants a flat 3,000 XP /
-- 3,000 gil reward once per week for landing a single hit (even 0 damage) — not
-- chain-kill XP, must not count toward dedication. https://horizonffxi.wiki/Highwind
local EXCLUDED_XP_ZONES = {
    [223] = true, -- San d'Oria-Jeuno Airship
    [224] = true, -- Bastok-Jeuno Airship
    [225] = true, -- Windurst-Jeuno Airship
    [226] = true, -- Kazham-Jeuno Airship
}

-- [[ internal ]]
-- Write itemName/itemRate/itemMax/acquired to both state.dedication and xrSettings.dedication.
local function setDedicationFields(state, xrSettings, itemName, itemRate, itemMax, acquired)
    state.dedication.itemName = itemName
    state.dedication.itemRate = itemRate
    state.dedication.itemMax  = itemMax
    state.dedication.acquired = acquired

    xrSettings.dedication.itemName = itemName
    xrSettings.dedication.itemRate = itemRate
    xrSettings.dedication.itemMax  = itemMax
    xrSettings.dedication.acquired = acquired
end
M.setDedicationFields = setDedicationFields

-- Activate dedication from a known item.
local function activateDedication(state, xrSettings, item)
    state.dedication.active = true
    setDedicationFields(state, xrSettings, item.name, item.rate, item.max, 0)
    state.dedicationDirty = true
end

-- Deactivate dedication.
local function deactivateDedication(state, xrSettings)
    state.dedication.active        = false
    state.dedication.norm          = 1.0
    state.dedication.awaitingClear = false

    xrSettings.dedication.acquired = state.dedication.acquired
    state.dedicationDirty = true
end

-- Accumulate bonus XP. Uses Metrics' integer-per-kill formula: floor base, bonus = total - base.
-- Deactivation is handled solely by refreshDedication() when buff 249 drops.
local function accumulateDedication(state, xrSettings, xpAmount)
    local rate   = state.dedication.itemRate
    local baseXp = math.floor(xpAmount / (1 + rate / 100))
    local bonus  = xpAmount - baseXp
    state.dedication.acquired      = state.dedication.acquired + bonus
    xrSettings.dedication.acquired = state.dedication.acquired
    state.dedicationDirty = true

    state.lastAccrual.bonus = bonus
    state.lastAccrual.at    = os.time()
end

-- Undo the most recent accrual when the item-finish packet identifies it as a scroll's XP.
local function refundScrollXp(state, xrSettings)
    local last = state.lastAccrual
    if last.bonus <= 0 or (os.time() - last.at) > SCROLL_REFUND_WINDOW then return end

    state.dedication.acquired      = math.max(state.dedication.acquired - last.bonus, 0)
    xrSettings.dedication.acquired = state.dedication.acquired
    state.dedicationDirty = true
    last.bonus = 0
end

-- Called from the packet_in event for every incoming packet.
-- @param e          Ashita packet event (.id, .data)
-- @param state      shared runtime state table
-- @param xrSettings live settings table (mirrors dedication state for persistence)
function M.handleIn(e, state, xrSettings)
    if not e or not e.id then return end

    if e.id == M.ID.ZONE_OUT then
        state.isZoning = true
        return
    end

    if e.id == M.ID.ZONE_IN then
        state.isZoning = false
        state.zoneTime = os.time()
        return
    end

    if e.id == M.ID.XP_MESSAGE then
        local data = e.data
        if not data then return end

        local ok1, msgId    = pcall(struct.unpack, 'H', data, 0x18 + 1)
        local ok2, xpAmount = pcall(struct.unpack, 'I', data, 0x10 + 1)
        if not ok1 or not ok2 or not msgId or not xpAmount then return end
        if not XP_MSGS[msgId] then return end

        local scrollExcluded = state.pendingScrollXp
            and state.pendingScrollXpAt
            and (os.time() - state.pendingScrollXpAt) < SCROLL_XP_TIMEOUT
        state.pendingScrollXp = false

        -- Any earlier accrual is now too old to be a scroll's; accumulateDedication
        -- re-stamps it below if this message credits one.
        state.lastAccrual.bonus = 0

        if not state.dedication.active or state.dedication.itemRate <= 0 or scrollExcluded then
            return
        end

        local memMgr = AshitaCore and AshitaCore:GetMemoryManager()
        local party  = memMgr and memMgr:GetParty()
        local zoneId = party and party:GetMemberZone(0) or 0
        if EXCLUDED_XP_ZONES[zoneId] then return end

        accumulateDedication(state, xrSettings, xpAmount)
        return
    end

    if e.id == M.ID.ACTION then
        local data = e.data
        if not data then return end

        local ok1, actorId = pcall(struct.unpack, 'I', data, 0x05 + 1)
        local ok2, lo       = pcall(struct.unpack, 'I', data, 0x09 + 1)
        if not ok1 or not ok2 or not actorId or not lo then return end

        local cmdNo  = bit.band(bit.rshift(lo, 10), 0xF)
        local itemId = bit.rshift(lo, 14)

        if cmdNo ~= ITEM_USE_START and cmdNo ~= ITEM_USE_FINISH then return end

        local memMgr = AshitaCore and AshitaCore:GetMemoryManager()
        local party  = memMgr and memMgr:GetParty()
        local playerServerId = party and party:GetMemberServerId(0) or 0
        if actorId ~= playerServerId or playerServerId == 0 then return end

        if cmdNo == ITEM_USE_START then
            local cmdArg = readCmdArg(data)

            if cmdArg == FOURCC_ITEM_INTERRUPT then
                -- Cancelled use: the XP message the flag waits for never arrives, so clear
                -- it now instead of letting it time out onto the next real kill.
                state.pendingScrollXp = false
                return
            end

            if cmdArg ~= FOURCC_ITEM_USE then return end

            -- cmd_arg is a four-cc here; the id lives in the first result's param.
            if #data < RESULT_PARAM_OFFSET + 4 then return end
            local ok3, word = pcall(struct.unpack, 'I', data, RESULT_PARAM_OFFSET + 1)
            if not ok3 or not word then return end
            itemId = bit.band(bit.rshift(word, RESULT_PARAM_SHIFT), RESULT_PARAM_MASK)
        end

        if XP_SCROLL_ITEMS[itemId] then
            -- Arm on start only. Re-arming on finish would leave the flag live for the
            -- next real kill, since the scroll's own XP has already consumed it by then.
            if cmdNo == ITEM_USE_START then
                state.pendingScrollXp   = true
                state.pendingScrollXpAt = os.time()
            else
                refundScrollXp(state, xrSettings)
            end
        elseif cmdNo == ITEM_USE_FINISH then
            local item = dedicationItems[itemId]
            if item then
                state.pendingDedicationItem = item
            end
        end
        return
    end
end

-- Poll the dedication buff to detect expiry/removal, or auto-activate when
-- the buff is present but the activation packet was missed (e.g. addon loaded
-- after the item was used). Auto-activation requires defaultingEnabled=true.
-- Called every throttle tick from xpReborn.lua.
-- @param state      shared runtime state table
-- @param xrSettings live settings table
function M.refreshDedication(state, xrSettings)
    if state.isZoning then return end
    if state.zoneTime and (os.time() - state.zoneTime) < ZONE_DELAY then return end

    local memMgr = AshitaCore and AshitaCore:GetMemoryManager()
    local player = memMgr and memMgr:GetPlayer()
    if not player then return end

    local buffs = player:GetBuffs()
    if not buffs then return end

    local present = false
    for i = 0, 31 do
        local id = buffs[i]
        if id == -1 then break end
        if id == BUFF_DEDICATION then
            present = true
            break
        end
    end

    if state.dedication.active then
        if present then
            state.dedication.awaitingClear = true
        elseif state.dedication.awaitingClear then
            deactivateDedication(state, xrSettings)
        end
    elseif present then
        -- Re-activate from saved item data if a previous activation is on record.
        -- deactivateDedication() preserves itemName/itemRate/itemMax/acquired in settings,
        -- so we can restore without resetting the accumulated XP budget.
        local hasKnownItem = xrSettings.dedication.itemName ~= '' and xrSettings.dedication.itemMax > 0
        if state.pendingDedicationItem then
            activateDedication(state, xrSettings, state.pendingDedicationItem)
            state.pendingDedicationItem = nil
        elseif hasKnownItem then
            state.dedication.active = true
            setDedicationFields(state, xrSettings, xrSettings.dedication.itemName, xrSettings.dedication.itemRate, xrSettings.dedication.itemMax, xrSettings.dedication.acquired)
        elseif xrSettings.dedication.defaultingEnabled then
            local id   = xrSettings.dedication.defaultItemId
            local item = id and dedicationItems[id]
            if item then
                activateDedication(state, xrSettings, item)
            end
        end
    end
end

return M
