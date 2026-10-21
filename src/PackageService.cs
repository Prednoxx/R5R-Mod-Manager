using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace R5R {
    public static class ArchiveRules {
        public static void CheckPart(string value) { if (String.IsNullOrEmpty(value) || value == "." || value == ".." || Regex.IsMatch(value, "[. ]$|[<>:\"|?*\\x00-\\x1F]") || Regex.IsMatch(value, "^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\\.|$)", RegexOptions.IgnoreCase)) throw new InvalidDataException("Package contains an invalid Windows file name."); }
        public static string Target(string root, string name) { name = name.Replace('\\', '/'); if (name.StartsWith("/") || name.Contains(":")) throw new InvalidDataException("Package contains an unsafe path."); foreach (var part in name.TrimEnd('/').Split('/')) CheckPart(part); var target = Path.GetFullPath(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar))); if (!Files.Inside(target, root)) throw new InvalidDataException("Package path escapes the staging folder."); return target; }
        public static void Extract(string archive, string destination, CancellationToken token) {
            using (var zip = ZipFile.OpenRead(archive)) {
                if (zip.Entries.Count > 20000) throw new InvalidDataException("Package contains too many files.");
                long expanded = 0; var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in zip.Entries) { token.ThrowIfCancellationRequested(); var target = Target(destination, entry.FullName); if (!paths.Add(target)) throw new InvalidDataException("Package contains duplicate Windows paths."); if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new InvalidDataException("Symbolic links cannot be installed."); expanded = checked(expanded + entry.Length); if (expanded > 4L * 1024 * 1024 * 1024) throw new InvalidDataException("Expanded package exceeds the 4 GB limit."); }
                foreach (var entry in zip.Entries) { token.ThrowIfCancellationRequested(); var target = Target(destination, entry.FullName); if (entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\")) Directory.CreateDirectory(target); else { Directory.CreateDirectory(Path.GetDirectoryName(target)); using (var input = entry.Open()) using (var output = File.Create(target)) { var buffer = new byte[65536]; int count; while ((count = input.Read(buffer, 0, buffer.Length)) > 0) { token.ThrowIfCancellationRequested(); output.Write(buffer, 0, count); } } } }
            }
        }
    }
    public sealed class PackageService {
        readonly INetwork network;
        public PackageService(INetwork network) { this.network = network; }
        public static bool GitBlob(string path, string expected) { using (var stream = File.OpenRead(path)) using (var sha = SHA1.Create()) { var header = Encoding.UTF8.GetBytes("blob " + stream.Length + "\0"); sha.TransformBlock(header, 0, header.Length, header, 0); var buffer = new byte[65536]; int count; while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) sha.TransformBlock(buffer, 0, count, buffer, 0); sha.TransformFinalBlock(new byte[0], 0, 0); return String.Equals(Files.Hex(sha.Hash), expected, StringComparison.OrdinalIgnoreCase); } }
        public async Task<PreparedPackage> Prepare(CatalogEntry entry, string stage, IProgress<PackageProgress> progress, CancellationToken token) {
            if (entry.Build != CatalogService.SupportedBuild) throw new InvalidDataException("This package targets a different game build.");
            if (!new[] { "zip", "github-directory" }.Contains(entry.InstallKind) || !Data.Match(entry.ModId, "^[A-Za-z0-9_.-]{1,100}$")) throw new InvalidDataException("Invalid installable mod listing.");
            Directory.CreateDirectory(stage); string modRoot;
            if (entry.InstallKind == "github-directory") {
                CatalogService.ValidateRepository(entry.Repository, entry.Commit, entry.PackagePath);
                var tree = Json.Decode<object>(await network.Text("https://api.github.com/repos/" + entry.Repository + "/git/trees/" + entry.Commit + "?recursive=1", token).ConfigureAwait(false));
                if (Data.Value(tree, "truncated") is bool && (bool)Data.Value(tree, "truncated")) throw new InvalidDataException("Repository listing is incomplete.");
                var prefix = entry.PackagePath.TrimEnd('/') + "/";
                var files = Data.Array(Data.Value(tree, "tree")).Where(f => Data.Text(f, "type") == "blob" && Data.Text(f, "path").StartsWith(prefix, StringComparison.Ordinal)).ToArray();
                if (files.Length == 0 || files.Length > 20000 || files.Sum(f => Data.Number(f, "size")) > 1073741824L) throw new InvalidDataException("Repository package exceeds the size limit.");
                modRoot = Path.Combine(stage, "repository-mod"); Directory.CreateDirectory(modRoot); long downloaded = 0; var total = files.Sum(f => Data.Number(f, "size")); var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var file in files) {
                    token.ThrowIfCancellationRequested(); var relative = Data.Text(file, "path").Substring(prefix.Length); var target = ArchiveRules.Target(modRoot, relative); var mode = Data.Text(file, "mode"); var sha = Data.Text(file, "sha");
                    if ((mode != "100644" && mode != "100755") || !Data.Match(sha, "^[a-f0-9]{40}$") || !names.Add(target)) throw new InvalidDataException("Repository contains an unsafe or duplicate file.");
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    if (progress != null) progress.Report(new PackageProgress("Downloading " + entry.Name + " — " + Path.GetFileName(target)) { Bytes = downloaded, Total = total });
                    await network.Download("https://raw.githubusercontent.com/" + entry.Repository + "/" + entry.Commit + "/" + Data.Text(file, "path"), target, Data.Number(file, "size") + 1, null, token).ConfigureAwait(false);
                    if (!GitBlob(target, sha)) throw new InvalidDataException("A repository file failed its integrity check."); downloaded += Data.Number(file, "size");
                }
            } else {
                var archive = Path.Combine(stage, "package.zip"); if (progress != null) progress.Report(new PackageProgress("Downloading " + entry.Name));
                await network.Download(entry.DownloadUrl, archive, 1073741824L, progress, token).ConfigureAwait(false);
                if (!String.IsNullOrEmpty(entry.Sha256) && !String.Equals(Files.HashFile(archive), entry.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Package checksum does not match the catalog.");
                var expanded = Path.Combine(stage, "expanded"); ArchiveRules.Extract(archive, expanded, token); var manifests = Files.Walk(expanded, "mod.vdf", 64, token).ToArray();
                if (manifests.Length != 1) throw new InvalidDataException("Package must contain exactly one mod.vdf."); modRoot = Path.GetDirectoryName(manifests[0]);
            }
            var manifest = Path.Combine(modRoot, "mod.vdf"); if (!File.Exists(manifest)) throw new InvalidDataException("Package has no mod.vdf."); var metadata = Vdf.Metadata(manifest);
            if (!String.Equals(metadata.Id, entry.ModId, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Package mod ID does not match the catalog.");
            if (!String.IsNullOrEmpty(entry.Version) && metadata.Version != entry.Version) throw new InvalidDataException("Package version does not match the catalog.");
            token.ThrowIfCancellationRequested(); var ready = Path.Combine(stage, "ready", entry.ModId); Directory.CreateDirectory(Path.GetDirectoryName(ready)); Directory.Move(modRoot, ready); return new PreparedPackage { Path = ready, ModId = metadata.Id, Version = metadata.Version };
        }
        public static List<PreparedPackage> PrepareLocal(string source, string game, string stage, CancellationToken token) {
            string root = source, fallback = Path.GetFileName(source.TrimEnd('\\'));
            if (Directory.Exists(source)) {
                if (String.Equals(Path.GetFullPath(source).TrimEnd('\\'), Path.GetFullPath(game).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) || String.Equals(Path.GetFullPath(source).TrimEnd('\\'), Path.Combine(Path.GetFullPath(game), "mods"), StringComparison.OrdinalIgnoreCase) || Files.Inside(source, Path.Combine(game, "mods"))) throw new IOException("Select a mod folder outside the installed mods directory.");
                if (Files.IsLinkParent(source, Path.GetPathRoot(source))) throw new IOException("Symbolic links and junctions cannot be installed.");
            } else {
                if (!String.Equals(Path.GetExtension(source), ".zip", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Install a ZIP archive or an extracted mod folder.");
                if (new FileInfo(source).Length > 1073741824L) throw new InvalidDataException("Package exceeds the 1 GB download limit.");
                root = Path.Combine(stage, "expanded"); ArchiveRules.Extract(source, root, token); fallback = Path.GetFileNameWithoutExtension(source);
            }
            var roots = new List<string>();
            foreach (var manifest in Files.Walk(root, "mod.vdf", 64, token).OrderBy(p => p.Length)) { var directory = Path.GetDirectoryName(manifest); if (!roots.Any(r => Files.Inside(directory, r))) roots.Add(directory); }
            if (roots.Count == 0) throw new InvalidDataException("No mod.vdf found in the selected package.");
            var result = new List<PreparedPackage>(); int index = 0;
            foreach (var directory in roots) { var name = String.Equals(directory.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? fallback : Path.GetFileName(directory); ArchiveRules.CheckPart(name); var metadata = Vdf.Metadata(Path.Combine(directory, "mod.vdf")); if (String.IsNullOrWhiteSpace(metadata.Id)) throw new InvalidDataException("The mod manifest has no ID."); var target = Path.Combine(stage, "local-" + index++, name); Files.CopyTree(directory, target, token); result.Add(new PreparedPackage { Path = target, ModId = metadata.Id, Version = metadata.Version }); }
            return result;
        }
    }
}
