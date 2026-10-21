# Using R5R Mod Manager

## Select a game folder

Extract the full portable package and open **R5R Mod Manager.exe**. The app searches for existing installations. If the game is not detected, open **Settings > Choose game folder** and select the folder containing `r5apex.exe`. The Install control on a compatible store listing also offers folder selection when no game is selected.

## Find mods

Use **Mods Store** to search by name, author, description or mod ID. Select **R5Reloaded S3** in the build filter to show listings for the supported game. Category filters match individual tags; selecting Map includes listings tagged with both Map and Gamemode. Filters can be combined with search, sorting and Favorites. **Clear filters** resets all filters and search.

Select a mod's name or preview to open its details. The page shows its source, version, compatibility, description and available gallery images. Select a gallery image to view it at full size. Escape closes the image or returns to the store. Favorites are saved between sessions.

Flowstate S21 and legacy packages remain available for browsing and source links. They cannot be installed into an S3 game through this app. Listings without publisher artwork show a placeholder.

## Install and update

Select **Install** on a compatible listing. Progress and cancellation are available in **Downloads**. Updates and reinstalls require a separate install action; catalog refresh does not install packages automatically. Replacing an installed mod requires confirmation, and the previous copy goes to the Windows Recycle Bin.

For downloaded mods, open **Mods Library** and select **Install .zip** or **Install folder**. A ZIP may include a wrapper folder, but it must contain a valid `mod.vdf`. Extract `.7z` and `.rar` archives before installing their folders. Close R5Reloaded, including its dedicated server, before installing mods.

Changing game folders clears pending installations for the previous folder. An active download for that folder cannot install into the newly selected game.

## Manage a collection

Use the switches in **Mods Library** to enable or disable mods. **Disable all** preserves required game mods. Dependency errors appear in the library; missing dependencies and disabled dependencies are listed separately.

Select **Save as new** to save the current enabled-mod combination as a preset. Select a saved preset to apply it. Presets record optional-mod switches; they do not include mod files or install missing mods. **Save** updates the selected preset after changes.

## Restore a mod

Open **Restore** in the library to find uninstalled mods and previous copies from replacements. A folder already present in the library cannot be overwritten by Restore. To recover an older copy, uninstall the current copy first, then restore the older entry. Recovery depends on the item remaining in the Windows Recycle Bin.

## Browse cached listings

Previously retrieved listings, previews and descriptions remain available when a source is unavailable. Open **Catalog sources** to inspect each source's state. A failed source retains its last successful listings while other sources continue updating. **Refresh** retries source synchronization. A network connection is required to download an uncached package or retrieve new artwork.
