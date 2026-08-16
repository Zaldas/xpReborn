-- elements/configWindow.lua
-- ImGui configuration window for xpReborn.
-- Toggle with /xr (no args). Drawn every frame from xpReborn.lua d3d_present.

local imgui           = require('imgui')
local dedicationItems = require('data/dedicationItems')

local M = {}

-- ImGuiWindowFlags_AlwaysAutoResize = 64
local IMGUI_AUTO_RESIZE = 64
local WINDOW_WIDTH      = 240

local open = false

-----------------------------------------------------------------------
-- Style helpers
-----------------------------------------------------------------------

-- Blue gradient fade subheading (solid left -> transparent right).
local function drawGradientHeader(text, availW, helpText)
    local drawlist    = imgui.GetWindowDrawList()
    local x, y       = imgui.GetCursorScreenPos()
    local lineH       = imgui.GetTextLineHeightWithSpacing()
    local gradWidth   = availW * 0.75
    local colLeft     = { 0.25, 0.40, 0.85, 1.00 }
    local colRight    = { colLeft[1], colLeft[2], colLeft[3], 0.00 }
    local colLeftU32  = imgui.GetColorU32(colLeft)
    local colRightU32 = imgui.GetColorU32(colRight)

    drawlist:AddRectFilledMultiColor(
        { x, y },
        { x + gradWidth, y + lineH },
        colLeftU32, colRightU32, colRightU32, colLeftU32
    )

    imgui.SetCursorScreenPos({ x + 4, y + 2 })
    imgui.Text(text)
    if helpText then
        imgui.SameLine()
        imgui.TextDisabled('(?)')
        if imgui.IsItemHovered() then
            imgui.SetTooltip(helpText)
        end
    end

    local _, newY = imgui.GetCursorScreenPos()
    imgui.SetCursorScreenPos({ x, newY })
    imgui.Spacing()
end

-- Rounded primary (blue) or ghost (transparent) button.
local function styledButton(label, size, isPrimary)
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0)

    if isPrimary then
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.25, 0.40, 0.85, 1.00 })
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.30, 0.48, 0.95, 1.00 })
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.18, 0.32, 0.70, 1.00 })
    else
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.00, 0.00, 0.00, 0.00 })
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 1.00, 1.00, 1.00, 0.12 })
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 1.00, 1.00, 1.00, 0.20 })
    end

    local clicked = imgui.Button(label, size)
    imgui.PopStyleColor(3)
    imgui.PopStyleVar(1)
    return clicked
end

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

    imgui.SetNextWindowSize({ WINDOW_WIDTH, 0 }, 1)

    local winOpen = { true }
    if imgui.Begin('xpReborn.' .. addon.version, winOpen, IMGUI_AUTO_RESIZE) then

        local avail  = imgui.GetContentRegionAvail()
        local availW = type(avail) == 'table' and avail[1] or avail
        local itemW  = math.floor(availW * 0.80)
        local pad    = math.floor((availW - itemW) * 0.5)
        local indent = 8
        local comboW = math.floor((availW - indent) * 0.65)

        -- ============================================================
        -- Display
        -- ============================================================
        drawGradientHeader('Display', availW, 'Toggle which text elements appear on the XP bar.')

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local showJobLevel = { xrSettings.display.showJobLevel == true }
        if imgui.Checkbox('Show job / level', showJobLevel) then
            cb.onShowJobLevel(showJobLevel[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show the current job abbreviation and level (e.g. NIN 75).')
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local showNumbers = { xrSettings.display.showNumbers == true }
        if imgui.Checkbox('Show numbers', showNumbers) then
            cb.onShowNumbers(showNumbers[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show current XP / XP-to-level numbers (or LP / merit count in limit mode).')
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local showPercent = { xrSettings.display.showPercent == true }
        if imgui.Checkbox('Show percent', showPercent) then
            cb.onShowPercent(showPercent[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show progress as a percentage beneath the numbers.')
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local showDedication = { xrSettings.display.showDedication == true }
        if imgui.Checkbox('Show dedication', showDedication) then
            cb.onShowDedication(showDedication[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show the dedication bar and label when a dedication item is active.')
        end

        imgui.Spacing()

        -- ============================================================
        -- Dedication
        -- ============================================================
        drawGradientHeader(
            'Dedication',
            availW,
            'Track XP bonus items (Emperor Band, Wandering Heroes, etc.). The bar shrinks as the budget is used.'
        )

        local ded = state.dedication
        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
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

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local defaultingEnabled = { xrSettings.dedication.defaultingEnabled == true }
        if imgui.Checkbox('Auto-assume default item', defaultingEnabled) then
            cb.onDefaultingEnabled(defaultingEnabled[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'When enabled, automatically assumes a dedication item is active if the dedication ' ..
                'buff is present but no item-use packet was seen.'
            )
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local overflowEnabled = { xrSettings.dedication.overflowEnabled == true }
        if imgui.Checkbox('Dedication overflow', overflowEnabled) then
            cb.onOverflowEnabled(overflowEnabled[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Allow the acquired XP to exceed the item max\n' ..
                'while the buff is still active (e.g. 10040 / 10000).'
            )
        end

        if xrSettings.dedication.defaultingEnabled then
            imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
            imgui.Text('Default item:')

            local defaultId    = xrSettings.dedication.defaultItemId
            local currentEntry = dedicationItems[defaultId]
            local currentName  = currentEntry and currentEntry.name
                or dedicationItems[dedicationItems.ordered[1].id].name

            imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
            imgui.SetNextItemWidth(comboW)
            if imgui.BeginCombo('##defitem', currentName) then
                for _, item in ipairs(dedicationItems.ordered) do
                    local selected = (item.id == defaultId)
                    if imgui.Selectable(dedicationItems[item.id].name, selected) then
                        if item.id ~= defaultId then cb.onDefaultItemId(item.id) end
                    end
                    if selected then imgui.SetItemDefaultFocus() end
                end
                imgui.EndCombo()
            end
        end

        imgui.Spacing()

        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad)
        if styledButton('Reset##dedresetbtn', { itemW, 0 }, false) then
            cb.onResetDedication()
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Clear the current dedication session. Use this if tracking is out of sync.')
        end

        imgui.Spacing()

        -- ============================================================
        -- Position
        -- ============================================================
        drawGradientHeader('Position', availW)

        imgui.SetCursorPosX(imgui.GetCursorPosX() + indent)
        local lockPosition = { xrSettings.lockPosition == true }
        if imgui.Checkbox('Lock position', lockPosition) then
            cb.onLockPosition(lockPosition[1])
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Disable drag-to-move so the bar cannot be accidentally repositioned.')
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad)
        if styledButton('Reset Position##resetpos', { itemW, 0 }, false) then
            cb.onResetAnchor()
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Snap bar to position (100, 100). Use if it has moved off-screen.')
        end
    end
    imgui.End()

    if not winOpen[1] then
        open = false
    end
end

return M
