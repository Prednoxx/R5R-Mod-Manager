# R5R Mod Manager

Windows mod manager for [R5Reloaded](https://r5reloaded.com).

## Run

Extract the portable package and open **R5R Mod Manager.exe**. Keep `app.ps1`, `assets`, `catalog`, `lib` and `ui` beside the executable. The app detects an existing game folder or accepts one in Settings.

Requires Windows 10 or 11, .NET Framework 4.8 and Windows PowerShell 5.1. These are included with supported Windows installations. The executable hosts the application directly without opening a console window.

## Features

- Image-based mod store with search, build/source/category filters, sorting and favorites.
- Mod pages with publisher previews, descriptions, gallery images, version information and installation controls.
- GitHub and Thunderstore catalog providers, maintained feeds, background synchronization and offline cache.
- R5Reloaded S3 compatibility checks. Flowstate S21 and legacy releases remain available as source listings.
- Background downloads, integrity checks, staged installation, replacement confirmation and rollback.
- Installed-mod switches, dependency checks, presets, local ZIP/folder installation and Recycle Bin recovery.
- Obsidian, Windows 11 and the existing wallpaper themes.

The installer supports the R5Reloaded S3 layout: `mods/<folder>/mod.vdf` and `mods/mods.vdf`. The store does not convert mods between game builds. Listings without publisher artwork display a labeled placeholder.

## Controls

| Key | Action |
| --- | --- |
| Ctrl+F | Focus search |
| F5 | Refresh the current store or library |
| Escape | Close an image preview or return from mod details |
| Enter | Open the selected store mod |
| Delete | Uninstall the selected library mod |

## Build and test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1 -Live
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1 -Live -Recycle
```

The build uses the Windows .NET Framework compiler. The portable archive is written to `dist/R5R-Mod-Manager-3.2.zip`. Tests use temporary game folders. `-Live` also checks the configured sources and downloads a pinned official mod. `-Recycle` verifies replacement recovery through the Windows Recycle Bin using a temporary mod.

## Data

Settings, favorites, installed-package receipts, catalog snapshots, previews and logs are stored in `%APPDATA%/R5RModManager`. The app contacts configured catalog sources at startup and during refresh. Mod descriptions and previews load from their publishers; packages download only after an installation action. Source pages open in the default browser.

[Catalog sources and feed format](docs/catalog.md)

[Usage guide](docs/usage.md)

## Credits and license

Copyright (C) 2026 Prednoxx. Software licensed under the GNU Affero General Public License v3.0 or later. See [LICENSE](LICENSE).

Lumi-tan sprite by [blackbunney](https://blackbunney.itch.io/free-anime-girl-character-sprite). The sprite is not covered by the software license and may not be resold on its own. See `assets/CREDITS.txt` for asset credits. Publisher previews and mod packages retain their original ownership and licenses.

R5R Mod Manager is not affiliated with Electronic Arts, Respawn Entertainment or the R5Reloaded team.
