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
    internal sealed class FakeNetwork : INetwork {
        public readonly Dictionary<string, string> Texts = new Dictionary<string, string>();
        public readonly Dictionary<string, byte[]> Downloads = new Dictionary<string, byte[]>();
        public readonly List<string> Requests = new List<string>();
        public Task<string> Text(string url, CancellationToken token) { token.ThrowIfCancellationRequested(); Requests.Add(url); string text; if (!Texts.TryGetValue(url, out text)) throw new IOException("Source unavailable."); return Task.FromResult(text); }
        public Task Download(string url, string path, long limit, IProgress<PackageProgress> progress, CancellationToken token) {
            token.ThrowIfCancellationRequested(); Requests.Add(url); byte[] data; if (!Downloads.TryGetValue(url, out data)) throw new IOException("Package unavailable."); if (data.Length > limit) throw new InvalidDataException("Download exceeds the size limit.");
            Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllBytes(path, data); if (progress != null) progress.Report(new PackageProgress("Downloading") { Bytes = data.Length, Total = data.Length }); token.ThrowIfCancellationRequested(); return Task.FromResult(true);
        }
    }
    internal sealed class InlineProgress<T> : IProgress<T> { readonly Action<T> action; public InlineProgress(Action<T> action) { this.action = action; } public void Report(T value) { action(value); } }
    internal sealed class TestRecovery : IRecoveryService {
        readonly string root; public bool Fail; public readonly List<string> Originals = new List<string>(); public readonly List<string> Saved = new List<string>();
        public TestRecovery(string root) { this.root = root; Directory.CreateDirectory(root); }
        public void Recycle(string path) { if (Fail) throw new IOException("Recycle unavailable."); var target = Path.Combine(root, Guid.NewGuid().ToString("N")); Directory.Move(path, target); Originals.Add(path); Saved.Add(target); }
        public List<RecycledMod> List(string game) { return new List<RecycledMod>(); }
        public Task Restore(RecycledMod item, string game, CancellationToken token) { throw new NotSupportedException(); }
    }
    internal sealed class FaultMover : IDirectoryMover {
        readonly HashSet<int> failures; int calls;
        public FaultMover(params int[] failures) { this.failures = new HashSet<int>(failures); }
        public void Move(string source, string target) { if (failures.Contains(++calls)) throw new IOException("Simulated move failure."); Directory.Move(source, target); }
    }
    internal static partial class TestRunner {
        static string sandbox, appRoot; static int passed;
        static readonly CancellationToken None = CancellationToken.None;
        static void Check(bool value, string name) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
        static void Throws(Action action, string name) { bool thrown = false; try { action(); } catch { thrown = true; } Check(thrown, name); }
        static string Area(string name) { var path = Path.Combine(sandbox, name + "-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path); return path; }
        static string Mod(string root, string folder, string id, string version) { var path = Path.Combine(root, folder); Directory.CreateDirectory(path); File.WriteAllText(Path.Combine(path, "mod.vdf"), "\"mod\" { \"id\" " + Vdf.Quote(id) + " \"name\" " + Vdf.Quote(folder) + " \"version\" " + Vdf.Quote(version) + " }"); return path; }
        static string Game(string root) { var path = Path.Combine(root, "game"); Directory.CreateDirectory(path); File.WriteAllText(Path.Combine(path, "r5apex.exe"), ""); return path; }
        static CatalogEntry Listing(string id, string category) { return CatalogService.Entry(new SourceConfig { Id = "fixture", Name = "Fixture" }, new { id = id, modId = id, name = id, author = "Publisher", description = "Practice map", version = "1.0", build = CatalogService.SupportedBuild, category = category, pageUrl = "https://example.org/mod", installKind = "zip", downloadUrl = "https://example.org/mod.zip" }); }
        static void Zip(string path, string[] names, string text) { using (var archive = ZipFile.Open(path, ZipArchiveMode.Create)) foreach (var name in names) using (var output = new StreamWriter(archive.CreateEntry(name).Open())) output.Write(text); }
        static PreparedPackage Prepared(string game, string folder, string id, string version) { var root = Path.Combine(game, ".r5mm-stage-" + Guid.NewGuid().ToString("N")); var path = Mod(Path.Combine(root, "ready"), folder, id, version); return new PreparedPackage { Path = path, ModId = id, Version = version }; }
        [STAThread] public static int Main(string[] args) {
            appRoot = AppDomain.CurrentDomain.BaseDirectory; sandbox = AreaRoot();
            try {
                StorageTests(); VdfTests(); LibraryTests(); CatalogTests().GetAwaiter().GetResult(); PackageTests().GetAwaiter().GetResult(); InstallerTests(); MediaTests().GetAwaiter().GetResult(); UiTests(); LifecycleTests();
                if (args.Contains("--live")) LiveTests().GetAwaiter().GetResult();
                if (args.Contains("--recycle")) RecycleTests().GetAwaiter().GetResult();
                Check(!typeof(Program).Assembly.GetReferencedAssemblies().Any(a => a.Name.IndexOf("Management.Automation", StringComparison.OrdinalIgnoreCase) >= 0), "Application has no scripting-engine dependency");
                Console.WriteLine(passed + " checks passed."); return 0;
            } catch (Exception ex) { Console.Error.WriteLine(ex.ToString()); return 1; }
            finally { if (Files.Inside(sandbox, Path.GetTempPath()) && Path.GetFileName(sandbox).StartsWith("r5mm-csharp-tests-")) { foreach (var file in Directory.GetFiles(sandbox, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal); Directory.Delete(sandbox, true); } }
        }
        static string AreaRoot() { var path = Path.Combine(Path.GetTempPath(), "r5mm-csharp-tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path); return path; }
        static void StorageTests() {
            var root = Area("settings"); var paths = new AppPaths(appRoot, root); var file = Path.Combine(root, "settings.json");
            File.WriteAllText(file, "{\"GameDir\":\"C:\\\\Games\\\\R5Reloaded\",\"Theme\":\"aero_night\",\"ActivePreset\":\"Practice\",\"StoreLayoutVersion\":1,\"Presets\":{\"Practice\":{\"My.Mod\":\"0\"}},\"ConVarCache\":{\"My.Mod\":[\"example\"]}}");
            var settings = AppSettings.Load(paths); Check(settings.Theme == "aero_night" && settings.Presets["practice"]["my.mod"] == "0", "Existing settings and preset keys migrate without case changes"); Check(settings.ConVarCache["my.mod"].Single() == "example", "Existing dependency cache is preserved"); Check(File.Exists(file + ".pre-3.3.bak"), "Existing settings are backed up before migration");
            var backup = File.ReadAllText(file + ".pre-3.3.bak"); settings.Theme = "obsidian"; settings.Save(paths); settings = AppSettings.Load(paths); Check(settings.Theme == "obsidian", "Settings round-trip through atomic storage"); Check(File.ReadAllText(file + ".pre-3.3.bak") == backup, "Migration backup is not replaced on later launches");
            var cache = Path.Combine(root, "cache.json"); Json.Write(cache, new { count = 1 }); Json.Write(cache, new { count = 2 }); Check(Data.Number(Json.Read<object>(cache), "count") == 2, "Atomic cache replacement keeps the completed document");
            File.WriteAllText(cache, "{invalid"); Check(Json.Read<object>(cache) == null, "Corrupt JSON cache is recoverable");
            var lower = Json.Decode<SourceDocument>("{\"schemaVersion\":1,\"sources\":[{\"id\":\"one\",\"name\":\"One\",\"type\":\"feed\"}]}"); Check(lower.SchemaVersion == 1 && lower.Sources[0].Id == "one", "Existing lowercase catalog JSON maps to typed models");
            Check(Network.SafeUrl("https://example.org/mod.zip"), "HTTPS source URL is accepted"); Check(!Network.SafeUrl("http://example.org/mod.zip"), "HTTP source URL is rejected"); Check(!Network.SafeUrl("https://user:password@example.org"), "Embedded source credentials are rejected"); Check(!Network.SafeUrl("file:///C:/mod.zip"), "Local file URLs are rejected as remote sources");
            Check(Files.Inside(Path.Combine(root, "child"), root) && !Files.Inside(root + "-other", root), "Path containment distinguishes sibling directories");
            Throws(() => Files.RemoveStage(root, root), "Staging cleanup rejects the game root");
        }
        static void VdfTests() {
            var text = "// comment\n\"mod\" { \"ID\" \"Example.Mod\" \"Name\" \"Practice \\\"Room\\\"\" \"description\" \"Line 1\\nLine 2\" \"ConVars\" { \"example_value\" \"1\" } \"Dependencies\" { \"Core.Mod\" \"1\" \"Ignored\" \"0\" } }";
            var metadata = Vdf.MetadataText(text); Check(metadata.Id == "Example.Mod" && metadata.Name == "Practice \"Room\"", "VDF parser supports comments and escaped quoted strings"); Check(metadata.Description == "Line 1\nLine 2", "VDF descriptions retain line breaks"); Check(metadata.ConVars.Single() == "example_value" && metadata.Deps.Single() == "Core.Mod", "ConVars and enabled dependencies are parsed");
            Check(Vdf.MetadataText("mod { id Bare.Name name Practice }").Id == "Bare.Name", "VDF parser supports bare tokens"); Check(Vdf.MetadataText("mod { id Test name \"Room\" [$WIN32] }").Name == "Room", "VDF platform conditions do not become metadata keys");
            Throws(() => Vdf.Parse("mod { id \"Unclosed"), "Unterminated VDF strings are rejected"); Throws(() => Vdf.Parse("mod { id Test"), "Missing VDF closing braces are rejected"); Throws(() => Vdf.Parse("}"), "Unexpected VDF closing braces are rejected");
            var states = new Dictionary<string, string> { { "Quoted\"Id", "0" }, { "Path\\Id", "1" } }; var roundTrip = Vdf.Parse(Vdf.WriteSwitches("ModList", states)); var saved = (Dictionary<string, object>)roundTrip["ModList"]; Check((string)saved["Quoted\"Id"] == "0" && (string)saved["Path\\Id"] == "1", "Switch writer escapes identifiers before saving VDF");
        }
        static void LibraryTests() {
            var root = Area("library"); var game = Game(root); var mods = Path.Combine(game, "mods"); var owner = Mod(mods, "Owner", "Owner.Mod", "1.0"); var client = Mod(mods, "Client", "Client.Mod", "1.0"); Mod(mods, "Flowstate", "Flowstate", "1.0");
            File.WriteAllText(Path.Combine(owner, "mod.vdf"), "mod { id Owner.Mod name Owner ConVars { needed 1 } }"); File.WriteAllText(Path.Combine(client, "asset.rpak"), "\"needed\"" + new string('x', 2 * 1024 * 1024));
            var before = Directory.GetFiles(mods, "*", SearchOption.AllDirectories).Length; var library = LibraryService.Scan(game, null, None); Check(library.Mods.Count == 3 && library.Mods.All(m => m.Enabled), "Library scan defaults unlisted mods to enabled"); Check(library.Find("Client.Mod").Dependencies.Length == 0, "Binary assets are excluded from dependency scanning"); Check(!File.Exists(Path.Combine(mods, "mods.vdf")) && before == Directory.GetFiles(mods, "*", SearchOption.AllDirectories).Length, "Scanning does not change game files or switches");
            File.WriteAllText(Path.Combine(client, "client.gnut"), "GetConVarInt(\"needed\")"); library = LibraryService.Scan(game, null, None); Check(library.Find("Client.Mod").Dependencies.Contains("Owner.Mod"), "Squirrel scripts identify dependencies on other mods");
            library.SetAll(false); Check(library.Find("Flowstate").Enabled && !library.Find("Client.Mod").Enabled, "Disable all preserves required game mods"); library.Save(); Check(File.ReadAllText(Path.Combine(mods, "mods.vdf")).Contains("\"Client.Mod\""), "Mod switches are saved to the game VDF");
            library.SetEnabled(library.Find("Client.Mod"), true); library.Save(); Check(File.Exists(Path.Combine(mods, "mods.vdf.bak")), "First switch replacement retains the original VDF backup");
            var preset = library.Snapshot(); Check(!preset.ContainsKey("Flowstate"), "Presets exclude required game mods"); library.SetEnabled(library.Find("Client.Mod"), false); Check(library.Diff(preset), "Preset differences are detected"); library.Apply(preset); Check(library.Find("Client.Mod").Enabled && !library.Diff(preset), "Saved preset restores optional mod switches");
            library.Save(); var reloaded = LibraryService.Scan(game, null, None); Check(reloaded.Find("Client.Mod").Enabled && !reloaded.Find("Owner.Mod").Enabled, "Saved switches survive a fresh library scan"); Check(reloaded.Issues().Any(i => i.Contains("Disabled:")), "Library reports disabled dependencies");
            Mod(mods, "Duplicate", "Client.Mod", "2.0"); Mod(Path.Combine(mods, "Nested"), "Wrapped", "Nested.Mod", "1.0"); Directory.CreateDirectory(Path.Combine(mods, "NoManifest"));
            library = LibraryService.Scan(game, null, None); Check(library.Mods.Count(m => m.Id == "Client.Mod" && m.ProblemTitle == "Duplicate ID") == 2, "Duplicate mod IDs are reported on both copies"); Check(library.Find("Nested.Mod").ProblemTitle == "Nested folder", "Nested mod manifests are reported"); Check(library.Mods.Any(m => m.FolderName == "NoManifest" && m.ProblemTitle == "Missing mod.vdf"), "Folders without manifests remain visible with an error");
            Check(GameLocator.Resolve(client) == game, "Selecting a mod subfolder resolves its game installation"); Check(!GameLocator.Valid(root) && GameLocator.Valid(game), "Game detection requires a game executable");
            File.WriteAllText(Path.Combine(mods, "mods.vdf"), "ModList { invalid"); library = LibraryService.Scan(game, null, None); Check(!String.IsNullOrEmpty(library.StateError), "Unreadable switch files are reported without crashing the library"); Throws(library.Save, "Unreadable switch files cannot be overwritten by mod changes");
            var cancellation = new CancellationTokenSource(); cancellation.Cancel(); Throws(() => LibraryService.Scan(game, null, cancellation.Token), "Background library scanning honors cancellation");
        }
    }
}
