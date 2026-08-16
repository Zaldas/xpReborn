# xpReborn

**An FFXI addon for HorizonXI (Ashita v4) that shows a persistent XP / LP bar with
dedication item tracking.**

xpReborn keeps an XP (or Limit Point) bar on screen at all times and tracks how much of
your active dedication item's bonus pool you have left, so you can see at a glance
whether a ring still has charge on it.

<img width="553" height="42" alt="image" src="https://github.com/user-attachments/assets/5f643c07-db68-46aa-a16b-f4602ce1c175" />

<img width="528" height="40" alt="image" src="https://github.com/user-attachments/assets/d8705785-37a3-4c6e-9a80-bfb894310540" />

---

## Features

- **Persistent XP / LP bar** — switches to Limit Points automatically at the level cap
- **Dedication item tracking** — live remaining bonus for Chariot, Emperor, and the rest
  of the dedication ring family
- **Layout-driven rendering** — the whole bar is described by `layouts/default.lua`
- **Config window** — display toggles, dedication options, and position lock
- **Stays out of the way** — hides on the title screen, while zoning, during cutscenes,
  and whenever the game UI is hidden

## Installation

1. Extract the `xpReborn` folder into `Ashita4/addons/`
2. `/addon load xpReborn`

No font installation is required — the default layout uses Tahoma, which ships with
Windows.

## Commands

| Command | Effect |
|---------|--------|
| `/xpreborn` or `/xr` | Toggle the config window |
| `/xr reset` | Clear the current dedication session |
| `/xr reload` | Reload settings and layout |
| `/xr help` | List commands in chat |

The bar is drag-to-move. Lock it in the config window once it's where you want it, and
use **Reset Position** if it ever ends up off-screen.

## License

**MIT** — see [LICENSE](LICENSE).

xpReborn bundles two libraries, each of which keeps its own notice:

| Path | License | Copyright |
|---|---|---|
| everything not listed below | MIT | © 2026 Zaldas |
| [`libs/spui/`](libs/spui/LICENSE) | BSD 3-Clause | © 2023 Tylas ([XivParty](https://github.com/Tylas11/XivParty)) |
| [`libs/gdifonts/`](libs/gdifonts/LICENSE) | MIT | © 2023 Thorny |

`libs/spui/classes.lua` is in turn based on Paul Moore's classes library, © 2011 Strange
Ideas Software (MIT).

## Acknowledgements

- **[Tylas11](https://github.com/Tylas11/XivParty)** — the sprite library xpReborn's
  rendering is built on
- **[Thorny](https://github.com/ThornyFFXI)** and **[atom0s](https://github.com/atom0s)** —
  for everything they do for Ashita and the wider FFXI community
