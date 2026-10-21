# Application structure

The application is a C# WPF executable targeting .NET Framework 4.8. WPF resources and layouts are stored in `ui`; game data and publisher catalog configuration remain ordinary files.

| Component | Responsibility |
| --- | --- |
| `Program` | Application lifetime, instance ownership and startup errors |
| `MainWindowController`, `StoreView`, `LibraryView`, `InstallView` | Navigation, input, dialogs and operation state |
| `CatalogService`, `Network` | Provider indexing, HTTPS requests, ETags, snapshots and source failure recovery |
| `PackageService`, `ArchiveRules` | Package staging, archive validation and integrity checks |
| `Installer` | Replacement planning, same-volume publication, state persistence and rollback |
| `LibraryService`, `Vdf` | Mod metadata, switch files, dependency analysis and presets |
| `MediaService` | Publisher descriptions, validated artwork and image caching |
| `WindowsRecovery`, `NativeShell` | Recycle Bin recovery, folder selection and source links |
| `Storage`, `Models`, `ThemeService` | Atomic persistence, typed data, bindings and appearance |

Network requests, scanning and package preparation run asynchronously outside the dispatcher. UI state is updated through the WPF synchronization context. Dialogs use task completion instead of nested dispatcher loops. Closing the application cancels background work and waits for active operations to release their resources.

Downloads stage on the selected game volume. The installer plans against a fresh library scan, confirms replacements, moves existing folders to named backups, publishes the prepared folder and saves the switch file atomically. A failure restores the previous folders. Successful replacements send backups to the Windows Recycle Bin; failed recycling leaves the backup path in `error.log`.

Settings and cache models accept the existing JSON field names. A settings backup is created before the first migrated save. No game files are modified by scanning or settings migration.

The build helper and regression tests are also written in C#. The portable package contains no application scripts or scripting-engine dependency.
