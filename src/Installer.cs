using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace R5R {
    public interface IDirectoryMover { void Move(string source, string target); }
    public sealed class DirectoryMover : IDirectoryMover { public void Move(string source, string target) { Directory.Move(source, target); } }
    public sealed class InstallPlan {
        public PreparedPackage Package;
        public ModItem Metadata;
        public string Destination;
        public List<ModItem> Existing;
        public LibrarySnapshot Library;
    }
    public sealed class Installer {
        readonly IRecoveryService recovery;
        readonly IDirectoryMover mover;
        readonly Action<string> log;
        public Installer(IRecoveryService recovery, IDirectoryMover mover, Action<string> log) { this.recovery = recovery; this.mover = mover; this.log = log; }
        public InstallPlan Plan(string game, PreparedPackage package, CancellationToken token) {
            if (!Files.Inside(package.Path, game) || Files.IsLinkParent(package.Path, game)) throw new IOException("The prepared package must be staged on the game volume.");
            var name = Path.GetFileName(package.Path); ArchiveRules.CheckPart(name); var metadata = Vdf.Metadata(Path.Combine(package.Path, "mod.vdf"));
            if (String.IsNullOrWhiteSpace(metadata.Id)) throw new InvalidDataException("The mod manifest has no ID.");
            var library = LibraryService.Scan(game, null, token); if (!String.IsNullOrEmpty(library.StateError)) throw new IOException("Repair mods.vdf before installing mods.");
            var matches = library.Mods.Where(m => String.Equals(m.Id, metadata.Id, StringComparison.OrdinalIgnoreCase) || String.Equals(m.FolderName, name, StringComparison.OrdinalIgnoreCase)).ToList();
            return new InstallPlan { Package = package, Metadata = metadata, Library = library, Existing = matches, Destination = matches.Count > 0 ? matches[0].Folder : Path.Combine(library.ModsDir, name) };
        }
        public void Commit(InstallPlan plan, CancellationToken token) {
            token.ThrowIfCancellationRequested(); var game = plan.Library.GameDir; var stage = plan.Package.Path;
            if (!Files.Inside(plan.Destination, Path.Combine(game, "mods")) || Files.IsLinkParent(plan.Destination, game)) throw new IOException("Invalid mod destination.");
            Directory.CreateDirectory(plan.Library.ModsDir); var backups = new List<KeyValuePair<string, string>>(); bool published = false;
            var previousStates = new Dictionary<string, string>(plan.Library.States, StringComparer.OrdinalIgnoreCase);
            try {
                var replace = plan.Existing.Select(m => m.Folder).ToList(); if (Directory.Exists(plan.Destination) && !replace.Contains(plan.Destination, StringComparer.OrdinalIgnoreCase)) replace.Add(plan.Destination);
                foreach (var original in replace) {
                    token.ThrowIfCancellationRequested();
                    if (!Directory.Exists(original)) throw new IOException("The installed mod changed. Rescan the library before replacing it.");
                    var parent = Path.Combine(game, ".r5mm-backups", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(parent); var backup = Path.Combine(parent, Path.GetFileName(original));
                    mover.Move(original, backup); backups.Add(new KeyValuePair<string, string>(original, backup));
                }
                token.ThrowIfCancellationRequested(); mover.Move(stage, plan.Destination); published = true;
                plan.Library.States[plan.Metadata.Id] = "1"; plan.Library.Save();
            } catch (Exception originalError) {
                var rollbackErrors = new List<Exception>();
                if (published && Directory.Exists(plan.Destination)) try { mover.Move(plan.Destination, stage); } catch (Exception ex) { rollbackErrors.Add(ex); }
                foreach (var backup in backups.AsEnumerable().Reverse()) try { mover.Move(backup.Value, backup.Key); } catch (Exception ex) { rollbackErrors.Add(ex); if (log != null) log("Previous mod retained at " + backup.Value); }
                plan.Library.States = previousStates;
                if (rollbackErrors.Count > 0) { rollbackErrors.Insert(0, originalError); throw new AggregateException("Installation failed. A previous mod remains in .r5mm-backups; see error.log.", rollbackErrors); }
                throw;
            }
            foreach (var backup in backups) {
                try { recovery.Recycle(backup.Value); if (Directory.Exists(Path.GetDirectoryName(backup.Value)) && !Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(backup.Value)).Any()) Directory.Delete(Path.GetDirectoryName(backup.Value)); }
                catch (Exception ex) { if (log != null) log("Previous mod retained at " + backup.Value + ": " + ex.Message); }
            }
        }
    }
}
