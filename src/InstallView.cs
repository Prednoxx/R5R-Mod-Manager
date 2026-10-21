using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace R5R {
    public sealed partial class MainWindowController {
        readonly List<string> downloadHistory = new List<string>();
        void UpdateDownload(string message, PackageProgress progress) {
            Text("DownloadStatus", message); Text("StoreProgressText", message);
            foreach (var name in new[] { "DownloadProgress", "StoreProgress" }) { var control = Element<ProgressBar>(name); control.IsIndeterminate = progress == null || progress.Total <= 0; if (!control.IsIndeterminate) control.Value = Math.Min(100, 100.0 * progress.Bytes / progress.Total); }
        }
        async Task<bool> Publish(PreparedPackage prepared, string game, CancellationToken token) {
            token.ThrowIfCancellationRequested(); if (game != settings.GameDir) throw new OperationCanceledException("The game folder changed.");
            var plan = await Task.Run(() => installer.Plan(game, prepared, token), token);
            if (plan.Existing.Count > 0) {
                var old = plan.Existing[0]; var body = plan.Metadata.DisplayName + Environment.NewLine + Environment.NewLine + "Installed: " + (String.IsNullOrEmpty(old.Version) ? "Unknown version" : old.Version) + Environment.NewLine + "New: " + (String.IsNullOrEmpty(plan.Metadata.Version) ? "Unknown version" : plan.Metadata.Version) + Environment.NewLine + Environment.NewLine + "The installed copy will move to the Windows Recycle Bin.";
                if (!(await ShowDialog("Replace installed mod", body, "Replace", "Skip", false)).Accepted) return false;
            }
            token.ThrowIfCancellationRequested(); if (game != settings.GameDir) throw new OperationCanceledException("The game folder changed.");
            if (GameLocator.Running()) throw new IOException("Close R5Reloaded before installing mods.");
            UpdateDownload("Installing " + plan.Metadata.DisplayName, null); await Task.Run(() => installer.Commit(plan, token), token); return true;
        }
        async Task InstallStore(CatalogEntry entry, CancellationToken queueToken) {
            if (entry == null || installing || mutating || scanning || closing || entry.Build != CatalogService.SupportedBuild || entry.InstallKind == "manual") return;
            if (!GameLocator.Valid(settings.GameDir)) { await BrowseGame(); return; }
            if (GameLocator.Running()) { UpdateDownload("Close R5Reloaded before installing mods.", null); return; }
            foreach (var dependency in entry.Dependencies ?? new string[0]) if (library == null || library.Find(dependency) == null) { await ShowDialog("Missing dependency", "Install " + dependency + " before installing this mod.", "OK", null, false); return; }
            var game = settings.GameDir; var stage = System.IO.Path.Combine(game, ".r5mm-stage-" + Guid.NewGuid().ToString("N")); var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, queueToken); operationCancellation = cancellation; var token = cancellation.Token;
            installing = true; SetBusy(); FillStore(); Text("DownloadName", entry.Name); Visible("DownloadProgress", true); Visible("StoreProgress", true); Visible("BtnStoreCancel", true); Element<Button>("BtnDownloadCancel").IsEnabled = true; string outcome = "Installation skipped"; Exception failure = null;
            try {
                UpdateDownload("Preparing download", null);
                var progress = new Progress<PackageProgress>(p => { if (!closing && operationCancellation == cancellation) { var text = p.Text; if (p.Total > 0) text += "  " + (p.Bytes / 1048576.0).ToString("N1") + " / " + (p.Total / 1048576.0).ToString("N1") + " MB"; UpdateDownload(text, p); } });
                var prepared = await Task.Run(() => packages.Prepare(entry, stage, progress, token), token);
                if (await Publish(prepared, game, token)) {
                    receipts[entry.ModId] = new Receipt { Key = entry.Key, GameDir = game, Version = entry.Version, Commit = entry.Commit, Installed = DateTime.UtcNow.ToString("o") }; Json.Write(System.IO.Path.Combine(paths.Data, "installed-packages.json"), receipts); outcome = "Installed " + entry.Name;
                }
            } catch (OperationCanceledException) { outcome = game == settings.GameDir ? "Download cancelled" : "Download cancelled: game folder changed"; }
            catch (Exception ex) { outcome = "Installation failed"; paths.Log("Package: " + ex); failure = ex; }
            finally {
                try { Files.RemoveStage(stage, game); } catch (Exception ex) { paths.Log("Package cleanup: " + ex.Message); }
                if (operationCancellation == cancellation) operationCancellation = null; cancellation.Dispose(); installing = false; SetBusy();
                Text("DownloadName", "No active downloads"); UpdateDownload(outcome, null); Visible("DownloadProgress", false); Visible("StoreProgress", false); Visible("BtnStoreCancel", false); Element<Button>("BtnDownloadCancel").IsEnabled = false;
                downloadHistory.Insert(0, DateTime.Now.ToString("HH:mm") + "  " + entry.Name + "  —  " + outcome); if (downloadHistory.Count > 100) downloadHistory.RemoveAt(downloadHistory.Count - 1); Text("DownloadHistory", String.Join(Environment.NewLine, downloadHistory));
            }
            if (failure != null && !closing) await ShowDialog("Installation failed", failure.Message, "OK", null, false);
            if (!closing && game == settings.GameDir) await ReloadLibrary(); FillStore();
        }
        async Task InstallLocal(string[] sources) {
            if (installing || mutating || scanning || !RequireGame()) return;
            if (GameLocator.Running()) { Status("Close R5Reloaded before installing mods.", true); return; }
            var game = settings.GameDir; var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); operationCancellation = cancellation; var token = cancellation.Token; installing = true; SetBusy(); FillStore(); int installed = 0; Exception failure = null;
            try {
                foreach (var source in sources) {
                    var stage = System.IO.Path.Combine(game, ".r5mm-stage-" + Guid.NewGuid().ToString("N"));
                    try { Status("Preparing " + System.IO.Path.GetFileName(source), false); var mods = await Task.Run(() => PackageService.PrepareLocal(source, game, stage, token), token); foreach (var mod in mods) if (await Publish(mod, game, token)) installed++; }
                    finally { try { Files.RemoveStage(stage, game); } catch (Exception ex) { paths.Log("Local package cleanup: " + ex.Message); } }
                }
                Status(installed == 1 ? "Installed 1 mod" : "Installed " + installed + " mods", false);
            } catch (Exception ex) { failure = ex; }
            finally { if (operationCancellation == cancellation) operationCancellation = null; cancellation.Dispose(); installing = false; SetBusy(); }
            if (!closing && game == settings.GameDir) await ReloadLibrary(); FillStore(); if (failure != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        }
        async Task InstallZip() { if (installing || mutating || scanning || !RequireGame()) return; var dialog = new OpenFileDialog { Title = "Install mod ZIP", Filter = "Mod archives (*.zip)|*.zip", Multiselect = true }; if (dialog.ShowDialog(Window) == true) await InstallLocal(dialog.FileNames); }
        async Task InstallFolder() { if (installing || mutating || scanning || !RequireGame()) return; var path = NativeShell.PickFolder(new System.Windows.Interop.WindowInteropHelper(Window).Handle, "Install mod folder", null); if (!String.IsNullOrEmpty(path)) await InstallLocal(new[] { path }); }
    }
}
