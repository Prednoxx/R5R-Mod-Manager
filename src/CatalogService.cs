using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace R5R {
    public static class Data {
        public static Dictionary<string, object> Object(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static object Value(object value, string key) { object result; return Object(value).TryGetValue(key, out result) ? result : null; }
        public static string Text(object value, string key) { return Convert.ToString(Value(value, key)) ?? ""; }
        public static long Number(object value, string key) { long result; return Int64.TryParse(Text(value, key), out result) ? result : 0; }
        public static object[] Array(object value) { var list = value as IEnumerable; return list == null || value is string || value is IDictionary ? new object[0] : list.Cast<object>().ToArray(); }
        public static string[] Strings(object value) { return Array(value).Select(Convert.ToString).Where(s => !String.IsNullOrEmpty(s)).ToArray(); }
        public static bool Match(string value, string pattern) { return Regex.IsMatch(value ?? "", pattern, RegexOptions.CultureInvariant); }
    }
    public sealed class CatalogService {
        public const string SupportedBuild = "R5Reloaded S3";
        readonly AppPaths paths;
        readonly INetwork network;
        public CatalogService(AppPaths paths, INetwork network) { this.paths = paths; this.network = network; }
        public static string[] Categories(string value) { return (value ?? "").Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(s => s).ToArray(); }
        public SourceDocument Config() {
            var value = Json.Read<SourceDocument>(Path.Combine(paths.Root, "catalog", "sources.json"));
            if (value == null || value.SchemaVersion != 1 || value.Sources == null || value.Sources.Any(s => !Data.Match(s.Id, "^[A-Za-z0-9_.-]{1,100}$")) || value.Sources.Select(s => s.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != value.Sources.Count) throw new InvalidDataException("Invalid catalog source configuration.");
            return value;
        }
        public static CatalogEntry Entry(SourceConfig source, object raw) {
            var e = Json.Decode<CatalogEntry>(Json.Encode(raw));
            if (!Data.Match(e.Id, "^[A-Za-z0-9_.-]{1,100}$") || String.IsNullOrWhiteSpace(e.Name) || String.IsNullOrWhiteSpace(e.Build) || !Network.SafeUrl(e.PageUrl)) throw new InvalidDataException("A catalog listing has invalid metadata.");
            e.InstallKind = String.IsNullOrEmpty(e.InstallKind) ? "manual" : e.InstallKind;
            if (!new[] { "manual", "zip", "github-directory" }.Contains(e.InstallKind)) throw new InvalidDataException("Unsupported catalog package type.");
            if (e.InstallKind != "manual" && (!Data.Match(e.ModId, "^[A-Za-z0-9_.-]{1,100}$") || !Network.SafeUrl(e.DownloadUrl))) throw new InvalidDataException("An installable listing requires a valid mod ID and HTTPS package URL.");
            if (!String.IsNullOrEmpty(e.Sha256) && !Data.Match(e.Sha256, "^[a-fA-F0-9]{64}$")) throw new InvalidDataException("Invalid package checksum.");
            if (e.InstallKind == "github-directory") ValidateRepository(e.Repository, e.Commit, e.PackagePath);
            e.Key = source.Id + ":" + e.Id; e.SourceId = source.Id; e.Source = source.Name;
            e.Dependencies = e.Dependencies ?? new string[0]; e.PreviewUrls = (e.PreviewUrls ?? new string[0]).Where(Network.SafeUrl).ToArray(); return e;
        }
        public static void ValidateRepository(string repository, string commit, string path) {
            if (!Data.Match(repository, "^[\\w.-]+/[\\w.-]+$") || !Data.Match(commit, "^[a-f0-9]{40}$") || !Data.Match(path, "^[\\w./-]+$") || Data.Match(path, "(^|/)\\.\\.(/|$)") || path.StartsWith("/")) throw new InvalidDataException("Invalid GitHub package location.");
        }
        static void Merge(CatalogResult result, IEnumerable<CatalogEntry> entries, HashSet<string> seen) { foreach (var e in entries) { var key = String.IsNullOrEmpty(e.ModId) ? e.Key : e.Build + ":" + e.ModId; if (seen.Add(key)) result.Items.Add(e); } }
        public CatalogResult ReadCache() {
            var result = new CatalogResult(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var source in Config().Sources) {
                var snapshot = Json.Read<SourceSnapshot>(Path.Combine(paths.Cache, source.Id + ".json"));
                if (snapshot != null && snapshot.SchemaVersion == 1 && snapshot.Items != null) Merge(result, snapshot.Items, seen);
            }
            return result;
        }
        public async Task<CatalogResult> Sync(bool force, IProgress<string> progress, CancellationToken token) {
            var result = new CatalogResult(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var source in Config().Sources) {
                token.ThrowIfCancellationRequested(); var path = Path.Combine(paths.Cache, source.Id + ".json"); var snapshot = Json.Read<SourceSnapshot>(path);
                if (snapshot != null && (snapshot.SchemaVersion != 1 || snapshot.Items == null)) snapshot = null;
                var now = DateTime.UtcNow; DateTime next; bool due = snapshot == null || !DateTime.TryParse(snapshot.NextCheck, out next) || next.ToUniversalTime() <= now;
                string state = "Current", error = "";
                if (force || due || (source.Type == "feed" && !String.IsNullOrEmpty(source.Path))) {
                    if (progress != null) progress.Report("Updating " + source.Name);
                    try {
                        var items = await Retrieve(source, token).ConfigureAwait(false);
                        snapshot = new SourceSnapshot { SchemaVersion = 1, Updated = now.ToString("o"), NextCheck = now.AddMinutes(30).ToString("o"), Items = items, Error = "" }; Json.Write(path, snapshot);
                    } catch (OperationCanceledException) { throw; } catch (Exception ex) {
                        error = ex.Message; state = snapshot == null ? "Unavailable" : "Cached";
                        if (snapshot != null) { snapshot.NextCheck = now.AddMinutes(5).ToString("o"); snapshot.Error = error; Json.Write(path, snapshot); }
                    }
                } else if (!String.IsNullOrEmpty(snapshot.Error)) { state = "Cached"; error = snapshot.Error; }
                if (snapshot != null) Merge(result, snapshot.Items, seen);
                result.Sources.Add(new SourceState { Name = source.Name, State = state, Error = error, Count = snapshot == null ? 0 : snapshot.Items.Count, Updated = snapshot == null ? "" : snapshot.Updated });
            }
            result.Items = result.Items.OrderBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ToList(); return result;
        }
        async Task<List<CatalogEntry>> Retrieve(SourceConfig source, CancellationToken token) {
            if (source.Type == "feed") {
                string text;
                if (!String.IsNullOrEmpty(source.Url)) text = await network.Text(source.Url, token).ConfigureAwait(false);
                else { var root = Path.Combine(paths.Root, "catalog"); var path = Path.GetFullPath(Path.Combine(root, source.Path ?? "")); if (!Files.Inside(path, root)) throw new InvalidDataException("Invalid catalog feed path."); text = File.ReadAllText(path); }
                var feed = Json.Decode<Dictionary<string, object>>(text);
                if (Data.Number(feed, "schemaVersion") != 1 || !feed.ContainsKey("mods")) throw new InvalidDataException("Invalid catalog feed.");
                return Data.Array(feed["mods"]).Select(item => Entry(source, item)).ToList();
            }
            if (source.Type == "thunderstore") {
                var packages = Json.Decode<object[]>(await network.Text(source.Url, token).ConfigureAwait(false)); var list = new List<CatalogEntry>();
                foreach (var package in packages) {
                    if (Data.Value(package, "is_deprecated") is bool && (bool)Data.Value(package, "is_deprecated")) continue;
                    var versions = Data.Array(Data.Value(package, "versions")); var version = versions.FirstOrDefault(v => !(Data.Value(v, "is_active") is bool) || (bool)Data.Value(v, "is_active")); if (version == null) continue;
                    var owner = Data.Text(package, "owner"); var name = Data.Text(package, "name"); if (owner.Length == 0 || name.Length == 0) throw new InvalidDataException("Invalid Thunderstore response.");
                    list.Add(Entry(source, new { id = owner + "." + name, modId = owner + "." + name, name = name, author = owner, description = Data.Text(version, "description"), version = Data.Text(version, "version_number"), category = String.Join(", ", Data.Strings(Data.Value(package, "categories"))), build = source.Build, pageUrl = Data.Text(package, "package_url"), installKind = "zip", downloadUrl = Data.Text(version, "download_url"), updated = Data.Text(package, "date_updated"), size = Data.Number(version, "file_size"), downloads = versions.Sum(v => Data.Number(v, "downloads")), dependencies = Data.Strings(Data.Value(version, "dependencies")), iconUrl = Data.Text(version, "icon") }));
                }
                return list;
            }
            if (source.Type != "github-tree" || !Data.Match(source.Repository, "^[\\w.-]+/[\\w.-]+$") || !Data.Match(source.Root, "^[\\w/-]+$")) throw new InvalidDataException("Unsupported or invalid catalog provider.");
            var entries = new List<CatalogEntry>(); var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var reference in source.Refs ?? new string[0]) {
                var branch = Json.Decode<object>(await network.Text("https://api.github.com/repos/" + source.Repository + "/branches/" + Uri.EscapeDataString(reference), token).ConfigureAwait(false));
                var commit = Data.Text(Data.Value(branch, "commit"), "sha"); if (!Data.Match(commit, "^[a-f0-9]{40}$")) throw new InvalidDataException("Invalid repository revision.");
                var tree = Json.Decode<object>(await network.Text("https://api.github.com/repos/" + source.Repository + "/git/trees/" + commit + "?recursive=1", token).ConfigureAwait(false));
                if (Data.Value(tree, "truncated") is bool && (bool)Data.Value(tree, "truncated")) throw new InvalidDataException("Repository listing is incomplete.");
                var files = Data.Array(Data.Value(tree, "tree")); var pattern = "^" + Regex.Escape(source.Root) + "/([^/]+)/mod\\.vdf$";
                foreach (var file in files.Where(f => Data.Text(f, "type") == "blob" && Data.Match(Data.Text(f, "path"), pattern))) {
                    var filePath = Data.Text(file, "path"); var raw = await network.Text("https://raw.githubusercontent.com/" + source.Repository + "/" + commit + "/" + filePath, token).ConfigureAwait(false); var metadata = Vdf.MetadataText(raw);
                    if (String.IsNullOrEmpty(metadata.Id) || !ids.Add(metadata.Id)) continue;
                    var packagePath = filePath.Substring(0, filePath.LastIndexOf('/')); var artwork = files.Select(f => Data.Text(f, "path")).FirstOrDefault(p => Data.Match(p, "^" + Regex.Escape(packagePath) + "/(preview|screenshot|icon)\\.(png|jpg|jpeg)$"));
                    entries.Add(Entry(source, new { id = metadata.Id, modId = metadata.Id, name = metadata.Name, author = metadata.Author, description = metadata.Description, version = metadata.Version, build = source.Build, category = source.Category, installKind = "github-directory", repository = source.Repository, commit = commit, packagePath = packagePath, pageUrl = "https://github.com/" + source.Repository + "/tree/" + reference + "/" + packagePath, downloadUrl = "https://codeload.github.com/" + source.Repository + "/zip/" + commit, previewUrls = artwork == null ? new string[0] : new[] { "https://raw.githubusercontent.com/" + source.Repository + "/" + commit + "/" + artwork } }));
                }
            }
            return entries;
        }
        public static string Status(CatalogEntry entry, LibrarySnapshot library, IDictionary<string, Receipt> receipts) {
            if (entry.Build != SupportedBuild) return entry.Build;
            var installed = library == null ? null : library.Find(entry.ModId);
            if (installed == null) return entry.InstallKind == "manual" ? "Manual install" : "Available";
            Version remote, local;
            if (!String.IsNullOrEmpty(entry.Version) && !String.IsNullOrEmpty(installed.Version)) {
                if (Version.TryParse(entry.Version, out remote) && Version.TryParse(installed.Version, out local)) { if (remote > local) return "Update available"; if (remote < local) return "Newer installed"; }
                else if (entry.Version != installed.Version) return "Different version";
            }
            Receipt receipt; if (receipts.TryGetValue(entry.ModId ?? "", out receipt) && String.Equals(receipt.GameDir, library.GameDir, StringComparison.OrdinalIgnoreCase) && receipt.Key == entry.Key && !String.IsNullOrEmpty(entry.Commit) && receipt.Commit != entry.Commit) return "Update available";
            return "Installed";
        }
        public static List<CatalogEntry> Filter(IEnumerable<CatalogEntry> source, string query, string build, string provider, string category, ISet<string> favorites) {
            return source.Where(e => (String.IsNullOrEmpty(build) || e.Build == build) && (String.IsNullOrEmpty(provider) || e.Source == provider) && (String.IsNullOrEmpty(category) || Categories(e.Category).Contains(category, StringComparer.OrdinalIgnoreCase)) && (favorites == null || favorites.Contains(e.Key)) && (String.IsNullOrWhiteSpace(query) || String.Join(" ", new[] { e.Name, e.Author, e.Description, e.ModId }).IndexOf(query.Trim(), StringComparison.OrdinalIgnoreCase) >= 0)).ToList();
        }
    }
}
