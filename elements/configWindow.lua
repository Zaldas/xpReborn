-- elements/configWindow.lua
-- ImGui configuration window for xpReborn.
-- Toggle with /xr (no args). Drawn every frame from xpReborn.lua d3d_present.

local imgui           = require('imgui')
local dedicationItems = require('data/dedicationItems')
local uiTheme         = require('libs/uiTheme')

local M = {}

-- ImGuiWindowFlags_AlwaysAutoResize = 64
local IMGUI_AUTO_RESIZE = 64
local WINDOW_WIDTH      = 240

local open = false

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

function M.toggle()
    open = not open
end

function M.isOpen()
    return open
end

function M.initialize()
    open = false
end

function M.destroy()
    open = false
end

-- Draw the config window. Call every frame from d3d_present.
-- xrSettings: live settings table (read for current values)
-- state:      shared state table (reads state.dedication for progress display)
-- cb:         callbacks table (see header doc / plan)
function M.draw(xrSettings, state, cb)
    if not open then return end

    local function drawBody()
        -- ============================================================
        -- Display
        -- ============================================================
        uiTheme.header('Display', 'Toggle which text elements appear on the XP bar.')

        imgui.Indent(uiTheme.indent)
        local showJobLevel = { xrSettings.display.showJobLevel == true }
        if imgui.Checkbox('Show job / level', showJobLevel) then
            cb.onShowJobLevel(showJobLevel[1])
        end
        uiTheme.helpMarker('Show the current job abbreviation and level (e.g. NIN 75).')

        local showNumbers = { xrSettings.display.showNumbers == true }
        if imgui.Checkbox('Show numbers', showNumbers) then
            cb.onShowNumbers(showNumbers[1])
        end
        uiTheme.helpMarker('Show current XP / XP-to-level numbers (or LP / merit count in limit mode).')

        local showPercent = { xrSettings.display.showPercent == true }
        if imgui.Checkbox('Show percent', showPercent) then
            cb.onShowPercent(showPercent[1])
        end
        uiTheme.helpMarker('Show progress as a percentage beneath the numbers.')

        local showDedication = { xrSettings.display.showDedication == true }
        if imgui.Checkbox('Show dedication', showDedication) then
            cb.onShowDedication(showDedication[1])
        end
        uiTheme.helpMarker('Show the dedication bar and label when a dedication item is active.')
        imgui.Unindent(uiTheme.indent)

        imgui.Spacing()

        -- ============================================================
        -- Dedication
        -- ============================================================
        uiTheme.header(
            'Dedication',
            'Track XP bonus items (Emperor Band, Wandering Heroes, etc.). The bar shrinks as the budget is used.'
        )

        local ded = state.dedication
        imgui.Indent(uiTheme.indent)
        if ded.active and ded.itemMax > 0 then
            local pct      = (1 - ded.norm) * 100
            local acquired = math.floor(ded.acquired)
            local firstNum = xrSettings.dedication.overflowEnabled and acquired or math.min(acquired, ded.itemMax)
            local progressStr = string.format('%s: %d / %d (%.0f%%)', ded.itemName, firstNum, ded.itemMax, pct)
            imgui.Text(progressStr)
        elseif ded.active then
            imgui.Text('Dedication active (no budget set)')
        else
            imgui.TextDisabled('No dedication active.')
        end

        local defaultingEnabled = { xrSettings.dedication.defaultingEnabled == true }
        if imgui.Checkbox('Auto-assume default item', defaultingEnabled) then
            cb.onDefaultingEnabled(defaultingEnabled[1])
        end
        uiTheme.helpMarker(
            'When enabled, automatically assumes a dedication item is active if the dedication ' ..
            'buff is present but no item-use packet was seen.'
        )

        local overflowEnabled = { xrSettings.dedication.overflowEnabled == true }
        if imgui.Checkbox('Dedication overflow', overflowEnabled) then
            cb.onOverflowEnabled(overflowEnabled[1])
        end
        uiTheme.helpMarker(
            'Allow the acquired XP to exceed the item max\n' ..
            'while the buff is still active (e.g. 10040 / 10000).'
        )

        if xrSettings.dedication.defaultingEnabled then
            local defaultId    = xrSettings.dedication.defaultItemId
            local currentEntry = dedicationItems[defaultId]
            local currentName  = currentEntry and currentEntry.name
                or dedicationItems[dedicationItems.ordered[1].id].name

            imgui.Indent(uiTheme.subIndent)
            imgui.SetNextItemWidth(uiTheme.comboWidth())
            if imgui.BeginCombo('Default item##defitem', currentName) then
                for _, item in ipairs(dedicationItems.ordered) do
                    local selected = (item.id == defaultId)
                    if imgui.Selectable(dedicationItems[item.id].name, selected) then
                        if item.id ~= defaultId then cb.onDefaultItemId(item.id) end
                    end
                    if selected then imgui.SetItemDefaultFocus() end
                end
                imgui.EndCombo()
            end
            imgui.Unindent(uiTheme.subIndent)
        end
        imgui.Unindent(uiTheme.indent)

        imgui.Spacing()

        if uiTheme.centeredButton('Reset##dedresetbtn', 'ghost') then
            cb.onResetDedication()
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Clear the current dedication session. Use this if tracking is out of sync.')
        end

        imgui.Spacing()

        -- ============================================================
        -- Position
        -- ============================================================
        uiTheme.header('Position')

        imgui.Indent(uiTheme.indent)
        local lockPosition = { xrSettings.lockPosition == true }
        if imgui.Checkbox('Lock position', lockPosition) then
            cb.onLockPosition(lockPosition[1])
        end
        uiTheme.helpMarker('Disable drag-to-move so the bar cannot be accidentally repositioned.')
        imgui.Unindent(uiTheme.indent)

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if uiTheme.centeredButton('Reset position##resetpos', 'ghost') then
            cb.onResetAnchor()
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Snap bar to position (100, 100). Use if it has moved off-screen.')
        end
    end

    local n = uiTheme.push()
    imgui.SetNextWindowSize({ WINDOW_WIDTH, 0 }, 1)

    local winOpen = { true }
    local ok, err = true, nil
    if imgui.Begin('xpReborn.' .. addon.version, winOpen, IMGUI_AUTO_RESIZE) then
        ok, err = pcall(drawBody)
    end
    imgui.End()
    uiTheme.pop(n)

    if not winOpen[1] then
        open = false
    end
    if not ok then error(err, 0) end
end

return M
