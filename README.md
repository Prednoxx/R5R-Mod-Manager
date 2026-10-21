# R5R Mod Manager

Mod manager for [R5Reloaded](https://r5reloaded.com). Works with the R5Reloaded mod system (`mods\<mod>\mod.vdf` and `mods\mods.vdf`).

## Features

- Turn mods on and off, install from `.zip` or folder (drag and drop works), uninstall to the Recycle Bin
- Presets: save which mods are on and switch between setups in one click
- Required core mods (Flowstate, SDK core) are locked on
- Dependency check: flags mods that need a missing or disabled mod, with one-click fix
- Restore mods from the Recycle Bin, or download R5Reloaded's stock mods from the official scripts repo
- Problem detection: missing `mod.vdf`, missing ID, duplicate IDs, nested folders
- Themes: Aero Day, Aero Night, Aqua, Aurora, Eco, Metro, Sunburst, Sweetheart, Windows 11 (follows system light/dark and accent color)

## Requirements

- Windows 10 or 11
- R5Reloaded installed

## Install

1. Download or clone this repo. Keep the `assets` folder next to `R5R Mod Manager.cmd`.
2. Run `R5R Mod Manager.cmd`. It finds your R5Reloaded folder automatically, or set it with **Change**.
3. A shortcut with the app icon is created next to the script on first run.

## Shortcuts

| Key | Action |
| --- | --- |
| Ctrl+F | Search |
| F5 | Rescan mods |
| Delete | Uninstall selected mod |

## Mod dependencies

Dependencies are detected from scripts that use ConVars defined by another mod. A mod can also list them in its `mod.vdf`:

```
"Dependencies"
{
    "Flowstate" "1"
}
```

## Data and privacy

Settings are stored in `%APPDATA%\R5RModManager`. The app only connects to the internet when you choose to download a stock mod, and then only to GitHub (`github.com/Mauler125/r5_flowstate`).

## Credits

Mascot: Lumi-tan, sprite by [blackbunney](https://blackbunney.itch.io/free-anime-girl-character-sprite). The sprite may not be resold on its own.

R5R Mod Manager is a fan-made tool and is not affiliated with Electronic Arts, Respawn Entertainment or the R5Reloaded team.

Copyright (C) 2026 Prednoxx. Licensed under the GNU Affero General Public License v3.0 or later (`LICENSE`). The Lumi-tan sprite is not covered by the software license.
