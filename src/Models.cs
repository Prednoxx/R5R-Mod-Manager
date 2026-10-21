using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;

namespace R5R {
    public abstract class Observable : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Changed(params string[] names) { var handler = PropertyChanged; if (handler != null) foreach (var name in names) handler(this, new PropertyChangedEventArgs(name)); }
    }
    public sealed class ModItem : Observable {
        public string Folder { get; set; }
        public string FolderName { get; set; }
        public string VdfPath { get; set; }
        public string Name { get; set; }
        public string Id { get; set; }
        public string Version { get; set; }
        public string Author { get; set; }
        public string Description { get; set; }
        public string Problem { get; set; }
        public string ProblemTitle { get; set; }
        public bool IsRequired { get; set; }
        public string[] ConVars { get; set; }
        public string[] Deps { get; set; }
        public string[] Dependencies { get; set; }
        private bool enabled;
        private string dependencyProblem, dependencyTitle;
        public bool Enabled { get { return enabled; } set { enabled = value; Changed("Enabled", "Status"); } }
        public string DepProblem { get { return dependencyProblem; } set { dependencyProblem = value; Changed("DepProblem", "HasProblem", "Status"); } }
        public string DepTitle { get { return dependencyTitle; } set { dependencyTitle = value; Changed("DepTitle"); } }
        public bool CanToggle { get { return !String.IsNullOrEmpty(Id); } }
        public bool HasProblem { get { return !String.IsNullOrEmpty(Problem) || !String.IsNullOrEmpty(DepProblem); } }
        public string Status { get { return HasProblem ? "Error" : Enabled ? "Active" : "Inactive"; } }
        public string DisplayName { get { return String.IsNullOrEmpty(Name) ? FolderName : Name; } }
        public string Meta { get { return String.Join("  ·  ", new[] { String.IsNullOrEmpty(Version) ? "" : "v" + Version, Author }.Where(s => !String.IsNullOrEmpty(s))); } }
        public ModItem() { ConVars = Deps = Dependencies = new string[0]; }
    }
    public sealed class CatalogEntry {
        public string Key { get; set; }
        public string Id { get; set; }
        public string ModId { get; set; }
        public string Name { get; set; }
        public string Author { get; set; }
        public string Description { get; set; }
        public string Version { get; set; }
        public string Category { get; set; }
        public string Build { get; set; }
        public string SourceId { get; set; }
        public string Source { get; set; }
        public string PageUrl { get; set; }
        public string DownloadUrl { get; set; }
        public string InstallKind { get; set; }
        public string Sha256 { get; set; }
        public string Repository { get; set; }
        public string Commit { get; set; }
        public string PackagePath { get; set; }
        public string Updated { get; set; }
        public long Downloads { get; set; }
        public long Size { get; set; }
        public string[] Dependencies { get; set; }
        public string IconUrl { get; set; }
        public string[] PreviewUrls { get; set; }
        public CatalogEntry() { Dependencies = PreviewUrls = new string[0]; }
    }
    public sealed class CatalogCard : Observable {
        public CatalogEntry Entry { get; set; }
        public string Key { get { return Entry.Key; } }
        public string Name { get { return Entry.Name; } }
        public string AuthorLabel { get { return "By " + Entry.Author; } }
        public string Build { get { return Entry.Build; } }
        public string Stats { get { return Entry.Downloads > 0 ? Entry.Downloads.ToString("N0") + " downloads" : Entry.Source; } }
        public string Status { get; set; }
        public bool CanInstall { get; set; }
        private string previewPath;
        public string PreviewPath { get { return previewPath; } set { previewPath = value; Changed("PreviewPath"); } }
        public override string ToString() { return Name; }
    }
    public sealed class SourceConfig {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Type { get; set; }
        public string Repository { get; set; }
        public string[] Refs { get; set; }
        public string Root { get; set; }
        public string Build { get; set; }
        public string Category { get; set; }
        public string Url { get; set; }
        public string Path { get; set; }
    }
    public sealed class SourceDocument { public int SchemaVersion { get; set; } public List<SourceConfig> Sources { get; set; } }
    public sealed class SourceSnapshot { public int SchemaVersion { get; set; } public string Updated { get; set; } public string NextCheck { get; set; } public List<CatalogEntry> Items { get; set; } public string Error { get; set; } }
    public sealed class SourceState { public string Name { get; set; } public string State { get; set; } public string Error { get; set; } public string Updated { get; set; } public int Count { get; set; } }
    public sealed class CatalogResult { public List<CatalogEntry> Items = new List<CatalogEntry>(); public List<SourceState> Sources = new List<SourceState>(); }
    public sealed class Receipt { public string Key { get; set; } public string GameDir { get; set; } public string Version { get; set; } public string Commit { get; set; } public string Installed { get; set; } }
    public sealed class FavoritesDocument { public string[] Keys { get; set; } }
    public sealed class ModDetails { public string Key { get; set; } public string Body { get; set; } public string[] Images { get; set; } public string Updated { get; set; } }
    public sealed class PackageProgress { public string Text; public long Bytes; public long Total; public PackageProgress(string text) { Text = text; } }
    public sealed class PreparedPackage { public string Path; public string ModId; public string Version; }
    public sealed class StockMod {
        public string Id, Folder, Name; public bool Required;
        public StockMod(string id, string folder, string name, bool required) { Id = id; Folder = folder; Name = name; Required = required; }
        public static readonly StockMod[] All = {
            new StockMod("Flowstate", "Flowstate", "R5R Mod: Flowstate", true), new StockMod("SDK.Core", "sdk_core", "SDK core mod", true),
            new StockMod("Karma", "Karma", "Karma Assets", false), new StockMod("kralstuff", "Kralstuff", "KralStuff", false), new StockMod("movementgym", "movementgym", "movementgym", false)
        };
    }
}
