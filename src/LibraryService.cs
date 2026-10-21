using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;

namespace R5R {
    public sealed class LibrarySnapshot {
        public string GameDir;
        public string StateRoot = "ModList";
        public Dictionary<string, string> States = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public List<ModItem> Mods = new List<ModItem>();
        public Dictionary<string, string[]> ConVarCache = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        public string StateError;
        public string ModsDir { get { return Path.Combine(GameDir, "mods"); } }
        public ModItem Find(string id) { return Mods.FirstOrDefault(m => !String.IsNullOrEmpty(id) && String.Equals(m.Id, id, StringComparison.OrdinalIgnoreCase)); }
        public void Save() {
            var path = Path.Combine(ModsDir, "mods.vdf"); Directory.CreateDirectory(ModsDir);
            if (!String.IsNullOrEmpty(StateError)) throw new IOException("mods.vdf could not be read. Repair the file before changing mod switches.");
            if (File.Exists(path) && !File.Exists(path + ".bak")) File.Copy(path, path + ".bak");
            Files.WriteAtomic(path, Vdf.WriteSwitches(StateRoot, States));
        }
        public Dictionary<string, string> Snapshot() { return Mods.Where(m => !String.IsNullOrEmpty(m.Id) && !m.IsRequired).GroupBy(m => m.Id, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().Enabled ? "1" : "0", StringComparer.OrdinalIgnoreCase); }
        public void SetEnabled(ModItem item, bool enabled) { if (!item.CanToggle) return; States[item.Id] = enabled ? "1" : "0"; foreach (var m in Mods.Where(m => String.Equals(m.Id, item.Id, StringComparison.OrdinalIgnoreCase))) m.Enabled = enabled; }
        public void SetAll(bool enabled) { foreach (var mod in Mods.Where(m => m.CanToggle && (enabled || !m.IsRequired))) SetEnabled(mod, enabled); }
        public void Apply(IDictionary<string, string> preset) { foreach (var m in Mods.Where(m => m.CanToggle && !m.IsRequired)) { string state; if (preset.TryGetValue(m.Id, out state)) SetEnabled(m, state != "0"); } }
        public bool Diff(IDictionary<string, string> preset) { return Mods.Where(m => m.CanToggle && !m.IsRequired).Any(m => preset.ContainsKey(m.Id) && (preset[m.Id] != "0") != m.Enabled); }
        public List<string> Issues() {
            var issues = new List<string>();
            foreach (var m in Mods) { m.DepProblem = ""; m.DepTitle = ""; }
            foreach (var stock in StockMod.All.Where(s => s.Required)) { var m = Find(stock.Id); if (m == null) issues.Add(stock.Name + " is not installed. R5Reloaded needs it for its menus and settings."); else if (!m.Enabled) issues.Add(m.DisplayName + " is disabled. R5Reloaded needs it for its menus and settings."); }
            foreach (var m in Mods.Where(m => m.Enabled && !m.IsRequired)) {
                var missing = m.Dependencies.Where(d => Find(d) == null).ToArray(); var disabled = m.Dependencies.Select(Find).Where(d => d != null && !d.Enabled).ToArray();
                var parts = new List<string>(); if (missing.Length > 0) parts.Add("Missing: " + String.Join(", ", missing) + "."); if (disabled.Length > 0) parts.Add("Disabled: " + String.Join(", ", disabled.Select(d => d.DisplayName)) + ".");
                if (parts.Count > 0) { m.DepTitle = missing.Length > 0 ? "Missing dependency" : "Dependency disabled"; m.DepProblem = String.Join(" ", parts); issues.Add(m.DisplayName + ": " + m.DepProblem); }
            }
            return issues;
        }
    }
    public static class LibraryService {
        public static LibrarySnapshot Scan(string game, IDictionary<string, string[]> previous, CancellationToken token) {
            var result = new LibrarySnapshot { GameDir = game, ConVarCache = new Dictionary<string, string[]>(previous ?? new Dictionary<string, string[]>(), StringComparer.OrdinalIgnoreCase) };
            var stateFile = Path.Combine(result.ModsDir, "mods.vdf");
            if (File.Exists(stateFile)) try { var root = Vdf.Parse(File.ReadAllText(stateFile)); var pair = root.FirstOrDefault(p => p.Value is Dictionary<string, object>); if (pair.Value == null) throw new InvalidDataException("No mod list in mods.vdf."); result.StateRoot = pair.Key; foreach (var entry in (Dictionary<string, object>)pair.Value) result.States[entry.Key] = Convert.ToString(entry.Value); } catch (Exception ex) { if (!(ex is IOException) && !(ex is UnauthorizedAccessException) && !(ex is InvalidDataException)) throw; result.StateError = ex.Message; }
            if (!Directory.Exists(result.ModsDir)) return result;
            foreach (var directory in Directory.GetDirectories(result.ModsDir)) {
                token.ThrowIfCancellationRequested(); if (Files.IsLink(directory)) continue;
                var name = Path.GetFileName(directory); var vdf = Path.Combine(directory, "mod.vdf"); var item = new ModItem();
                try {
                    if (!File.Exists(vdf)) vdf = Files.Walk(directory, "mod.vdf", 2, token).OrderBy(p => p.Length).FirstOrDefault();
                    if (vdf == null) { item.ProblemTitle = "Missing mod.vdf"; item.Problem = "No mod.vdf in this folder. The game will not load it."; }
                    else { item = Vdf.Metadata(vdf); if (String.IsNullOrEmpty(item.Id)) { item.ProblemTitle = "Missing ID"; item.Problem = "mod.vdf has no ID. This mod cannot be enabled or disabled."; } else if (!String.Equals(vdf, Path.Combine(directory, "mod.vdf"), StringComparison.OrdinalIgnoreCase)) { item.ProblemTitle = "Nested folder"; item.Problem = "Move the contents containing mod.vdf up one folder level."; } }
                } catch (Exception ex) { if (!(ex is IOException) && !(ex is UnauthorizedAccessException) && !(ex is InvalidDataException)) throw; item.ProblemTitle = "Unreadable mod.vdf"; item.Problem = ex.Message; }
                item.Folder = directory; item.FolderName = name; item.VdfPath = vdf;
                if (String.IsNullOrEmpty(item.Name)) item.Name = name;
                string state; item.Enabled = String.IsNullOrEmpty(item.Id) || !result.States.TryGetValue(item.Id, out state) || state != "0";
                item.IsRequired = StockMod.All.Any(s => s.Required && String.Equals(s.Id, item.Id, StringComparison.OrdinalIgnoreCase));
                if (!String.IsNullOrEmpty(item.Id) && item.ConVars.Length > 0) result.ConVarCache[item.Id] = item.ConVars;
                result.Mods.Add(item);
            }
            foreach (var group in result.Mods.Where(m => m.CanToggle).GroupBy(m => m.Id, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1)) foreach (var m in group) { if (String.IsNullOrEmpty(m.Problem)) { m.ProblemTitle = "Duplicate ID"; m.Problem = "Another installed mod uses the same ID. Both share their enabled state."; } }
            var owners = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var pair in result.ConVarCache) foreach (var name in pair.Value ?? new string[0]) if (!String.IsNullOrEmpty(name)) owners[name] = pair.Key;
            var regex = owners.Count == 0 ? null : new Regex("\"(" + String.Join("|", owners.Keys.OrderByDescending(k => k.Length).Select(Regex.Escape)) + ")\"", RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(250));
            foreach (var m in result.Mods) {
                var deps = new HashSet<string>(m.Deps, StringComparer.OrdinalIgnoreCase);
                if (regex != null && !m.IsRequired) foreach (var file in Files.Walk(m.Folder, "*", 32, token).Where(p => String.Equals(Path.GetExtension(p), ".nut", StringComparison.OrdinalIgnoreCase) || String.Equals(Path.GetExtension(p), ".gnut", StringComparison.OrdinalIgnoreCase))) {
                    if (new FileInfo(file).Length > 4 * 1024 * 1024) continue;
                    try { foreach (Match match in regex.Matches(File.ReadAllText(file))) { var owner = owners[match.Groups[1].Value]; if (!String.Equals(owner, m.Id, StringComparison.OrdinalIgnoreCase)) deps.Add(owner); } } catch (IOException) { } catch (UnauthorizedAccessException) { } catch (RegexMatchTimeoutException) { }
                }
                m.Dependencies = deps.ToArray();
            }
            result.Mods = result.Mods.OrderBy(m => m.DisplayName, StringComparer.OrdinalIgnoreCase).ToList(); result.Issues(); return result;
        }
    }
}
