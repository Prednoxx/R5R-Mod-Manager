using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace R5R.Tests {
    internal static partial class TestRunner {
        static object Manual(string id, string name) { return new { id = id, name = name, build = "Community", pageUrl = "https://example.org/mod", installKind = "manual" }; }
        static void Feed(string root, string file, params object[] items) { Json.Write(Path.Combine(root, "catalog", file), new { schemaVersion = 1, mods = items }); }
        static async Task CatalogTests() {
            var root = Area("catalog"); var paths = new AppPaths(root, Path.Combine(root, "data")); var fake = new FakeNetwork(); var service = new CatalogService(paths, fake); Directory.CreateDirectory(Path.Combine(root, "catalog"));
            Json.Write(Path.Combine(root, "catalog", "sources.json"), new { schemaVersion = 1, sources = new[] { new SourceConfig { Id = "one", Name = "One", Type = "feed", Path = "one.json" }, new SourceConfig { Id = "two", Name = "Two", Type = "feed", Path = "two.json" } } });
            Feed(root, "one.json", Manual("First", "First listing")); Feed(root, "two.json", Manual("Second", "Second listing"));
            var result = await service.Sync(true, null, None); Check(result.Items.Count == 2 && result.Sources.All(s => s.State == "Current"), "Maintained catalog sources synchronize independently");
            File.WriteAllText(Path.Combine(root, "catalog", "one.json"), "{invalid"); Feed(root, "two.json", Manual("New", "Updated listing")); result = await service.Sync(true, null, None);
            Check(result.Items.Any(e => e.Id == "First") && result.Items.Any(e => e.Id == "New"), "Failed source preserves listings while another source updates"); Check(result.Sources[0].State == "Cached" && result.Sources[1].State == "Current", "Source availability is reported per provider");
            Check(service.ReadCache().Items.Count == 2, "Catalog snapshots are available before network synchronization");
            Feed(root, "one.json"); result = await service.Sync(true, null, None); Check(!result.Items.Any(e => e.Id == "First"), "Successful source refresh removes withdrawn listings");
            File.WriteAllText(Path.Combine(root, "catalog", "one.json"), "{invalid"); File.Delete(Path.Combine(paths.Cache, "one.json")); result = await service.Sync(true, null, None); Check(result.Sources[0].State == "Unavailable" && result.Sources[0].Count == 0, "First-source failure reports no cached listings");
            var configPath = Path.Combine(root, "catalog", "sources.json"); var config = File.ReadAllText(configPath); Json.Write(configPath, new { schemaVersion = 1, sources = new[] { new SourceConfig { Id = "duplicate" }, new SourceConfig { Id = "duplicate" } } }); Throws(() => service.Config(), "Duplicate catalog source IDs are rejected"); File.WriteAllText(configPath, config);
            var source = new SourceConfig { Id = "source", Name = "Source" };
            Throws(() => CatalogService.Entry(source, new { id = "../bad", name = "Bad", build = "Community", pageUrl = "https://example.org" }), "Unsafe catalog identifiers are rejected");
            Throws(() => CatalogService.Entry(source, new { id = "Valid", name = "Name", build = "Community", pageUrl = "http://example.org" }), "Catalog page URLs require HTTPS");
            Throws(() => CatalogService.Entry(source, new { id = "Valid", name = "Name", build = CatalogService.SupportedBuild, pageUrl = "https://example.org", installKind = "zip" }), "Installable entries require package and mod identifiers");
            Throws(() => CatalogService.ValidateRepository("owner/repo", new string('a', 40), "../mods"), "Repository packages reject parent traversal");
            Throws(() => CatalogService.ValidateRepository("owner/repo", "main", "mods"), "Repository package revisions must be fixed commits");
            var entries = new[] { Listing("City", "Gamemode, Map"), Listing("Coast", "Map"), Listing("Knife", "Model, Weapon") };
            Check(CatalogService.Categories(" Map, Gamemode, Map ").SequenceEqual(new[] { "Gamemode", "Map" }), "Category tags are trimmed and deduplicated");
            Check(CatalogService.Filter(entries, "", null, null, "Map", null).Count == 2, "Category filters include multi-category listings");
            Check(CatalogService.Filter(entries, "CITY", null, null, "Map", null).Single().Id == "City", "Search combines with category filtering without case sensitivity");
            Check(CatalogService.Filter(entries, "", "Wrong build", null, null, null).Count == 0, "Build filtering excludes incompatible listings");
            Check(CatalogService.Filter(entries, "", null, "Other provider", null, null).Count == 0, "Provider filters restrict source listings");
            Check(CatalogService.Filter(entries, "", null, null, null, new HashSet<string> { "fixture:Knife" }).Single().Id == "Knife", "Favorites filtering uses stable source keys");
            var library = new LibrarySnapshot { GameDir = "C:\\Game" }; library.Mods.Add(new ModItem { Id = "City", Version = "1.0" }); var receipts = new Dictionary<string, Receipt>();
            Check(CatalogService.Status(entries[0], library, receipts) == "Installed", "Installed package status matches mod ID and version"); entries[0].Version = "2.0"; Check(CatalogService.Status(entries[0], library, receipts) == "Update available", "Newer catalog versions are labeled as updates"); entries[0].Version = "0.5"; Check(CatalogService.Status(entries[0], library, receipts) == "Newer installed", "Older catalog versions are labeled before downgrading");
            entries[0].Version = "1.0"; entries[0].Commit = new string('a', 40); receipts["City"] = new Receipt { Key = entries[0].Key, GameDir = library.GameDir, Commit = new string('b', 40) }; Check(CatalogService.Status(entries[0], library, receipts) == "Update available", "Changed source commits trigger update status without a version change"); receipts["City"].GameDir = "C:\\OtherGame"; Check(CatalogService.Status(entries[0], library, receipts) == "Installed", "Receipts from a different game do not trigger update status");
            entries[0].Build = "Flowstate S21"; Check(CatalogService.Status(entries[0], library, receipts) == "Flowstate S21", "Incompatible build listings retain their build label");
            await ProviderTests();
        }
        static async Task ProviderTests() {
            var root = Area("providers"); var paths = new AppPaths(root, Path.Combine(root, "data")); var fake = new FakeNetwork(); var service = new CatalogService(paths, fake); var source = new SourceConfig { Id = "github", Name = "GitHub", Type = "github-tree", Repository = "owner/repo", Refs = new[] { "primary", "fallback" }, Root = "defaults/mods", Build = CatalogService.SupportedBuild, Category = "Core" };
            Json.Write(Path.Combine(root, "catalog", "sources.json"), new { schemaVersion = 1, sources = new[] { source } });
            foreach (var reference in source.Refs) {
                string commit = new string(reference == "primary" ? 'a' : 'b', 40); fake.Texts["https://api.github.com/repos/owner/repo/branches/" + reference] = Json.Encode(new { commit = new { sha = commit } });
                fake.Texts["https://api.github.com/repos/owner/repo/git/trees/" + commit + "?recursive=1"] = Json.Encode(new { truncated = false, tree = new object[] { new { path = "defaults/mods/Practice/mod.vdf", type = "blob" }, new { path = "defaults/mods/Practice/preview.png", type = "blob" } } });
                fake.Texts["https://raw.githubusercontent.com/owner/repo/" + commit + "/defaults/mods/Practice/mod.vdf"] = "mod { id Practice name Practice version \"" + (reference == "primary" ? "2.0" : "1.0") + "\" }";
            }
            var result = await service.Sync(true, null, None); Check(result.Items.Count == 1 && result.Items[0].Version == "2.0", "Ordered GitHub release channels prefer the first matching mod ID"); Check(result.Items[0].Commit == new string('a', 40) && result.Items[0].PreviewUrls.Single().Contains("/preview.png"), "GitHub metadata and artwork are pinned to the resolved commit");
            var requests = fake.Requests.Count; await service.Sync(false, null, None); Check(fake.Requests.Count == requests, "Fresh source snapshots avoid unnecessary API requests");
            source.Type = "thunderstore"; source.Url = "https://example.org/packages"; source.Build = "Flowstate S21"; Json.Write(Path.Combine(root, "catalog", "sources.json"), new { schemaVersion = 1, sources = new[] { source } });
            fake.Texts[source.Url] = Json.Encode(new object[] { new { owner = "Author", name = "City", is_deprecated = false, package_url = "https://example.org/city", categories = new[] { "Map", "Gamemode" }, date_updated = "2026-10-21T00:00:00Z", versions = new object[] { new { is_active = true, version_number = "2.0.0", description = "City map", download_url = "https://example.org/city.zip", file_size = 100, downloads = 20, dependencies = new string[0], icon = "https://example.org/city.png" } } } });
            result = await service.Sync(true, null, None); Check(result.Items.Single().Build == "Flowstate S21" && result.Items[0].ModId == "Author.City", "Thunderstore packages retain their game build and publisher identity"); Check(result.Items[0].Downloads == 20 && CatalogService.Categories(result.Items[0].Category).Length == 2, "Thunderstore statistics and individual category tags are indexed");
        }
        static async Task LiveTests() {
            var root = Area("live"); var paths = new AppPaths(appRoot, Path.Combine(root, "data")); var network = new Network(paths.Cache); var service = new CatalogService(paths, network);
            var result = await service.Sync(true, null, None); Check(result.Sources.All(s => s.State == "Current"), "Live configured catalog sources synchronize"); Check(result.Items.Count(e => e.Build == CatalogService.SupportedBuild) >= 5, "Live official S3 mods are indexed"); Check(result.Items.Any(e => e.Build == "Flowstate S21"), "Live Thunderstore listings are indexed separately");
            var entry = result.Items.Single(e => e.ModId == "movementgym"); var game = Game(root); var stage = Path.Combine(game, ".r5mm-stage-live"); var package = await new PackageService(network).Prepare(entry, stage, null, None); Check(Vdf.Metadata(Path.Combine(package.Path, "mod.vdf")).Id == "movementgym", "Live repository package downloads and verifies every pinned file");
            var installer = new Installer(new TestRecovery(Path.Combine(root, "recovery")), new DirectoryMover(), null); installer.Commit(installer.Plan(game, package, None), None); var library = LibraryService.Scan(game, null, None); Check(library.Find("movementgym") != null && library.Find("movementgym").Enabled, "Live package installs into an isolated game through the C# installer"); Files.RemoveStage(stage, game);
        }
    }
}
