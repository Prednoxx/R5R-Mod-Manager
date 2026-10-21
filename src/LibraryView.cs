using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace R5R {
    public sealed partial class MainWindowController {
        async Task ReloadLibrary() {
            if (!GameLocator.Valid(settings.GameDir) || installing || mutating) return;
            if (scanCancellation != null) scanCancellation.Cancel(); var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); scanCancellation = cancellation; var token = cancellation.Token; var game = settings.GameDir;
            scanning = true; if (library != null && !String.Equals(library.GameDir, game, StringComparison.OrdinalIgnoreCase)) library = null; SetBusy(); Status("Scanning mods", false);
            try { var cache = new Dictionary<string, string[]>(settings.ConVarCache, StringComparer.OrdinalIgnoreCase); var result = await Task.Run(() => LibraryService.Scan(game, cache, token), token); if (token.IsCancellationRequested || !String.Equals(game, settings.GameDir, StringComparison.OrdinalIgnoreCase)) return; library = result; settings.ConVarCache = result.ConVarCache; settings.Save(paths); FillLibrary(); Status(String.IsNullOrEmpty(result.StateError) ? "Ready" : "mods.vdf could not be read. Repair it before changing mods.", !String.IsNullOrEmpty(result.StateError)); Trace("mods ready: " + library.Mods.Count); }
            catch (OperationCanceledException) { }
            finally { if (scanCancellation == cancellation) { scanning = false; SetBusy(); FillStore(); } cancellation.Dispose(); }
        }
        void FillLibrary() {
            var list = Element<ListBox>("ModList"); var selected = list.SelectedItem as ModItem; var query = Element<TextBox>("SearchBox").Text.Trim();
            var mods = library == null ? new List<ModItem>() : library.Mods.Where(m => query.Length == 0 || String.Join(" ", new[] { m.Name, m.Id, m.Author, m.FolderName }).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToList();
            list.ItemsSource = mods; list.SelectedItem = selected == null ? mods.FirstOrDefault() : mods.FirstOrDefault(m => m.Folder == selected.Folder) ?? mods.FirstOrDefault(); Visible("SearchHint", query.Length == 0); Visible("EmptyState", mods.Count == 0);
            if (!GameLocator.Valid(settings.GameDir)) { Text("EmptyTitle", "No game folder"); Text("EmptySub", "Choose the R5Reloaded folder in Settings."); }
            else if (library == null || library.Mods.Count == 0) { Text("EmptyTitle", "No mods installed"); Text("EmptySub", "Drop a ZIP archive or mod folder here."); }
            else { Text("EmptyTitle", "No matches"); Text("EmptySub", "No installed mods match the search."); }
            RefreshLibraryState(); LibraryDetails();
        }
        void RefreshLibraryState() {
            Text("CountText", library == null || library.Mods.Count == 0 ? "" : library.Mods.Count + " installed  ·  " + library.Mods.Count(m => m.CanToggle && m.Enabled) + " active");
            var issues = library == null ? new List<string>() : library.Issues(); Visible("IssueBar", issues.Count > 0); Text("IssueText", String.Join(Environment.NewLine, issues)); Visible("BtnFixIssues", issues.Count > 0); Text("FixText", "Fix");
            Dictionary<string, string> preset; bool found = !String.IsNullOrEmpty(settings.ActivePreset) && settings.Presets.TryGetValue(settings.ActivePreset, out preset);
            Text("PresetName", found ? settings.ActivePreset : "None"); Element<Button>("BtnPresetSave").IsEnabled = found && !installing && !mutating && !scanning; Element<Button>("BtnPresetDelete").IsEnabled = found && !installing && !mutating && !scanning;
            Visible("PresetModified", found && library != null && library.Diff(settings.Presets[settings.ActivePreset]));
        }
        void LibraryDetails() {
            var mod = Element<ListBox>("ModList").SelectedItem as ModItem; Visible("DetBody", mod != null); Visible("DetEmpty", mod == null); Element<Button>("BtnOpenMod").IsEnabled = mod != null; Element<Button>("BtnRemove").IsEnabled = mod != null && !installing && !mutating && !scanning;
            if (mod == null) return;
            Text("DetName", mod.DisplayName); Text("DetTagText", mod.Status); Element<Border>("DetTag").SetResourceReference(Border.BackgroundProperty, mod.HasProblem ? "Warn" : mod.Enabled ? "AccentBg" : "TagOffBg"); Element<TextBlock>("DetTagText").SetResourceReference(TextBlock.ForegroundProperty, mod.Enabled && !mod.HasProblem ? "AccentText" : "Text");
            Text("DetVersion", String.IsNullOrEmpty(mod.Version) ? "—" : mod.Version); Text("DetAuthor", String.IsNullOrEmpty(mod.Author) ? "—" : mod.Author); Text("DetId", String.IsNullOrEmpty(mod.Id) ? "—" : mod.Id); Text("DetFolder", "mods\\" + mod.FolderName); Text("DetDesc", String.IsNullOrEmpty(mod.Description) ? "—" : mod.Description);
            Visible("DetWarn", mod.HasProblem); Text("DetWarnTitle", String.IsNullOrEmpty(mod.Problem) ? mod.DepTitle : mod.ProblemTitle); Text("DetWarnText", String.IsNullOrEmpty(mod.Problem) ? mod.DepProblem : mod.Problem);
            Visible("DetDepsWrap", mod.Dependencies.Length > 0); Text("DetDeps", String.Join(", ", mod.Dependencies.Select(d => { var dependency = library == null ? null : library.Find(d); return dependency == null ? d + " (missing)" : dependency.DisplayName + (dependency.Enabled ? "" : " (disabled)"); })));
            var entry = listings.Items.FirstOrDefault(e => String.Equals(e.ModId, mod.Id, StringComparison.OrdinalIgnoreCase)); Visible("DetSourceWrap", entry != null); if (entry != null) Element<Run>("DetSourceText").Text = new Uri(entry.PageUrl).Host;
        }
        void SetBusy() { bool busy = installing || mutating || scanning; Element<ListBox>("ModList").IsEnabled = !busy; foreach (var name in new[] { "BtnInstallZip", "BtnInstallDir", "BtnEnableAll", "BtnDisableAll", "BtnPreset", "BtnPresetNew", "BtnRefresh", "BtnFixIssues", "BtnRestore" }) Element<Button>(name).IsEnabled = !busy; RefreshLibraryState(); LibraryDetails(); UpdateStoreDetails(); }
        async Task ModifyLibrary(Action<LibrarySnapshot> action) {
            if (library == null || !RequireGame()) return; if (installing || mutating || scanning) { Status("Wait for the current mod operation to finish.", true); return; }
            var previous = new Dictionary<string, string>(library.States, StringComparer.OrdinalIgnoreCase); mutating = true; SetBusy();
            try { action(library); await Task.Run(() => library.Save(), lifetime.Token); RefreshLibraryState(); LibraryDetails(); FillStore(); Status("Mod configuration saved", false); }
            catch { library.States = previous; foreach (var mod in library.Mods) { string state; mod.Enabled = !previous.TryGetValue(mod.Id ?? "", out state) || state != "0"; } throw; }
            finally { mutating = false; SetBusy(); }
        }
        Task ToggleMod(ModItem mod) {
            if (library == null) return Done();
            if (installing || mutating || scanning) { string state; mod.Enabled = !library.States.TryGetValue(mod.Id ?? "", out state) || state != "0"; return Done(); }
            bool enabled = mod.Enabled; return ModifyLibrary(l => l.SetEnabled(mod, enabled));
        }
        void ShowPresets() { var menu = Menu("BtnPreset"); foreach (var name in settings.Presets.Keys.OrderBy(n => n)) { var key = name; menu.Items.Add(Item(name + (settings.ActivePreset == name ? "  ✓" : ""), async () => { await ModifyLibrary(l => l.Apply(settings.Presets[key])); settings.ActivePreset = key; settings.Save(paths); RefreshLibraryState(); Status("Preset applied: " + key, false); })); } if (settings.Presets.Count == 0) menu.Items.Add(new MenuItem { Header = "No presets", IsEnabled = false }); menu.Items.Add(Item("Save as new preset", NewPreset)); menu.IsOpen = true; }
        Task SavePreset() { if (library == null || installing || mutating || scanning) return Done(); if (String.IsNullOrEmpty(settings.ActivePreset)) return NewPreset(); settings.Presets[settings.ActivePreset] = library.Snapshot(); settings.Save(paths); RefreshLibraryState(); Status("Preset saved: " + settings.ActivePreset, false); return Done(); }
        async Task NewPreset() {
            if (library == null || installing || mutating || scanning || !RequireGame()) return;
            var answer = await ShowDialog("New preset", "Save the current enabled-mod combination.", "Save", "Cancel", true); if (!answer.Accepted || answer.Text.Length == 0) return;
            if (settings.Presets.ContainsKey(answer.Text) && !(await ShowDialog("Replace preset", "A preset with this name already exists.", "Replace", "Cancel", false)).Accepted) return;
            settings.Presets[answer.Text] = library.Snapshot(); settings.ActivePreset = answer.Text; settings.Save(paths); RefreshLibraryState(); Status("Preset saved: " + answer.Text, false);
        }
        async Task DeletePreset() { var name = settings.ActivePreset; if (String.IsNullOrEmpty(name) || installing || mutating || scanning) return; if (!(await ShowDialog("Delete preset", "Delete the preset \"" + name + "\"? Mod files and switches remain unchanged.", "Delete", "Cancel", false)).Accepted) return; settings.Presets.Remove(name); settings.ActivePreset = ""; settings.Save(paths); RefreshLibraryState(); Status("Preset deleted", false); }
        async Task UninstallSelected() {
            var mod = Element<ListBox>("ModList").SelectedItem as ModItem; if (mod == null || library == null || installing || mutating || scanning) return;
            mutating = true; SetBusy(); Exception failure = null;
            try { var message = (mod.IsRequired ? "R5Reloaded needs this mod for its menus and settings. " : "") + "The mod folder will move to the Windows Recycle Bin."; if (!(await ShowDialog("Uninstall " + mod.DisplayName, message, "Uninstall", "Cancel", false)).Accepted) return; await Task.Run(() => recovery.Recycle(mod.Folder)); if (!library.Mods.Any(m => m.Folder != mod.Folder && String.Equals(m.Id, mod.Id, StringComparison.OrdinalIgnoreCase))) { library.States.Remove(mod.Id ?? ""); await Task.Run(() => library.Save()); } Status("Uninstalled " + mod.DisplayName, false); }
            catch (Exception ex) { failure = ex; }
            finally { mutating = false; SetBusy(); }
            if (!closing) await ReloadLibrary(); if (failure != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        }
        async Task ShowRestore() {
            if (!RequireGame() || installing || mutating || scanning) return; var game = settings.GameDir; var entries = await Task.Run(() => recovery.List(game), lifetime.Token); if (game != settings.GameDir) return;
            var menu = Menu("BtnRestore"); if (entries.Count == 0) menu.Items.Add(new MenuItem { Header = "No recoverable mods", IsEnabled = false });
            foreach (var entry in entries) { var item = entry; menu.Items.Add(Item(entry.Name + (entry.Date.HasValue ? "  —  " + entry.Date.Value.ToString("g") : ""), () => Restore(item, game))); }
            menu.IsOpen = true;
        }
        async Task Restore(RecycledMod item, string game) {
            if (mutating || installing || scanning || game != settings.GameDir) return; mutating = true; SetBusy(); Exception failure = null;
            try { await recovery.Restore(item, game, lifetime.Token); Status("Restored " + item.Name, false); }
            catch (Exception ex) { failure = ex; }
            finally { mutating = false; SetBusy(); }
            if (!closing) await ReloadLibrary(); if (failure != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        }
        async Task FixIssues() {
            if (library == null || installing || mutating || scanning) return;
            await ModifyLibrary(l => { foreach (var required in l.Mods.Where(m => m.IsRequired || l.Mods.Where(x => x.Enabled).Any(x => x.Dependencies.Contains(m.Id, StringComparer.OrdinalIgnoreCase)))) l.SetEnabled(required, true); });
            var ids = new HashSet<string>(StockMod.All.Where(s => s.Required && library.Find(s.Id) == null).Select(s => s.Id), StringComparer.OrdinalIgnoreCase);
            foreach (var mod in library.Mods.Where(m => m.Enabled)) foreach (var id in mod.Dependencies) if (library.Find(id) == null) ids.Add(id);
            if (ids.Count == 0) return; if (listings.Items.Count == 0) await Sync(true);
            var entries = listings.Items.Where(e => e.Build == CatalogService.SupportedBuild && e.InstallKind != "manual" && ids.Contains(e.ModId)).ToArray();
            if (entries.Length == 0) { Status("Missing dependencies are not available in the configured catalog.", true); return; }
            if (!(await ShowDialog("Install missing mods", String.Join(Environment.NewLine, entries.Select(e => e.Name)), "Download", "Cancel", false)).Accepted) return;
            queueCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            try { foreach (var entry in entries) { queueCancellation.Token.ThrowIfCancellationRequested(); await InstallStore(entry, queueCancellation.Token); } }
            finally { queueCancellation.Dispose(); queueCancellation = null; }
        }
    }
}
