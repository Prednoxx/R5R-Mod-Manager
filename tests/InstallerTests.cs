using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace R5R.Tests {
    internal static partial class TestRunner {
        static void InstallerTests() {
            var root = Area("installer"); var game = Game(root); var recovery = new TestRecovery(Path.Combine(root, "recovery")); var logs = new List<string>(); var service = new Installer(recovery, new DirectoryMover(), logs.Add);
            var first = Prepared(game, "OriginalFolder", "Fixture.Mod", "1.0"); var plan = service.Plan(game, first, None); Check(plan.Existing.Count == 0, "New package plans do not require replacement confirmation"); service.Commit(plan, None); var original = Path.Combine(game, "mods", "OriginalFolder"); Check(Directory.Exists(original) && !Directory.Exists(first.Path), "Prepared mods publish through a same-volume directory move");
            var library = LibraryService.Scan(game, null, None); Check(library.Find("Fixture.Mod").Enabled && library.States["Fixture.Mod"] == "1", "Newly installed mods are enabled in mods.vdf");
            var second = Prepared(game, "DifferentPackageFolder", "Fixture.Mod", "2.0"); plan = service.Plan(game, second, None); Check(plan.Existing.Single().Version == "1.0" && plan.Destination == original, "Replacement plans preserve the installed folder name by mod ID");
            Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "1.0" && Directory.Exists(second.Path), "Preparing a replacement leaves the installed copy unchanged"); service.Commit(plan, None); Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "2.0", "Confirmed replacements install the new version"); Check(recovery.Saved.Count == 1 && Vdf.Metadata(Path.Combine(recovery.Saved[0], "mod.vdf")).Version == "1.0", "Successful replacements retain the complete previous mod for recovery");
            bool managed; Check(WindowsRecovery.Origin(game, "OriginalFolder", Path.GetDirectoryName(recovery.Originals[0]), out managed) && managed, "Replacement backups are discoverable by their original folder name"); Check(!WindowsRecovery.Origin(game, "OriginalFolder", root, out managed), "Recovery excludes unrelated Recycle Bin folders"); Check(!WindowsRecovery.Origin(game, "..\\outside", Path.Combine(game, "mods"), out managed), "Recovery rejects names outside the mod directory");
            var third = Prepared(game, "Candidate", "Fixture.Mod", "3.0"); var cancelled = new System.Threading.CancellationTokenSource(); cancelled.Cancel(); Throws(() => service.Commit(service.Plan(game, third, None), cancelled.Token), "Cancelled transactions do not start publication"); Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "2.0", "Cancellation preserves the installed version");
            foreach (int failure in new[] { 1, 2 }) {
                var candidate = Prepared(game, "Failure" + failure, "Fixture.Mod", "3.0"); var faulty = new Installer(recovery, new FaultMover(failure), logs.Add); var failedPlan = faulty.Plan(game, candidate, None); Throws(() => faulty.Commit(failedPlan, None), failure == 1 ? "Backup move failures are reported" : "Publish move failures are reported");
                Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "2.0" && Directory.Exists(candidate.Path), failure == 1 ? "Failed backup moves never remove the untouched original" : "Failed publishing restores the previous folder and preserves the candidate");
            }
            {
                var statePath = Path.Combine(game, "mods", "mods.vdf"); var state = File.ReadAllText(statePath); File.SetAttributes(statePath, FileAttributes.ReadOnly); var candidate = Prepared(game, "StateFailure", "Fixture.Mod", "3.0");
                try { Throws(() => service.Commit(service.Plan(game, candidate, None), None), "Switch-file write failure aborts the replacement transaction"); Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "2.0" && File.ReadAllText(statePath) == state, "Switch-file failure restores both mod files and the original configuration"); }
                finally { File.SetAttributes(statePath, FileAttributes.Normal); }
            }
            {
                var failureRoot = Area("rollback-failure"); var failureGame = Game(failureRoot); var current = Mod(Path.Combine(failureGame, "mods"), "Current", "Current.Mod", "1.0"); var candidate = Prepared(failureGame, "Next", "Current.Mod", "2.0"); var failed = new Installer(new TestRecovery(Path.Combine(failureRoot, "recovery")), new FaultMover(2, 3), logs.Add); Throws(() => failed.Commit(failed.Plan(failureGame, candidate, None), None), "Rollback failures report retained backup locations"); Check(Directory.GetFiles(Path.Combine(failureGame, ".r5mm-backups"), "mod.vdf", SearchOption.AllDirectories).Length == 1 && logs.Any(l => l.Contains("Previous mod retained")), "Failed rollback never discards the previous mod backup");
            }
            recovery.Fail = true; var next = Prepared(game, "RecycleFailure", "Fixture.Mod", "4.0"); service.Commit(service.Plan(game, next, None), None); Check(Vdf.Metadata(Path.Combine(original, "mod.vdf")).Version == "4.0", "Recycle Bin failure does not undo a successful installation"); Check(Directory.GetFiles(Path.Combine(game, ".r5mm-backups"), "mod.vdf", SearchOption.AllDirectories).Length >= 1, "Unrecycled backups remain available on disk");
            var outside = Mod(root, "Outside", "Outside.Mod", "1.0"); Throws(() => service.Plan(game, new PreparedPackage { Path = outside }, None), "Publication rejects unstaged packages outside the game volume");
        }
        static async Task RecycleTests() {
            var root = Area("windows-recycle"); var game = Game(root); var parent = Path.Combine(game, ".r5mm-backups", Guid.NewGuid().ToString("N")); var original = Mod(parent, "RecoveryFixture", "Recovery.Fixture", "1.0"); var recovery = new WindowsRecovery(); recovery.Recycle(original);
            var entry = recovery.List(game).FirstOrDefault(e => e.Name == "RecoveryFixture"); Check(entry != null && entry.ManagedBackup, "Windows Recycle Bin exposes replacement backups");
            await recovery.Restore(entry, game, None); Check(Vdf.Metadata(Path.Combine(game, "mods", "RecoveryFixture", "mod.vdf")).Id == "Recovery.Fixture", "Windows replacement recovery restores the manifest into the mods directory");
        }
    }
}
