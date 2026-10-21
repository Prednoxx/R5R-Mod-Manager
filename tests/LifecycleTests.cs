using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace R5R.Tests {
    internal sealed class PendingNetwork : INetwork {
        public int Started, Active;
        public async Task<string> Text(string url, CancellationToken token) {
            Interlocked.Increment(ref Started); Interlocked.Increment(ref Active);
            var completion = new TaskCompletionSource<string>();
            try { using (token.Register(() => completion.TrySetCanceled())) return await completion.Task.ConfigureAwait(false); }
            finally { Interlocked.Decrement(ref Active); }
        }
        public async Task Download(string url, string path, long limit, IProgress<PackageProgress> progress, CancellationToken token) { await Text(url, token).ConfigureAwait(false); }
    }
    internal static partial class TestRunner {
        static object ControllerCall(MainWindowController controller, string name, params object[] args) {
            try { return typeof(MainWindowController).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(controller, args); }
            catch (TargetInvocationException ex) { throw ex.InnerException; }
        }
        static void PumpUntil(Func<bool> complete) {
            if (complete()) return;
            var frame = new DispatcherFrame(); var started = DateTime.UtcNow;
            var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(5) };
            timer.Tick += (s, e) => { if (complete() || DateTime.UtcNow - started > TimeSpan.FromSeconds(10)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!complete()) throw new TimeoutException("Application lifecycle operation did not complete.");
        }
        static void CompleteTask(Task task) { PumpUntil(() => task.IsCompleted); task.GetAwaiter().GetResult(); }
        static MainWindowController LifecycleController(string name, INetwork network = null) {
            var root = Area(name); var paths = new AppPaths(appRoot, Path.Combine(root, "data")); var game = Game(root);
            Mod(Path.Combine(game, "mods"), "Practice", "Practice.Mod", "1.0");
            new AppSettings { GameDir = game }.Save(paths); return network == null ? new MainWindowController(paths) : new MainWindowController(paths, network);
        }
        static void CloseController(MainWindowController controller, string name) {
            bool closed = false; controller.Window.Closed += (s, e) => closed = true;
            controller.Window.Close(); PumpUntil(() => closed); Check(closed, name);
            var paths = (AppPaths)typeof(MainWindowController).GetField("paths", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(controller);
            var log = Path.Combine(paths.Data, "error.log");
            Check(!File.Exists(log), "Shutdown completes without writing an application error" + (File.Exists(log) ? ": " + File.ReadAllText(log) : ""));
        }
        static void LifecycleTests() {
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try {
                var controller = LifecycleController("lifecycle-idle");
                try {
                    CompleteTask((Task)ControllerCall(controller, "ReloadLibrary"));
                    CompleteTask((Task)ControllerCall(controller, "ReloadLibrary"));
                    Check(controller.Element<System.Windows.Controls.ListBox>("ModList").Items.Count == 1, "Repeated completed library scans preserve the installed mod list");
                    CloseController(controller, "Closing after a completed mod scan finishes without a disposed cancellation source");
                } finally {
                    typeof(MainWindowController).GetField("allowClose", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(controller, true);
                    controller.Window.Close();
                }
                controller = LifecycleController("lifecycle-scan");
                ControllerCall(controller, "Fire", new Func<Task>(() => (Task)ControllerCall(controller, "ReloadLibrary")));
                CloseController(controller, "Closing during a library scan cancels and waits for the pending scan");
                controller = LifecycleController("lifecycle-replace");
                var first = (Task)ControllerCall(controller, "ReloadLibrary");
                var second = (Task)ControllerCall(controller, "ReloadLibrary");
                CompleteTask(Task.WhenAll(first, second));
                Check(controller.Element<System.Windows.Controls.Button>("BtnRefresh").IsEnabled, "Replacing a pending library scan restores the refresh control");
                CloseController(controller, "Closing after a cancelled and replaced scan finishes normally");
                controller = LifecycleController("detail", new FakeNetwork());
                var entry = Listing("Practice.Mod", "Map");
                ((CatalogResult)typeof(MainWindowController).GetField("listings", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(controller)).Items.Add(entry);
                CompleteTask((Task)ControllerCall(controller, "OpenDetail", entry));
                ControllerCall(controller, "CloseDetail");
                CompleteTask((Task)ControllerCall(controller, "OpenDetail", entry));
                Check(controller.Element<System.Windows.Controls.TextBlock>("StoreDetailDescription").Text == entry.Description, "Reopened mod details display the cached description");
                CloseController(controller, "Completed details can be closed, reopened, and shut down");
                var network = new PendingNetwork(); controller = LifecycleController("lifecycle-network", network);
                entry = Listing("Preview.Mod", "Map"); entry.PreviewUrls = new[] { "https://example.org/pending.png" };
                var listings = (CatalogResult)typeof(MainWindowController).GetField("listings", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(controller);
                listings.Items.Add(entry);
                var current = controller; var selectedEntry = entry;
                ControllerCall(current, "Fire", new Func<Task>(() => (Task)ControllerCall(current, "OpenDetail", selectedEntry)));
                ControllerCall(current, "BeginImages");
                ControllerCall(current, "Fire", new Func<Task>(() => (Task)ControllerCall(current, "Sync", true)));
                PumpUntil(() => Volatile.Read(ref network.Started) >= 3);
                CloseController(current, "Closing cancels concurrent details, preview, and catalog requests");
                Check(Volatile.Read(ref network.Active) == 0, "All pending network requests finish before the window closes");
                network = new PendingNetwork(); controller = LifecycleController("lifecycle-download", network); current = controller;
                ControllerCall(current, "Fire", new Func<Task>(() => (Task)ControllerCall(current, "InstallStore", Listing("Download.Mod", "Map"), None)));
                PumpUntil(() => Volatile.Read(ref network.Started) > 0);
                CloseController(current, "Closing during a mod download waits for cancellation and staging cleanup");
                var settings = (AppSettings)typeof(MainWindowController).GetField("settings", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(current);
                Check(Volatile.Read(ref network.Active) == 0 && Directory.GetDirectories(settings.GameDir, ".r5mm-stage-*").Length == 0, "Cancelled downloads leave no pending requests or staging directories");
                Check(Directory.GetDirectories(Path.Combine(settings.GameDir, "mods")).Length == 1, "Closing during a download preserves existing mod files");
                controller = LifecycleController("lifecycle-dialog"); current = controller;
                ControllerCall(current, "Fire", new Func<Task>(() => (Task)ControllerCall(current, "SourceInfo")));
                CloseController(current, "Closing dismisses an open application dialog");
                controller = LifecycleController("lifecycle-startup"); current = controller;
                ControllerCall(current, "Fire", new Func<Task>(() => (Task)ControllerCall(current, "Initialize")));
                CloseController(current, "Closing immediately during initialization completes normally");
                Check(!((DispatcherTimer)typeof(MainWindowController).GetField("refreshTimer", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(current)).IsEnabled, "Cancelled initialization does not restart the refresh timer");
            } finally { SynchronizationContext.SetSynchronizationContext(previous); }
        }
    }
}
