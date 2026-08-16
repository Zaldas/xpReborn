-- xpReborn.lua
-- Persistent XP / LP bar overlay with dedication item tracking.
-- Wires together state, packet handlers, the spui render frame, and the
-- ImGui config window. Toggle the config window with /xr.

addon.name    = 'xpReborn'
addon.author  = 'Zaldas'
addon.version = '1.0'
addon.desc    = 'XP / LP bar overlay with dedication item tracking'
addon.link    = 'https://github.com/Zaldas/xpReborn'

require('common')
local chat            = require('chat')
local settings        = require('settings')
local State           = require('state')
local packets         = require('packets')
local dedicationItems = require('data/dedicationItems')
local xpFrame         = require('elements/xpFrame')
local configWindow    = require('elements/configWindow')

-- Chariot Band; matches dedicationItems.ordered[1]. Shared by defaultSettings and the
-- defaultItemIndex -> defaultItemId migration's out-of-range fallback.
local DEFAULT_DEDICATION_ITEM_ID = 15761

-- Sample dedication data shown in the spui bar while the config window is open and no
-- real dedication is active. Built once here rather than allocated fresh every frame;
-- xpFrame.update() reads it read-only, so it's safe to share across frames. txtDedit
-- intentionally omits a percent suffix -- state.lua's State.refresh builds the real
-- dedication text via string.format('%s: %d / %d', ...) with no percent, so this must
-- match that format exactly.
local DEDICATION_PREVIEW = {
    dedication = {
        active   = true,
        itemName = 'Emperor Band',
        itemRate = 75,
        itemMax  = 2250,
        acquired = 1000,
        norm     = (2250 - 1000) / 2250,
    },
    txtDedit = 'Emperor Band: 1000 / 2250',
}

local defaultSettings = T{
    anchor       = T{ x = 800, y = 900 },
    lockPosition = false,
    display = T{
        showJobLevel   = true,
        showNumbers    = true,
        showPercent    = true,
        showDedication = true,
    },
    dedication = T{
        defaultingEnabled = false,
        defaultItemId     = DEFAULT_DEDICATION_ITEM_ID,
        overflowEnabled   = false,
        itemName = '',
        itemRate = -1,
        itemMax  = -1,
        acquired = 0,
    },
}

local xrSettings = defaultSettings   -- initialized in load event
local frameCount = 0
local THROTTLE   = 30

-- Game state detection
local pEventSystem     = ashita.memory.find('FFXiMain.dll', 0, 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0)
local pInterfaceHidden = ashita.memory.find('FFXiMain.dll', 0, '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0)

-- Zone suppression: start true so the frame stays hidden until the player entity
-- confirms login. Cleared in should_hide() once GetMemberTargetIndex(0) is non-zero.
local frameZoneSuppressed = true
local zoneInReceived      = true   -- treat initial load as having already "arrived"

local function isGameInterfaceHidden()
    if pEventSystem ~= 0 then
        local ptr = ashita.memory.read_uint32(pEventSystem + 1)
        if ptr ~= 0 and ashita.memory.read_uint8(ptr) == 1 then return true end
    end
    if pInterfaceHidden ~= 0 then
        local ptr = ashita.memory.read_uint32(pInterfaceHidden + 10)
        if ptr ~= 0 and ashita.memory.read_uint8(ptr + 0xB4) == 1 then return true end
    end
    return false
end

-- Returns true when the bar should be hidden: between zone packets, on title screen,
-- or during cutscenes / NPC dialogue / world map.
local function should_hide()
    if frameZoneSuppressed then
        if not zoneInReceived then return true end
        -- Wait for the player entity to actually spawn in the new zone.
        local pty = AshitaCore:GetMemoryManager():GetParty()
        if not pty or (pty:GetMemberTargetIndex(0) or 0) == 0 then return true end
        frameZoneSuppressed = false
    end
    return isGameInterfaceHidden()
end

local function loadLayout()
    local fn, loadErr = loadfile(addon.path .. 'layouts/default.lua')
    if not fn then
        print(chat.header(addon.name) .. chat.error('Failed to load layout: ' .. tostring(loadErr)))
        return {}
    end

    local ok, result = pcall(fn)
    if not ok then
        print(chat.header(addon.name) .. chat.error('Layout script error: ' .. tostring(result)))
        return {}
    end

    if type(result) ~= 'table' then
        print(chat.header(addon.name) .. chat.error('Layout script did not return a table.'))
        return {}
    end

    return result
end

local function resetDedicationState()
    State.dedication.active         = false
    State.dedication.itemName       = ''
    State.dedication.itemRate       = -1
    State.dedication.itemMax        = -1
    State.dedication.acquired       = 0
    State.dedication.norm           = 1.0
    State.dedication.awaitingClear  = false
    State.pendingDedicationItem     = nil
    State.pendingScrollXp           = false
    State.pendingScrollXpAt         = nil
    State.lastAccrual.bonus         = 0
    State.lastAccrual.at            = 0
    State.dedicationDirty           = false
end

local function resetDedication()
    resetDedicationState()
    packets.setDedicationFields(State, xrSettings, '', -1, -1, 0)
    settings.save()
end

local function buildCallbacks()
    return {
        onShowJobLevel   = function(v) xrSettings.display.showJobLevel   = v; settings.save() end,
        onShowNumbers    = function(v) xrSettings.display.showNumbers    = v; settings.save() end,
        onShowPercent    = function(v) xrSettings.display.showPercent    = v; settings.save() end,
        onShowDedication = function(v) xrSettings.display.showDedication = v; settings.save() end,
        onDefaultingEnabled = function(v)
            xrSettings.dedication.defaultingEnabled = v
            settings.save()
        end,
        onOverflowEnabled = function(v)
            xrSettings.dedication.overflowEnabled = v
            settings.save()
        end,
        onDefaultItemId = function(id)
            xrSettings.dedication.defaultItemId = id
            settings.save()
        end,
        onResetDedication = function()
            resetDedication()
            print(chat.header(addon.name) .. chat.message('Dedication reset.'))
        end,
        onLockPosition = function(v)
            xrSettings.lockPosition = v
            settings.save()
        end,
        onResetAnchor = function()
            xrSettings.anchor.x = 100
            xrSettings.anchor.y = 100
            xpFrame.setAnchor(100, 100)
            settings.save()
            print(chat.header(addon.name) .. chat.message('Position reset to (100, 100).'))
        end,
    }
end
local callbacks = buildCallbacks()

-- One-time migration: pre-MED-3 settings files store defaultItemIndex (an ordered-list
-- position); resolve it to the equivalent defaultItemId and drop the legacy field.
-- settings.load()'s merge backfills defaultItemId from defaultSettings for old files
-- (missing keys are deep-filled from defaults), so the presence of defaultItemIndex --
-- not the current defaultItemId value, which is always already valid post-merge -- is
-- the only reliable signal that this file predates the defaultItemId field.
-- Must be called on every settings table that gets assigned to xrSettings, not just the
-- initial load: xpReborn is boot-loaded (scripts/default.txt), so the 'load' handler's
-- first settings.load() runs before character login and resolves against the shared
-- defaults-folder file (settingslib.logged_in is still false at that point). The actual
-- per-character file only surfaces later via the xpreborn_settings_update callback below,
-- fired when packet 0x000A drives settings.lua's process_character_switch -- so this must
-- also run there, and in the /xr reload command handler for full self-healing.
local function migrateDedicationSettings(s)
    if s.dedication.defaultItemIndex ~= nil then
        local entry = dedicationItems.ordered[s.dedication.defaultItemIndex]
        s.dedication.defaultItemId = entry and entry.id or DEFAULT_DEDICATION_ITEM_ID
        s.dedication.defaultItemIndex = nil
        -- MED-4 dropped the persisted `active` flag the same phase this field was
        -- renamed; every file old enough to still have defaultItemIndex also still
        -- has this orphaned key. Strip it now rather than carrying it forever.
        s.dedication.active = nil
        settings.save()
    end
end

ashita.events.register('load', 'xpreborn_load_cb', function()
    xrSettings = settings.load(defaultSettings)
    migrateDedicationSettings(xrSettings)

    -- state.dedication.active must start false on load/settings reload; it can only
    -- be set true by packets.refreshDedication()'s buff-presence-verified paths
    -- (activateDedication on item-use, or the hasKnownItem branch once buff 249 is
    -- observed) -- never restored directly from a persisted flag, since that flag
    -- can be stale.

    local layout = loadLayout()
    xpFrame.initialize(layout, xrSettings.anchor.x, xrSettings.anchor.y)
    configWindow.initialize()

    settings.register('settings', 'xpreborn_settings_update', function(s)
        if s then
            migrateDedicationSettings(s)
            resetDedicationState()
            xrSettings = s
            local L = loadLayout()
            xpFrame.destroy()
            xpFrame.initialize(L, xrSettings.anchor.x, xrSettings.anchor.y)
        end
    end)

    print(chat.header(addon.name) .. chat.message('Loaded. /xr to configure.'))
end)

ashita.events.register('unload', 'xpreborn_unload_cb', function()
    configWindow.destroy()
    xpFrame.destroy()
    settings.save()
end)

ashita.events.register('d3d_present', 'xpreborn_present_cb', function()
    -- Config window draws regardless of bar visibility (player may open it any time).
    configWindow.draw(xrSettings, State, callbacks)

    -- Suppress bar while on title screen, zoning, or during cutscenes.
    local hide = should_hide()
    xpFrame.setFrameVisible(not hide)
    if hide then return end

    -- Throttled data refresh
    frameCount = (frameCount + 1) % THROTTLE
    if frameCount == 0 then
        local memMgr = AshitaCore:GetMemoryManager()
        local player = memMgr and memMgr:GetPlayer()
        State.refresh(player, xrSettings)

        packets.refreshDedication(State, xrSettings)

        -- Persist dedication state only when this refresh actually mutated it.
        if State.dedicationDirty then
            settings.save()
            State.dedicationDirty = false
        end
    end

    -- Persist anchor if user dragged the bar
    local newAnch = xpFrame.getAnchor()
    if newAnch then
        xrSettings.anchor.x = newAnch.x
        xrSettings.anchor.y = newAnch.y
        settings.save()
    end

    -- While config is open and no real dedication is active, pass sample preview data
    -- into xpFrame.update() so the spui bar shows a sample alongside the config window.
    -- State itself is never mutated for this -- xpFrame.update() reads the preview
    -- table directly when provided.
    local showPreview = configWindow.isOpen() and not State.dedication.active
    xpFrame.update(State, xrSettings, showPreview and DEDICATION_PREVIEW or nil)
end)

ashita.events.register('packet_in', 'xpreborn_packet_in_cb', function(e)
    if e.id == packets.ID.ZONE_OUT then
        -- Zone-out: suppress unconditionally until zone-in + entity spawn confirmed.
        frameZoneSuppressed = true
        zoneInReceived      = false
        xpFrame.setFrameVisible(false)
    elseif e.id == packets.ID.ZONE_IN then
        -- Zone-in arrived; d3d_present will clear frameZoneSuppressed once entity spawns.
        frameZoneSuppressed = true
        zoneInReceived      = true
    end

    packets.handleIn(e, State, xrSettings)
end)

ashita.events.register('mouse', 'xpreborn_mouse_cb', function(e)
    if xrSettings.lockPosition then return end
    xpFrame.handleMouse(e)
end)

ashita.events.register('command', 'xpreborn_command_cb', function(e)
    local args = e.command:args()
    if #args == 0 or (args[1] ~= '/xpreborn' and args[1] ~= '/xr') then return end
    e.blocked = true

    local cmd = args[2] and args[2]:lower() or ''

    if cmd == '' then
        configWindow.toggle()
    elseif cmd == 'reset' then
        resetDedication()
        print(chat.header(addon.name) .. chat.message('Dedication reset.'))
    elseif cmd == 'reload' then
        resetDedicationState()
        xrSettings = settings.load(defaultSettings)
        migrateDedicationSettings(xrSettings)
        local L = loadLayout()
        xpFrame.destroy()
        xpFrame.initialize(L, xrSettings.anchor.x, xrSettings.anchor.y)
        print(chat.header(addon.name) .. chat.message('Reloaded.'))
    elseif cmd == 'help' then
        print(chat.header(addon.name) .. chat.message('/xr               Toggle config window'))
        print(chat.header(addon.name) .. chat.message('/xr reset         Clear dedication session'))
        print(chat.header(addon.name) .. chat.message('/xr reload        Reload settings and layout'))
    else
        print(chat.header(addon.name) .. chat.warning(string.format('Unknown command: %s. Use /xr help.', cmd)))
    end
end)
