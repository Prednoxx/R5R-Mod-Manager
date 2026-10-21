# Mod catalog

## Sources

Verified October 21, 2026.

| Source | Index | Package handling |
| --- | --- | --- |
| [Official R5Reloaded scripts](https://github.com/Mauler125/r5_flowstate) | GitHub branch and recursive tree APIs; metadata from `defaults/mods/*/mod.vdf` | Selected files downloaded at a fixed commit, checked against Git blob hashes, then passed to the mod installer |
| [R5Flowstate on Thunderstore](https://thunderstore.io/c/r5flowstate/) | Community package API, latest active version, categories, dependencies and publisher icons | Listed as Flowstate S21; installation blocked for R5Reloaded S3 |
| [Legacy Flowstate releases](https://github.com/CafeFPS/r5_flowstate/releases) | Maintained catalog entry | Source page only; these packages replace game scripts and require separate SDK/assets |
| [R5Reloaded Discord](https://discord.com/invite/r5reloaded) | Maintained community link | No attachment scraping or private-channel indexing |

R5Flowstate's [mod guide](https://r5flowstate.org/tools/mod-guide/) explicitly describes S21 packages and links its Thunderstore community. The shared `mod.vdf` filename does not establish compatibility with the S3 game. The store keeps these builds separate.

No verified R5Reloaded-specific GameBanana or Nexus feed is configured. Deadlock's GameBanana catalog is not an R5Reloaded catalog.

API references: [GitHub trees](https://docs.github.com/en/rest/git/trees#get-a-tree), [Thunderstore API implementation](https://github.com/thunderstore-io/Thunderstore), [Thunderstore CLI endpoints](https://github.com/thunderstore-io/thunderstore-cli/blob/master/ThunderstoreCLI/API/ApiHelper.cs).

## Synchronization

`catalog/sources.json` registers providers. Source IDs must be unique. Supported providers are `github-tree`, `thunderstore` and `feed`.

Each source has a separate last-successful snapshot in `%APPDATA%\R5RModManager\catalog`. The store reads these snapshots before starting network requests. Sources refresh after 30 minutes; failures retain their previous listings and retry after five minutes. Refresh forces an immediate check. HTTP requests use ETags, HTTPS, timeouts and response-size limits. A successful source response replaces that source's complete listing, including removals. Listings are deduplicated by game build and mod ID, with the first configured source taking precedence.

Publisher icons and supplied previews are cached separately. Full descriptions and gallery images load when opening a mod page. Missing artwork has a labeled placeholder. Remote descriptions render as text; remote HTML and scripts are not executed.

## Maintained feeds

`catalog/community.json` is the bundled feed. A feed source can also specify an HTTPS `url` instead of a relative `path` in `sources.json`. Feed endpoints must be accessible without credentials. Repository permissions are not changed by the app.

Example installable feed:

```json
{
  "schemaVersion": 1,
  "mods": [
    {
      "id": "Example.Movement",
      "modId": "Example.Movement",
      "name": "Movement Practice",
      "author": "Example",
      "description": "Movement practice map and scripts.",
      "version": "1.0.0",
      "build": "R5Reloaded S3",
      "category": "Movement",
      "installKind": "zip",
      "pageUrl": "https://example.org/mods/movement",
      "downloadUrl": "https://example.org/mods/movement-1.0.0.zip",
      "previewUrls": ["https://example.org/mods/movement-preview.png"],
      "dependencies": []
    }
  ]
}
```

Use `installKind: "manual"` for releases without a verified compatible package. Installable entries require a mod ID and an HTTPS download URL. `sha256` can pin a ZIP's checksum. Package IDs and versions must match `mod.vdf`; dependencies use mod IDs. The ZIP must contain exactly one mod, either directly or inside a wrapper folder.

Example feed registration:

```json
{
  "id": "community-feed",
  "name": "Community releases",
  "type": "feed",
  "url": "https://example.org/r5r/catalog.json"
}
```

GitHub sources specify `repository`, ordered `refs`, `root`, `build` and `category`. The configured official refs are `r5r_scripts_2025f` and `retail`. They are explicit release channels; changing to PTU requires a source configuration change. Commits are resolved before metadata or package files are retrieved.

## Installation

Downloads and package preparation run outside the UI thread. Packages stage on the game volume. Before installation, the app checks the target build, mod ID, version and archive paths. ZIP path traversal, symbolic links, duplicate paths, invalid Windows names and excessive archive sizes are rejected. GitHub directory downloads verify each file against its pinned Git blob hash.

The shared installer detects an existing mod by ID, requests replacement confirmation, preserves its folder name, and moves the staged copy into place. Failed replacements restore the previous folder. Successful replacements send the previous folder to the Recycle Bin, where it is available through Restore in the library. If recycling fails, the backup remains under the game's `.r5mm-backups` folder and its location is recorded in `error.log`.

Updates require an explicit install action. Installed-package receipts record source, version and commit for the selected game folder. The app does not install S21 packages into S3 or replace game scripts from legacy packages.
