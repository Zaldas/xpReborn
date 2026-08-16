-- elements/xpFrame.lua
-- spui rendering element for xpReborn.
-- Owns the sprite engine and the spui element tree (root container):
--   - main XP/LP bar (barXp)        always visible
--   - dedication budget bar (barDed) visible only while dedication is active
--   - text labels: job/level, numbers, percent, dedication
--
-- Layout coordinates are authored at the 1440p baseline; uiScale = resY / 1440 is
-- applied via root:scale(). Image paths in the layout are RELATIVE to the addon
-- folder; uiImage prepends addon.path internally (see libs/spui/uiImage.lua), so
-- this module must NOT prepend it again.

local sprites     = require('libs/spui/sprites')
local uiContainer = require('libs/spui/uiContainer')
local uiBar       = require('libs/spui/uiBar')
local uiText      = require('libs/spui/uiText')
local utils       = require('libs/spui/utils')

-- 1440p baseline scaling
local resY    = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0002', 768)
local uiScale = resY / 1440

-- Main XP bar layout dimensions (1440p baseline). Used for drag hit testing.
-- BAR_W/BAR_H are fallback defaults; barW/barH are the live values, set from
-- the layout's xpBar.imgBg.size in initialize() when available.
local BAR_W = 537
local BAR_H = 64
local barW  = BAR_W
local barH  = BAR_H

-- Windows mouse message ids (match Ashita's 'mouse' event e.message values)
local MSG_LBUTTON_DOWN = 513
local MSG_LBUTTON_UP   = 514
local MSG_MOUSEMOVE    = 512

local xpFrame = {}

-- Sprite engine + element refs (set in initialize, cleared in destroy)
local engine   = nil
local root     = nil
local barXp    = nil
local barDed   = nil
local txtJob   = nil
local txtNums  = nil
local txtPct   = nil
local txtDedit = nil

-- Anchor (screen position of root, top-left of the main bar)
local anchorX = 0
local anchorY = 0

-- Drag state
local dragActive  = false
local dragOffsetX = 0
local dragOffsetY = 0
local anchorDirty = false

-- Tracks whether the dedication elements are currently shown (avoids redundant calls)
local dedShown = false

-- Frame-level suppression: true while game state doesn't allow the bar to show
-- (title screen, zoning, cutscene). Toggled via setFrameVisible().
local suppressed = false

-- Registers a child element (pos already set from layout.pos during init), creates
-- its primitives, then hides it. root.isCreated is false at this point so addChild
-- only lays out the child; createPrimitives must be called explicitly.
local function addElement(element)
    root:addChild(element)
    element:createPrimitives()
    element:hide(utils.VIS_DEFAULT)
end

-- Hit test against the main bar bounds in screen space (scaled).
local function hitTest(mx, my)
    local left   = anchorX
    local top    = anchorY
    local right  = anchorX + barW * uiScale
    local bottom = anchorY + barH * uiScale
    return mx >= left and mx <= right and my >= top and my <= bottom
end

-- @param layout  the layout table (layouts/default.lua)
-- @param ax      initial anchor X (screen pixels)
-- @param ay      initial anchor Y (screen pixels)
function xpFrame.initialize(layout, ax, ay)
    local L = layout

    -- Drag hit-box dimensions come from the layout's main bar size, falling
    -- back to BAR_W/BAR_H if the layout is missing/incomplete (e.g. loadLayout()
    -- returned {} on a load failure).
    local bgSize = L.xpBar and L.xpBar.imgBg and L.xpBar.imgBg.size
    if bgSize and bgSize[1] and bgSize[2] then
        barW = bgSize[1]
        barH = bgSize[2]
    else
        barW = BAR_W
        barH = BAR_H
    end

    anchorX = ax or 0
    anchorY = ay or 0

    -- Sprite engine: registers itself with the global d3d_present dispatcher.
    engine = sprites.newEngine()

    -- Root container: scaled to UI resolution, positioned at the anchor.
    root = uiContainer.new()
    root:scale(uiScale, uiScale)
    root:pos(anchorX, anchorY)

    -- Main XP/LP bar (always visible). Layout image paths are relative; uiImage
    -- prepends addon.path internally, so pass the layout sub-table as-is.
    barXp = uiBar.new(L.xpBar, engine)
    addElement(barXp)
    barXp:show(utils.VIS_DEFAULT)

    -- Dedication budget bar (below the main bar). Hidden until dedication active.
    barDed = uiBar.new(L.dedBar, engine)
    addElement(barDed)

    -- Text labels (shown selectively in update based on settings)
    txtJob = uiText.new(L.txtJob)
    addElement(txtJob)

    txtNums = uiText.new(L.txtNumbers)
    addElement(txtNums)

    txtPct = uiText.new(L.txtPercent)
    addElement(txtPct)

    txtDedit = uiText.new(L.txtDedit)
    addElement(txtDedit)

    dedShown  = false

    -- Start suppressed; xpReborn.lua calls setFrameVisible(true) once the game
    -- state confirms the player is logged in and not in a cutscene/zone.
    suppressed = false
    xpFrame.setFrameVisible(false)
end

-- Per-frame data + animation update.
-- @param state    the shared state table (state.lua)
-- @param settings the live settings table; reads settings.display.show* flags
-- @param preview  optional override for the dedication-bar block, shaped
--                  { dedication = {...}, txtDedit = '...' }; nil for normal operation
function xpFrame.update(state, settings, preview)
    if not engine then return end

    local disp = settings and settings.display or {}

    -- Main bar value: LP norm in lp mode, XP norm otherwise.
    local value = (state.mode == 'lp') and state.lpNorm or state.xpNorm
    barXp:setValue(value or 0)

    -- Job / level label
    if disp.showJobLevel then
        txtJob:update(state.txtJob)
        txtJob:show(utils.VIS_DEFAULT)
    else
        txtJob:hide(utils.VIS_DEFAULT)
    end

    -- Numbers label (current / needed)
    if disp.showNumbers then
        txtNums:update(state.txtNumbers)
        txtNums:show(utils.VIS_DEFAULT)
    else
        txtNums:hide(utils.VIS_DEFAULT)
    end

    -- Percent label
    if disp.showPercent then
        txtPct:update(state.txtPercent)
        txtPct:show(utils.VIS_DEFAULT)
    else
        txtPct:hide(utils.VIS_DEFAULT)
    end

    -- Dedication bar + label: shown only when enabled AND active. `preview`
    -- (when provided) overrides state.dedication/state.txtDedit for setup-mode preview.
    local ded     = (preview and preview.dedication) or state.dedication
    local dedText = (preview and preview.txtDedit) or state.txtDedit
    local showDed = disp.showDedication and ded and ded.active
    if showDed then
        barDed:setValue(ded.norm or 0)
        txtDedit:update(dedText)
        if not dedShown then
            barDed:show(utils.VIS_DEFAULT)
            txtDedit:show(utils.VIS_DEFAULT)
            dedShown = true
        end
    elseif dedShown then
        barDed:hide(utils.VIS_DEFAULT)
        txtDedit:hide(utils.VIS_DEFAULT)
        dedShown = false
    end

    -- Advance bar animations (cascades to all children).
    root:update()
end

-- Mouse handler for drag-to-move. Returns nothing; sets e.blocked when consuming.
function xpFrame.handleMouse(e)
    if not engine then return end

    if e.message == MSG_LBUTTON_DOWN then
        if hitTest(e.x, e.y) then
            dragActive  = true
            dragOffsetX = e.x - anchorX
            dragOffsetY = e.y - anchorY
            e.blocked   = true
        end

    elseif e.message == MSG_LBUTTON_UP then
        if dragActive then
            dragActive  = false
            anchorDirty = true
            e.blocked   = true
        end

    elseif e.message == MSG_MOUSEMOVE then
        if dragActive then
            local newX = e.x - dragOffsetX
            local newY = e.y - dragOffsetY
            if newX ~= anchorX or newY ~= anchorY then
                anchorX = newX
                anchorY = newY
                root:pos(anchorX, anchorY)
            end
            e.blocked = true
        end
    end
end

-- Returns the new anchor once after a drag completes, then clears the dirty flag.
-- Returns nil when the anchor hasn't changed since the last call.
function xpFrame.getAnchor()
    if anchorDirty then
        anchorDirty = false
        return { x = anchorX, y = anchorY }
    end
    return nil
end

-- Sets the anchor programmatically (e.g. from saved settings) without marking dirty.
function xpFrame.setAnchor(x, y)
    anchorX = x
    anchorY = y
    if root then root:pos(anchorX, anchorY) end
end

-- Shows or hides the entire frame. Called by xpReborn.lua when game state changes
-- (login, zoning, cutscene). Uses root:hide/show which cascades absoluteVisibility
-- to all children via layoutElement, so individual element flags are unaffected.
function xpFrame.setFrameVisible(visible)
    if not root then return end
    if visible == (not suppressed) then return end
    suppressed = not visible
    if suppressed then
        root:hide(utils.VIS_DEFAULT)
    else
        root:show(utils.VIS_DEFAULT)
    end
end

-- Disposes the element tree and the sprite engine.
function xpFrame.destroy()
    if not engine then return end

    if root then root:dispose() end
    engine:destroy()

    engine   = nil
    root     = nil
    barXp    = nil
    barDed   = nil
    txtJob   = nil
    txtNums  = nil
    txtPct   = nil
    txtDedit = nil

    dragActive  = false
    anchorDirty = false
    dedShown    = false
    suppressed  = false
end

return xpFrame
