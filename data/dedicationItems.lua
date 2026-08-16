-- data/dedicationItems.lua
-- Dedication (XP boost) item database.
-- rate = bonus percentage (50 = +50%, 100 = +100% = double XP)
-- max  = total bonus XP budget before item expires
-- Rate/max values for all five items confirmed HorizonXI-accurate by the user on 2026-07-10.

local items = {
    [15763] = { id = 15763, name = 'Emperor Band',     rate = 75,  max = 2250  },
    [15762] = { id = 15762, name = 'Empress Band',     rate = 50,  max = 1000  },
    [15761] = { id = 15761, name = 'Chariot Band',     rate = 100, max = 4000  },
    [8191]  = { id = 8191,  name = 'Wandering Heroes', rate = 75,  max = 10000 },
    [15793] = { id = 15793, name = 'Anniversary Ring', rate = 100, max = 3000  },
}

-- Ordered list for config window combo box (display order only; names resolved via id-keyed table above)
items.ordered = {
    { id = 15761 },
    { id = 15763 },
    { id = 15762 },
    { id = 8191  },
    { id = 15793 },
}

return items
