using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace R5R.Tests {
    internal static partial class TestRunner {
        static async Task PackageTests() {
            foreach (var name in new[] { "../outside", "..\\outside", "/absolute", "C:/drive", "safe/file:stream", "CON.txt", "safe/trailing.", "safe/trailing ", "safe/../escape", "safe/./file", "safe/file?" }) { var root = Area("unsafe-archive"); var zip = Path.Combine(root, "package.zip"); Zip(zip, new[] { name }, "test"); Throws(() => ArchiveRules.Extract(zip, Path.Combine(root, "expanded"), None), "Archive rejects " + name); }
            {
                var root = Area("duplicate-archive"); var zip = Path.Combine(root, "package.zip"); Zip(zip, new[] { "safe/file.txt", "SAFE/FILE.TXT" }, "test"); Throws(() => ArchiveRules.Extract(zip, Path.Combine(root, "expanded"), None), "Archive rejects duplicate Windows paths");
            }
            {
                var root = Area("symlink-archive"); var zip = Path.Combine(root, "package.zip"); using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create)) { var entry = archive.CreateEntry("linked"); entry.ExternalAttributes = unchecked((int)0xA0000000); } Throws(() => ArchiveRules.Extract(zip, Path.Combine(root, "expanded"), None), "Archive rejects symbolic link entries");
            }
            var area = Area("packages"); var game = Game(area); var zipPath = Path.Combine(area, "valid.zip"); Zip(zipPath, new[] { "Wrapped/mod.vdf" }, "mod { id Fixture.Mod name Fixture version 1.0 }");
            var network = new FakeNetwork(); var entryValid = Listing("Fixture.Mod", "Map"); network.Downloads[entryValid.DownloadUrl] = File.ReadAllBytes(zipPath); var packages = new PackageService(network);
            var package = await packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-valid"), null, None); Check(Vdf.Metadata(Path.Combine(package.Path, "mod.vdf")).Id == "Fixture.Mod", "ZIP preparation supports wrapper folders and validates metadata");
            entryValid.Sha256 = Files.HashFile(zipPath); package = await packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-checksum"), null, None); Check(Directory.Exists(package.Path), "Pinned ZIP checksums are accepted when the package matches");
            entryValid.Sha256 = new string('0', 64); Throws(() => packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-bad-hash"), null, None).GetAwaiter().GetResult(), "Mismatched ZIP checksums are rejected"); entryValid.Sha256 = null;
            entryValid.ModId = "Wrong.Mod"; Throws(() => packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-bad-id"), null, None).GetAwaiter().GetResult(), "Package manifest IDs must match the listing"); entryValid.ModId = "Fixture.Mod"; entryValid.Version = "2.0"; Throws(() => packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-bad-version"), null, None).GetAwaiter().GetResult(), "Package versions must match the listing"); entryValid.Version = "1.0";
            entryValid.Build = "Flowstate S21"; Throws(() => packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-bad-build"), null, None).GetAwaiter().GetResult(), "S21 package installation is rejected for an S3 game"); entryValid.Build = CatalogService.SupportedBuild;
            var multiple = Path.Combine(area, "multiple.zip"); Zip(multiple, new[] { "One/mod.vdf", "Two/mod.vdf" }, "mod { id Fixture.Mod name Fixture version 1.0 }"); network.Downloads[entryValid.DownloadUrl] = File.ReadAllBytes(multiple); Throws(() => packages.Prepare(entryValid, Path.Combine(game, ".r5mm-stage-multiple"), null, None).GetAwaiter().GetResult(), "Store packages require exactly one mod manifest");
            network.Downloads[entryValid.DownloadUrl] = File.ReadAllBytes(zipPath); var cancellation = new CancellationTokenSource(); var cancelledStage = Path.Combine(game, ".r5mm-stage-cancelled"); Throws(() => packages.Prepare(entryValid, cancelledStage, new InlineProgress<PackageProgress>(p => { if (p.Bytes > 0) cancellation.Cancel(); }), cancellation.Token).GetAwaiter().GetResult(), "Cancelling a package prevents preparation from publishing it"); Files.RemoveStage(cancelledStage, game); Check(!Directory.Exists(cancelledStage), "Cancelled package staging can be removed safely");
            var local = Mod(area, "Local.Mod", "Local.Mod", "1.0"); var localMods = PackageService.PrepareLocal(local, game, Path.Combine(game, ".r5mm-stage-local"), None); Check(localMods.Single().ModId == "Local.Mod" && File.Exists(Path.Combine(local, "mod.vdf")), "Local folder staging leaves the source mod intact");
            var localZip = PackageService.PrepareLocal(zipPath, game, Path.Combine(game, ".r5mm-stage-local-zip"), None); Check(localZip.Single().ModId == "Fixture.Mod", "Local ZIP installation shares archive validation");
            Mod(Path.Combine(game, "mods"), "Already", "Already", "1.0"); Throws(() => PackageService.PrepareLocal(Path.Combine(game, "mods", "Already"), game, Path.Combine(game, ".r5mm-stage-already"), None), "Already installed source folders cannot install onto themselves");
            Throws(() => PackageService.PrepareLocal(game, game, Path.Combine(game, ".r5mm-stage-game"), None), "The entire game folder cannot be installed as a mod");
            Throws(() => PackageService.PrepareLocal(Path.Combine(area, "archive.rar"), game, Path.Combine(game, ".r5mm-stage-rar"), None), "Unsupported local archive formats are rejected");
            await RepositoryPackageTests();
        }
        static string GitHash(byte[] data) { using (var sha = SHA1.Create()) { var header = Encoding.UTF8.GetBytes("blob " + data.Length + "\0"); var all = header.Concat(data).ToArray(); return Files.Hex(sha.ComputeHash(all)).ToLowerInvariant(); } }
        static async Task RepositoryPackageTests() {
            var root = Area("repository-package"); var game = Game(root); var network = new FakeNetwork(); var entry = Listing("Fixture.Mod", "Map"); entry.InstallKind = "github-directory"; entry.Repository = "owner/repo"; entry.Commit = new string('a', 40); entry.PackagePath = "defaults/mods/Fixture";
            var bytes = Encoding.UTF8.GetBytes("mod { id Fixture.Mod name Fixture version 1.0 }"); var treeUrl = "https://api.github.com/repos/owner/repo/git/trees/" + entry.Commit + "?recursive=1"; var fileUrl = "https://raw.githubusercontent.com/owner/repo/" + entry.Commit + "/" + entry.PackagePath + "/mod.vdf";
            network.Texts[treeUrl] = Json.Encode(new { truncated = false, tree = new[] { new { type = "blob", mode = "100644", path = entry.PackagePath + "/mod.vdf", sha = GitHash(bytes), size = bytes.Length } } }); network.Downloads[fileUrl] = bytes;
            var service = new PackageService(network); var prepared = await service.Prepare(entry, Path.Combine(game, ".r5mm-stage-repository"), null, None); Check(prepared.ModId == "Fixture.Mod", "Repository packages verify Git blob hashes before publication"); Check(PackageService.GitBlob(Path.Combine(prepared.Path, "mod.vdf"), GitHash(bytes)), "Git blob verification includes the Git object header");
            network.Downloads[fileUrl] = Encoding.UTF8.GetBytes("tampered file"); Throws(() => service.Prepare(entry, Path.Combine(game, ".r5mm-stage-tampered"), null, None).GetAwaiter().GetResult(), "Tampered repository files fail integrity verification"); network.Downloads[fileUrl] = bytes;
            network.Texts[treeUrl] = Json.Encode(new { truncated = false, tree = new[] { new { type = "blob", mode = "120000", path = entry.PackagePath + "/mod.vdf", sha = GitHash(bytes), size = bytes.Length } } }); Throws(() => service.Prepare(entry, Path.Combine(game, ".r5mm-stage-link"), null, None).GetAwaiter().GetResult(), "Repository symbolic-link modes are rejected");
            network.Texts[treeUrl] = Json.Encode(new { truncated = true, tree = new object[0] }); Throws(() => service.Prepare(entry, Path.Combine(game, ".r5mm-stage-truncated"), null, None).GetAwaiter().GetResult(), "Truncated repository trees are rejected");
        }
    }
}
