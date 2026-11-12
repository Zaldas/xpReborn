-- packets.lua
-- Packet handlers and buff poll for xpReborn; the only writer of dedication state and
-- its persisted settings subset. No UI side effects.
-- Called from xpReborn.lua event handlers.

local dedicationItems = require('data/dedicationItems')

local M = {}

-- Packet IDs
M.ID = {
    XP_MESSAGE     = 0x002D,
    BATTLE_MESSAGE = 0x0029,
    ACTION         = 0x0028,
    ZONE_IN        = 0x000A,
    ZONE_OUT       = 0x000B,
}

-- XP/LP message IDs (packet 0x02D)
local XP_MSGS = { [8] = true, [253] = true, [371] = true, [372] = true }

-- EXP/limit chain messages: only kills extend a chain.
local CHAIN_MSGS = { [253] = true, [372] = true }

-- Battle messages (packet 0x029) announcing a mob's death: "defeats" and "falls to the ground".
local DEFEAT_MSGS = { [6] = true, [20] = true }

-- Target indexes 0x400-0x6FF are players. Mobs and NPCs sit below; dynamic entities,
-- pets and trusts sit above.
local PLAYER_INDEX_MIN = 0x400
local PLAYER_INDEX_MAX = 0x6FF

-- Non-kill XP carries no ring bonus, and the XP packet does not say its source: an
-- unchained XP message counts only if a mob defeat arrived within this many seconds.
-- The defeat message reaches players within 50 yalms of the mob; XP reaches party
-- members within 100, so a member between the two loses that kill's credit.
local DEFEAT_WINDOW = 5

-- Buff ID for dedication effect
local BUFF_DEDICATION = 249

-- An item-use whose buff has not been seen in a buff poll this many seconds later is
-- dropped, so it is never applied to an unrelated later buff.
local PENDING_ITEM_WINDOW = 15

-- Items that grant XP directly on use (not dedication multipliers).
-- XP from these should not count toward dedication bonus accumulation.
local XP_SCROLL_ITEMS = {
    [4198] = true,  -- Page from the Dragon Chronicles
    [4247] = true,  -- Page from Miratete's Memoirs
    [4248] = true,  -- Copy of Ginuva's Battle Theory
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

local function setItem(state, itemName, itemRate, itemMax, acquired)
    local ded = state.dedication
    ded.itemName = itemName
    ded.itemRate = itemRate
    ded.itemMax  = itemMax
    ded.acquired = acquired
end

local function clearItem(state)
    setItem(state, '', -1, -1, 0)
end

-- Copy the persisted subset of state.dedication into xrSettings.dedication.
local function persist(state, xrSettings)
    local ded   = state.dedication
    local saved = xrSettings.dedication
    saved.itemName = ded.itemName
    saved.itemRate = ded.itemRate
    saved.itemMax  = ded.itemMax
    saved.acquired = ded.acquired
end

-- Clear all dedication state and its packet bookkeeping. With xrSettings, the persisted
-- item is cleared too; without it, saved settings are left untouched.
function M.resetDedication(state, xrSettings)
    local ded = state.dedication
    ded.active        = false
    clearItem(state)
    ded.norm          = 1.0
    ded.awaitingClear = false

    state.pendingDedicationItem = false
    state.pendingDedicationAt   = 0
    state.pendingScrollXp       = false
    state.pendingScrollXpAt     = 0
    state.lastAccrual.bonus     = 0
    state.lastAccrual.at        = 0
    state.lastDefeatAt          = 0
    state.defeatBonus           = 0
    state.dedicationDirty       = false

    if xrSettings then
        persist(state, xrSettings)
    end
end

-- Activate dedication from a known item.
local function activateDedication(state, xrSettings, item)
    state.dedication.active = true
    setItem(state, item.name, item.rate, item.max, 0)
    state.defeatBonus = 0
    persist(state, xrSettings)
    state.dedicationDirty = true
end

-- Deactivate dedication on an observed buff drop. The item is forgotten so a later buff
-- without a seen item-use does not resume it.
local function deactivateDedication(state, xrSettings)
    local ded = state.dedication
    ded.active        = false
    ded.norm          = 1.0
    ded.awaitingClear = false

    clearItem(state)
    persist(state, xrSettings)
    state.dedicationDirty = true
end

-- Ring bonus within an XP total. The server grants base + floor(base * rate / 100),
-- capped at the remaining budget; rate is an integer percent.
local function bonusFromTotal(total, rate, remaining)
    local function grant(b)
        return b + math.floor(b * rate / 100)
    end
    local base = math.floor(total * 100 / (100 + rate))
    while base > 0 and grant(base) > total do
        base = base - 1
    end
    while grant(base + 1) <= total do
        base = base + 1
    end
    -- No exact base when another multiplier also applied: take the nearest.
    if grant(base) ~= total and (grant(base + 1) - total) < (total - grant(base)) then
        base = base + 1
    end
    return math.min(math.max(total - base, 0), math.max(remaining, 0))
end

-- Deactivation is handled solely by refreshDedication() when buff 249 drops.
local function accumulateDedication(state, xrSettings, xpAmount)
    local ded   = state.dedication
    -- With overflow on, the bonus is not capped so a server budget larger than the table's shows.
    local remaining = xrSettings.dedication.overflowEnabled and math.huge or (ded.itemMax - ded.acquired)
    local bonus = bonusFromTotal(xpAmount, ded.itemRate, remaining)
    ded.acquired = ded.acquired + bonus
    persist(state, xrSettings)
    state.dedicationDirty = true

    state.lastAccrual.bonus = bonus
    state.lastAccrual.at    = os.time()
    return bonus
end

-- Undo the unchained accrual already credited for the current defeat.
local function refundDefeatBonus(state, xrSettings)
    if state.defeatBonus <= 0 then return end
    state.dedication.acquired = math.max(state.dedication.acquired - state.defeatBonus, 0)
    persist(state, xrSettings)
    state.dedicationDirty = true
    state.defeatBonus = 0
end

-- Undo the most recent accrual when the item-finish packet identifies it as a scroll's XP.
local function refundScrollXp(state, xrSettings)
    local last = state.lastAccrual
    if last.bonus <= 0 or (os.time() - last.at) > SCROLL_REFUND_WINDOW then return end

    state.dedication.acquired = math.max(state.dedication.acquired - last.bonus, 0)
    persist(state, xrSettings)
    state.dedicationDirty = true
    last.bonus = 0
end

-- Called from the packet_in event for every incoming packet.
-- @param e          Ashita packet event (.id, .data)
-- @param state      shared runtime state table
-- @param xrSettings live settings table (holds the persisted dedication subset)
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

    if e.id == M.ID.BATTLE_MESSAGE then
        local data = e.data
        if not data then return end

        local ok1, targetIndex = pcall(struct.unpack, 'H', data, 0x16 + 1)
        local ok2, msgId       = pcall(struct.unpack, 'H', data, 0x18 + 1)
        if not ok1 or not ok2 or not targetIndex or not msgId then return end

        local isPlayer = targetIndex >= PLAYER_INDEX_MIN and targetIndex <= PLAYER_INDEX_MAX
        if DEFEAT_MSGS[msgId] and targetIndex > 0 and not isPlayer then
            state.lastDefeatAt = os.time()
            state.defeatBonus  = 0
        end
        return
    end

    if e.id == M.ID.XP_MESSAGE then
        local data = e.data
        if not data then return end

        local ok1, msgId    = pcall(struct.unpack, 'H', data, 0x18 + 1)
        local ok2, xpAmount = pcall(struct.unpack, 'I', data, 0x10 + 1)
        if not ok1 or not ok2 or not msgId or not xpAmount then return end
        if not XP_MSGS[msgId] then return end

        local now = os.time()
        local scrollExcluded = state.pendingScrollXp
            and (now - state.pendingScrollXpAt) < SCROLL_XP_TIMEOUT
        state.pendingScrollXp = false

        -- Any earlier accrual is now too old to be a scroll's; accumulateDedication
        -- re-stamps it below if this message credits one.
        state.lastAccrual.bonus = 0

        if not state.dedication.active or state.dedication.itemRate <= 0 or scrollExcluded then
            return
        end

        local isChain   = CHAIN_MSGS[msgId]
        local afterKill = (now - state.lastDefeatAt) <= DEFEAT_WINDOW
        if not isChain and not afterKill then return end

        local memMgr = AshitaCore and AshitaCore:GetMemoryManager()
        local party  = memMgr and memMgr:GetParty()
        local zoneId = party and party:GetMemberZone(0) or 0
        if EXCLUDED_XP_ZONES[zoneId] then return end

        -- A death handler's script XP (e.g. a regime page reward) is sent before the kill
        -- XP, so a defeat credits only its last XP message: a later one replaces an earlier
        -- credit. A chain message is the kill XP and closes the defeat.
        if afterKill then
            refundDefeatBonus(state, xrSettings)
        end
        local bonus = accumulateDedication(state, xrSettings, xpAmount)
        if isChain then
            state.lastDefeatAt = 0
        else
            state.defeatBonus = bonus
        end
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
                -- Cancelled use: no XP message follows, so a live flag would land on the next kill.
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
            -- Armed on start only: the scroll's XP arrives before its finish packet, so a
            -- flag armed on finish would exclude the next kill instead.
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
                state.pendingDedicationAt   = os.time()
            end
        end
        return
    end
end

-- Poll the dedication buff to detect expiry/removal, or auto-activate when
-- the buff is present but the activation packet was missed (e.g. addon loaded
-- after the item was used). Auto-activation requires defaultingEnabled=true.
-- Called every throttle tick from xpReborn.lua, including while the bar is hidden.
-- @param state      shared runtime state table
-- @param xrSettings live settings table
function M.refreshDedication(state, xrSettings)
    if state.isZoning then return end
    if (os.time() - state.zoneTime) < ZONE_DELAY then return end

    local memMgr = AshitaCore and AshitaCore:GetMemoryManager()
    local player = memMgr and memMgr:GetPlayer()
    local party  = memMgr and memMgr:GetParty()
    if not player or not party then return end

    -- The buff list is not trustworthy until the player entity has spawned.
    if (party:GetMemberTargetIndex(0) or 0) == 0 then return end

    local buffs = player:GetBuffs()
    if not buffs then return end

    local present = false
    for i = 1, 32 do
        local id = buffs[i]
        if id == -1 then break end
        if id == BUFF_DEDICATION then
            present = true
            break
        end
    end

    local pending = state.pendingDedicationItem
    if pending and not present and (os.time() - state.pendingDedicationAt) > PENDING_ITEM_WINDOW then
        state.pendingDedicationItem = false
        pending = false
    end

    if state.dedication.active then
        if present and pending then
            -- Item used after the last activation: the buff dropped and was reapplied between polls.
            activateDedication(state, xrSettings, pending)
            state.pendingDedicationItem = false
        elseif present then
            state.dedication.awaitingClear = true
        elseif state.dedication.awaitingClear then
            deactivateDedication(state, xrSettings)
        end
    elseif present then
        -- Settings keep the item across reloads and relogs, where no buff drop is observed,
        -- so it resumes its saved budget.
        local saved = xrSettings.dedication
        local hasKnownItem = saved.itemName ~= '' and saved.itemMax > 0
        if pending then
            activateDedication(state, xrSettings, pending)
            state.pendingDedicationItem = false
        elseif hasKnownItem then
            state.dedication.active = true
            setItem(state, saved.itemName, saved.itemRate, saved.itemMax, saved.acquired)
        elseif saved.defaultingEnabled then
            local id   = saved.defaultItemId
            local item = id and dedicationItems[id]
            if item then
                activateDedication(state, xrSettings, item)
            end
        end
    end
end

return M
