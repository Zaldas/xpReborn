-- xpReborn.lua
-- Persistent XP / LP bar overlay with dedication item tracking.
-- Wires together state, packet handlers, the spui render frame, and the
-- ImGui config window. Toggle the config window with /xr.

addon.name    = 'xpReborn'
addon.author  = 'Zaldas'
addon.version = '1.2'
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
local sprites         = require('libs/spui/sprites')

-- Chariot Band; matches dedicationItems.ordered[1]. Default item and the fallback
-- for an out-of-range legacy defaultItemIndex.
local DEFAULT_DEDICATION_ITEM_ID = 15761

-- Screen position "Reset position" moves the bar to.
local RESET_ANCHOR = { x = 100, y = 100 }

-- Sample dedication data shown in the spui bar while the config window is open and no
-- real dedication is active. Read-only.
local DEDICATION_PREVIEW = {
    dedication = {
        active   = true,
        itemName = 'Emperor Band',
        itemRate = 75,
        itemMax  = 2250,
        acquired = 1000,
        norm     = (2250 - 1000) / 2250,
    },
    txtDedit = State.formatDedication('Emperor Band', 1000, 2250, false),
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
local frameCount = 0       -- 0 runs the throttled tick on the next frame
local THROTTLE   = 30

-- Game state detection
local pEventSystem     = ashita.memory.find('FFXiMain.dll', 0, 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0)
local pInterfaceHidden = ashita.memory.find('FFXiMain.dll', 0, '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0)

-- Zone suppression: start true so the frame stays hidden until the player entity
-- confirms login. Cleared in shouldHide() once zone-in has arrived (State.isZoning false)
-- and GetMemberTargetIndex(0) is non-zero.
local frameZoneSuppressed = true

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
local function shouldHide()
    if frameZoneSuppressed then
        if State.isZoning then return true end
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
        return nil
    end

    local ok, result = pcall(fn)
    if not ok then
        print(chat.header(addon.name) .. chat.error('Layout script error: ' .. tostring(result)))
        return nil
    end

    if type(result) ~= 'table' then
        print(chat.header(addon.name) .. chat.error('Layout script did not return a table.'))
        return nil
    end

    local valid, validErr = xpFrame.validateLayout(result)
    if not valid then
        print(chat.header(addon.name) .. chat.error(validErr))
        return nil
    end

    return result
end

local function resetDedication()
    packets.resetDedication(State, xrSettings)
    settings.save()
end

local function buildCallbacks()
    return {
        resetAnchor      = RESET_ANCHOR,
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
            xrSettings.anchor.x = RESET_ANCHOR.x
            xrSettings.anchor.y = RESET_ANCHOR.y
            xpFrame.setAnchor(RESET_ANCHOR.x, RESET_ANCHOR.y)
            settings.save()
            print(chat.header(addon.name) .. chat.message(string.format('Position reset to (%d, %d).', RESET_ANCHOR.x, RESET_ANCHOR.y)))
        end,
    }
end
local callbacks = buildCallbacks()

-- Settings files from pre-release builds store defaultItemIndex (an ordered-list position)
-- and an orphaned dedication.active key. The settings merge always backfills defaultItemId,
-- so the presence of defaultItemIndex is the only signal of such a file.
-- Must run on every table assigned to xrSettings: the addon loads before login, so the
-- per-character file arrives later through the settings callback.
local function migrateDedicationSettings(s)
    if s.dedication.defaultItemIndex ~= nil then
        local entry = dedicationItems.ordered[s.dedication.defaultItemIndex]
        s.dedication.defaultItemId = entry and entry.id or DEFAULT_DEDICATION_ITEM_ID
        s.dedication.defaultItemIndex = nil
        s.dedication.active = nil
        settings.save()
    end
end

-- Adopts a settings table and rebuilds the frame. State.dedication.active starts false;
-- only packets.refreshDedication sets it, once buff 249 is observed.
-- A layout that fails to load keeps the existing frame, or leaves it unbuilt if none exists.
-- A layout that fails while building leaves the frame unbuilt.
local function applySettings(s)
    migrateDedicationSettings(s)
    packets.resetDedication(State)
    xrSettings = s
    local layout = loadLayout()
    if layout then
        xpFrame.destroy()
        local ok, initErr = pcall(xpFrame.initialize, layout, xrSettings.anchor.x, xrSettings.anchor.y)
        if not ok then
            print(chat.header(addon.name) .. chat.error('Layout error: ' .. tostring(initErr)))
            xpFrame.destroy()
        end
    else
        xpFrame.setAnchor(xrSettings.anchor.x, xrSettings.anchor.y)
    end
end

ashita.events.register('load', 'xpreborn_load_cb', function()
    applySettings(settings.load(defaultSettings))
    configWindow.initialize()

    settings.register('settings', 'xpreborn_settings_update', function(s)
        if s then
            applySettings(s)
        end
    end)

    print(chat.header(addon.name) .. chat.message('Loaded. /xr to configure.'))
end)

ashita.events.register('unload', 'xpreborn_unload_cb', function()
    ashita.events.unregister('load', 'xpreborn_load_cb')
    ashita.events.unregister('d3d_present', 'xpreborn_present_cb')
    ashita.events.unregister('packet_in', 'xpreborn_packet_in_cb')
    ashita.events.unregister('mouse', 'xpreborn_mouse_cb')
    ashita.events.unregister('command', 'xpreborn_command_cb')
    settings.unregister('settings', 'xpreborn_settings_update')
    local pendingAnchor = xpFrame.getAnchor()
    if pendingAnchor then
        xrSettings.anchor.x = pendingAnchor.x
        xrSettings.anchor.y = pendingAnchor.y
    end
    settings.save()
    configWindow.destroy()
    xpFrame.destroy()
    -- Unload only: gdifonts keeps its freed interface after this, so a later frame
    -- rebuild would create fonts on it.
    sprites.dispose()
end)

ashita.events.register('d3d_present', 'xpreborn_present_cb', function()
    -- Config window draws regardless of bar visibility (player may open it any time).
    configWindow.draw(xrSettings, State, callbacks)

    -- Throttled data refresh; runs while the bar is hidden so buff polling and saving continue.
    if frameCount == 0 then
        packets.refreshDedication(State, xrSettings)

        local memMgr = AshitaCore:GetMemoryManager()
        local player = memMgr and memMgr:GetPlayer()
        State.refresh(player, xrSettings)

        -- Persist dedication state only when this refresh actually mutated it.
        if State.dedicationDirty then
            settings.save()
            State.dedicationDirty = false
        end
    end
    frameCount = (frameCount + 1) % THROTTLE

    -- Suppress bar while on title screen, zoning, or during cutscenes.
    local hide = shouldHide()
    xpFrame.setFrameVisible(not hide)
    if hide then return end

    -- Persist anchor if user dragged the bar
    local newAnch = xpFrame.getAnchor()
    if newAnch then
        xrSettings.anchor.x = newAnch.x
        xrSettings.anchor.y = newAnch.y
        settings.save()
    end

    -- While config is open and no real dedication is active, the bar shows sample data.
    local showPreview = configWindow.isOpen() and not State.dedication.active
    xpFrame.update(State, xrSettings, showPreview and DEDICATION_PREVIEW or nil)
end)

ashita.events.register('packet_in', 'xpreborn_packet_in_cb', function(e)
    if e.id == packets.ID.ZONE_OUT then
        -- Zone-out: suppress unconditionally until zone-in + entity spawn confirmed.
        frameZoneSuppressed = true
        xpFrame.setFrameVisible(false)
    elseif e.id == packets.ID.ZONE_IN then
        -- Zone-in arrived; d3d_present will clear frameZoneSuppressed once entity spawns.
        frameZoneSuppressed = true
    end

    packets.handleIn(e, State, xrSettings)
end)

ashita.events.register('mouse', 'xpreborn_mouse_cb', function(e)
    xpFrame.handleMouse(e, xrSettings.lockPosition)
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
        settings.reload()
        print(chat.header(addon.name) .. chat.message('Reloaded.'))
    elseif cmd == 'help' then
        print(chat.header(addon.name) .. chat.message('/xpreborn or /xr  Toggle config window'))
        print(chat.header(addon.name) .. chat.message('/xr reset         Clear dedication session'))
        print(chat.header(addon.name) .. chat.message('/xr reload        Reload settings and layout'))
        print(chat.header(addon.name) .. chat.message('/xr help          List commands'))
    else
        print(chat.header(addon.name) .. chat.warning(string.format('Unknown command: %s. Use /xr help.', cmd)))
    end
end)
