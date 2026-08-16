-- state.lua
-- Shared runtime state. Written by xpReborn.lua (API poll) and packets.lua (gain events).
-- Read by xpFrame.lua via update(state, settings).

local State = {
    -- XP mode: 'xp' or 'lp'
    mode        = 'xp',

    -- XP mode values (mode == 'xp')
    xpCurrent   = 0,
    xpNeeded    = 1,       -- never 0; guarded against div-by-zero
    xpNorm      = 0.0,     -- xpCurrent / xpNeeded, clamped 0..1

    -- LP mode values (mode == 'lp')
    lpCurrent   = 0,
    lpMax       = 10000,
    lpNorm      = 0.0,     -- lpCurrent / lpMax, clamped 0..1
    meritCount  = 0,
    meritMax    = 0,

    -- Pre-built display strings (built once per throttle tick, read every frame by renderer)
    txtJob      = '',      -- e.g. 'NIN 75'
    txtNumbers  = '',      -- e.g. '1234 / 8000' or '8500 / 10000  |  14 Merits'
    txtPercent  = '',      -- e.g. '15.4%'
    txtDedit    = '',      -- e.g. 'Emperor Band — 1000 / 2250'

    -- Dedication tracking
    dedication  = {
        active      = false,
        itemName    = '',
        itemRate    = -1,
        itemMax     = -1,
        acquired    = 0,
        norm        = 1.0,  -- (max - acquired) / max; starts 1.0, drains toward 0
        -- Two-phase deactivation latch set by packets.lua's refreshDedication: must observe
        -- buff 249 present at least once while active before its absence is trusted.
        awaitingClear = false,
    },

    -- Zone suppression: set true on 0x00B, cleared on 0x00A
    isZoning    = false,

    -- Set true by packets.lua whenever a dedication field changes on disk;
    -- consumed (and cleared) by xpReborn.lua's throttle-tick save.
    dedicationDirty = false,

    -- Set by packets.lua when an XP-scroll item's follow-up XP message should be
    -- excluded from dedication accumulation.
    pendingScrollXp = false,

    -- Most recent bonus credited to the dedication budget, with the os.time() it was
    -- credited at. Read by packets.lua's scroll refund; zeroed once refunded or once an
    -- XP message is excluded on its own.
    lastAccrual = { bonus = 0, at = 0 },

    -- NOTE: state.pendingDedicationItem, state.zoneTime, and state.pendingScrollXpAt
    -- are also part of this module's runtime shape but have no meaningful non-nil
    -- default (a Lua table constructor silently drops any `= nil` entry, so they
    -- cannot be declared as real keys here). All three are created dynamically by
    -- packets.lua and are absent (nil) until first set: pendingDedicationItem on
    -- item-use, consumed by the next buff-poll tick; zoneTime on zone-in, used to
    -- gate the post-zone buff-poll delay; pendingScrollXpAt is the companion
    -- timestamp for pendingScrollXp's timeout, set alongside it on scroll-use.
    -- It is not itself nil'd when pendingScrollXp is consumed or expires (only
    -- the flag is) — safe because it's never read except when pendingScrollXp
    -- is true, and gets overwritten on the next scroll-use.
}

-- Rebuild display strings and bar norms from Ashita player memory.
-- Called by xpReborn.lua on the throttle tick (every 30 frames).
-- player: result of AshitaCore:GetMemoryManager():GetPlayer()
-- settings: the live settings table (reads display.show* flags)
function State.refresh(player, xrSettings)
    if not player then return end

    local mainJob  = player:GetMainJob()
    if mainJob == 0 then return end

    local jobLevel  = player:GetMainJobLevel()
    local resMgr    = AshitaCore:GetResourceManager()
    local jobAbbr   = resMgr:GetString('jobs.names_abbr', mainJob) or '---'

    local subJob    = player:GetSubJob()
    local subLevel  = player:GetSubJobLevel()
    local subAbbr   = (subJob and subJob > 0) and (resMgr:GetString('jobs.names_abbr', subJob) or '---') or nil

    -- Always build job string (visibility controlled by renderer)
    if subAbbr and subLevel and subLevel > 0 then
        State.txtJob = string.format('%s%d/%s%d', jobAbbr, jobLevel, subAbbr, subLevel)
    else
        State.txtJob = string.format('%s%d', jobAbbr, jobLevel)
    end

    -- Mode: LP when limit mode is active OR XP is capped at 75 (1 TNL = at cap, overflow goes to LP)
    local limitMode  = player:GetIsLimitModeEnabled()
    local rawCurrent = player:GetExpCurrent()
    local rawNeeded  = player:GetExpNeeded()
    State.mode = (jobLevel >= 75 and (limitMode or (rawNeeded - rawCurrent) <= 1)) and 'lp' or 'xp'

    if State.mode == 'lp' then
        State.lpCurrent  = player:GetLimitPoints()
        State.lpNorm     = math.min(State.lpCurrent / State.lpMax, 1.0)
        State.meritCount = player:GetMeritPoints()
        State.meritMax   = player:GetMeritPointsMax()
        State.txtNumbers = string.format('%d / 10000  |  %d Merits', State.lpCurrent, State.meritCount)
        State.txtPercent = string.format('%.1f%%', State.lpNorm * 100)
    else
        State.xpCurrent  = player:GetExpCurrent()
        State.xpNeeded   = math.max(player:GetExpNeeded(), 1)
        State.xpNorm     = math.min(State.xpCurrent / State.xpNeeded, 1.0)
        State.txtNumbers = string.format('%d / %d', State.xpCurrent, State.xpNeeded)
        State.txtPercent = string.format('%.1f%%', State.xpNorm * 100)
    end

    -- Dedication norm and text
    local ded = State.dedication
    if ded.active and ded.itemMax > 0 then
        ded.norm = math.max((ded.itemMax - ded.acquired) / ded.itemMax, 0.0)
        local overflow = xrSettings and xrSettings.dedication and xrSettings.dedication.overflowEnabled
        local acquired = math.floor(ded.acquired)
        local firstNum = overflow and acquired or math.min(acquired, ded.itemMax)
        State.txtDedit = string.format('%s: %d / %d', ded.itemName, firstNum, ded.itemMax)
    elseif ded.active then
        ded.norm      = 1.0
        State.txtDedit = 'Dedication active'
    else
        ded.norm      = 1.0
        State.txtDedit = ''
    end
end

return State
