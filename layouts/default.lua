-- layouts/default.lua
-- xpReborn layout definition. All sizes in D3D pixels at 1440p baseline.
-- uiScale = resY / 1440 is applied by xpFrame.lua at runtime via root:scale().
--
-- Bar geometry: 537x64, sliceBorder={30,30,60,60}.
-- Child image pos values are relative to the bar container, not the screen.
-- Top-level pos = {x, y} is the container's position relative to the root anchor.

return {
    -- ── Main XP / LP bar ────────────────────────────────────────────────────
    xpBar = {
        pos       = { 0, 0 },
        animSpeed = 0.2,
        imgBg = {
            path        = 'assets/BarBG.png',
            size        = { 537, 64 },
            pos         = { 0, 0 },
            color       = '#C8A030FF',
            sliceBorder = { 30, 30, 60, 60 },
        },
        imgBar = {
            path  = 'assets/Bar.png',
            size  = { 511, 64 },
            pos   = { 13, 0 },
            color = '#C8A030FF',
        },
        imgFg = {
            path        = 'assets/BarFG.png',
            size        = { 537, 64 },
            pos         = { 0, 0 },
            color       = '#C8A030FF',
            sliceBorder = { 30, 30, 60, 60 },
        },
        imgGlow = {
            path  = 'assets/BarGlow.png',
            size  = { 8, 64 },
            pos   = { 24, 0 },
            color = '#FFE870FF',
        },
    },

    -- ── Dedication budget bar (narrower, same height, below main bar) ────────
    dedBar = {
        pos       = { 5, 8 },   -- layout-space {x, y} relative to root anchor
        animSpeed = 0.5,
        imgBg = {
            path        = 'assets/BarBG.png',
            size        = { 320, 64 },
            pos         = { 0, 0 },
            color       = '#3ABCB0FF',
            sliceBorder = { 30, 30, 60, 60 },
        },
        imgBar = {
            path  = 'assets/Bar.png',
            size  = { 294, 64 },   -- 320 - 13 left border - 13 right border
            pos   = { 13, 0 },
            color = '#3ABCB0FF',
        },
        imgFg = {
            path        = 'assets/BarFG.png',
            size        = { 320, 64 },
            pos         = { 0, 0 },
            color       = '#3ABCB0FF',
            sliceBorder = { 30, 30, 60, 60 },
        },
    },

    -- ── Text labels (pos = {x, y} relative to root anchor, layout-space) ────
    txtJob = {
        pos         = { 18, 17 },
        font        = 'Tahoma',
        size        = 12,
        bold        = true,
        color       = '#E8E8E8FF',
        stroke      = '#000000C0',
        strokeWidth = 2,
    },
    txtNumbers = {
        pos         = { 519, 17 },   -- right-aligned within 537px bar
        font        = 'Tahoma',
        size        = 12,
        bold        = true,
        color       = '#E8E8E8FF',
        stroke      = '#000000C0',
        strokeWidth = 2,
        align       = 'right',
    },
    txtPercent = {
        pos         = { 510, 31 },
        font        = 'Tahoma',
        size        = 12,
        bold        = true,
        color       = '#E8E8E8FF',
        stroke      = '#000000C0',
        strokeWidth = 2,
        align       = 'right',
    },
    txtDedit = {
        pos         = { 24, 40 },
        font        = 'Tahoma',
        size        = 12,
        bold        = true,
        color       = '#E8E8E8FF',
        stroke      = '#000000C0',
        strokeWidth = 2,
    },
}
