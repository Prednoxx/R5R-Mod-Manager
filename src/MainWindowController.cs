using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace R5R {
    public sealed partial class MainWindowController {
        public Window Window { get; private set; }
        readonly AppPaths paths;
        readonly AppSettings settings;
        readonly INetwork network;
        readonly CatalogService catalog;
        readonly PackageService packages;
        readonly MediaService media;
        readonly Installer installer;
        readonly IRecoveryService recovery;
        readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        readonly HashSet<Task> tasks = new HashSet<Task>();
        readonly Stopwatch startup = Stopwatch.StartNew();
        readonly DispatcherTimer refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(5) };
        readonly DispatcherTimer processTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        CancellationTokenSource scanCancellation, operationCancellation, detailCancellation, imageCancellation, queueCancellation;
        LibrarySnapshot library;
        CatalogResult listings = new CatalogResult();
        Dictionary<string, Receipt> receipts;
        HashSet<string> favorites;
        List<string> installs = new List<string>();
        string activeView = "store", detailKey;
        bool scanning, synchronizing, installing, mutating, filtersLoading, closing, allowClose;
        TaskCompletionSource<DialogAnswer> dialog;
        public T Element<T>(string name) where T : class { var value = Window.FindName(name) as T; if (value == null) throw new InvalidDataException("Missing interface element: " + name); return value; }
        void Text(string name, string value) { Element<TextBlock>(name).Text = value ?? ""; }
        void Visible(string name, bool visible) { Element<UIElement>(name).Visibility = visible ? Visibility.Visible : Visibility.Collapsed; }
        void Click(string name, Func<Task> handler) { Element<Button>(name).Click += (s, e) => Fire(handler); }
        Task Done() { return Task.FromResult(true); }
        public MainWindowController(AppPaths paths) {
            this.paths = paths; settings = AppSettings.Load(paths); network = new Network(paths.Cache); catalog = new CatalogService(paths, network); packages = new PackageService(network); media = new MediaService(paths, network); recovery = new WindowsRecovery(); installer = new Installer(recovery, new DirectoryMover(), paths.Log);
            receipts = new Dictionary<string, Receipt>(Json.Read<Dictionary<string, Receipt>>(System.IO.Path.Combine(paths.Data, "installed-packages.json")) ?? new Dictionary<string, Receipt>(), StringComparer.OrdinalIgnoreCase);
            var savedFavorites = Json.Read<FavoritesDocument>(System.IO.Path.Combine(paths.Data, "favorites.json")); favorites = new HashSet<string>(savedFavorites == null || savedFavorites.Keys == null ? new string[0] : savedFavorites.Keys, StringComparer.OrdinalIgnoreCase);
            var markup = File.ReadAllText(System.IO.Path.Combine(paths.Root, "ui", "MainWindow.xaml"));
            foreach (var part in new[] { new[] { "store resources", "Resources.xaml" }, new[] { "sidebar", "Sidebar.xaml" }, new[] { "store view", "Store.xaml" }, new[] { "utility view", "Utility.xaml" } }) markup = markup.Replace("<!-- " + part[0] + " -->", File.ReadAllText(System.IO.Path.Combine(paths.Root, "ui", part[1])));
            Window = (Window)XamlReader.Parse(markup); Window.Resources["StoreCardWidth"] = 232.0; ThemeService.Fit(Window, SystemParameters.WorkArea); ThemeService.Apply(Window, paths, settings.Theme);
            Window.Icon = MediaService.Bitmap(paths.Asset("icon.png"), 64); Element<Image>("TitleIcon").Source = Window.Icon; Visible("Mascot", false); Text("FooterText", "v3.3  ·  Prednoxx");
            WireEvents(); InitStore(); SetView("store");
            bool started = false; Window.ContentRendered += (s, e) => { if (!started) { started = true; Trace("rendered"); Fire(Initialize); } };
            Window.Closing += OnClosing;
            refreshTimer.Tick += (s, e) => Fire(() => Sync(false));
            processTimer.Tick += (s, e) => { bool running = GameLocator.Running(); Text("LaunchText", running ? "Running" : "Launch"); Element<Button>("BtnGlobalLaunch").Content = running ? "R5Reloaded is running" : "Launch R5Reloaded"; };
        }
        void Trace(string message) { try { File.AppendAllText(System.IO.Path.Combine(paths.Data, "startup-trace.log"), startup.ElapsedMilliseconds.ToString().PadLeft(7) + " ms  " + message + Environment.NewLine); } catch (IOException) { } }
        async void Fire(Func<Task> action) {
            if (closing) return; Task task = null;
            try { task = action(); tasks.Add(task); await task; }
            catch (OperationCanceledException) { }
            catch (Exception ex) { paths.Log(ex.ToString()); if (!closing) { var pending = Window.Dispatcher.BeginInvoke(new Action(() => Fire(async () => { await ShowDialog("Error", ex.Message, "OK", null, false); }))); } }
            finally { if (task != null) tasks.Remove(task); }
        }
        async Task Initialize() {
            File.WriteAllText(System.IO.Path.Combine(paths.Data, "startup-trace.log"), ""); Trace("window ready");
            try { listings = await Task.Run(() => catalog.ReadCache(), lifetime.Token); SetStoreFilters(); FillStore(); BeginImages(); } catch (Exception ex) { paths.Log("Catalog cache: " + ex.Message); }
            Fire(() => Sync(false)); refreshTimer.Start(); processTimer.Start();
            if (GameLocator.Valid(settings.GameDir)) await SelectGame(settings.GameDir);
            else {
                settings.GameDir = null; Status("Looking for R5Reloaded", false);
                installs = await Task.Run(() => GameLocator.Find(paths.Root, lifetime.Token), lifetime.Token);
                if (String.IsNullOrEmpty(settings.GameDir) && installs.Count > 0) await SelectGame(installs[0]);
                else if (String.IsNullOrEmpty(settings.GameDir)) { Status("R5Reloaded not found. Choose the game folder in Settings.", true); FillLibrary(); FillStore(); }
            }
            Trace("startup complete");
        }
        async void OnClosing(object sender, CancelEventArgs e) {
            if (allowClose) return; e.Cancel = true; if (closing) return; closing = true; lifetime.Cancel(); if (operationCancellation != null) operationCancellation.Cancel(); if (queueCancellation != null) queueCancellation.Cancel(); if (scanCancellation != null) scanCancellation.Cancel();
            if (dialog != null) dialog.TrySetCanceled(); refreshTimer.Stop(); processTimer.Stop();
            try { await Task.WhenAll(tasks.ToArray()); } catch (Exception ex) { if (!(ex is OperationCanceledException)) paths.Log("Shutdown: " + ex.Message); }
            allowClose = true; var pending = Window.Dispatcher.BeginInvoke(new Action(() => Window.Close()));
        }
        void Status(string message, bool warning) { Text("StatusText", message); Element<Ellipse>("StatusDot").SetResourceReference(System.Windows.Shapes.Shape.FillProperty, warning ? "Warn" : "TextFaint"); }
        void SetView(string view) {
            activeView = view; Visible("StoreView", view == "store"); Visible("LibraryView", view == "library"); Visible("UtilityView", view == "downloads" || view == "settings"); Visible("SettingsView", view == "settings"); Visible("DownloadsView", view == "downloads");
            Text("SettingsGamePath", String.IsNullOrEmpty(settings.GameDir) ? "Not selected" : settings.GameDir);
            foreach (var pair in new[] { new[] { "BtnNavStore", "store" }, new[] { "BtnNavLibrary", "library" }, new[] { "BtnNavSettings", "settings" }, new[] { "BtnNavDownloads", "downloads" } }) Element<Button>(pair[0]).SetResourceReference(Control.BackgroundProperty, pair[1] == view ? "RowSel" : "WindowBg");
        }
        void WireEvents() {
            Click("BtnClose", () => { Window.Close(); return Done(); }); Click("BtnMin", () => { Window.WindowState = WindowState.Minimized; return Done(); }); Click("BtnMax", () => { Window.WindowState = Window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; return Done(); });
            Window.StateChanged += (s, e) => { Element<Button>("BtnMax").Content = Window.WindowState == WindowState.Maximized ? "\uE923" : "\uE922"; Element<FrameworkElement>("Root").Margin = new Thickness(Window.WindowState == WindowState.Maximized ? 7 : 0); };
            Click("BtnNavStore", () => { SetView("store"); return Done(); }); Click("BtnNavLibrary", () => { SetView("library"); return Done(); }); Click("BtnNavDownloads", () => { SetView("downloads"); return Done(); }); Click("BtnNavSettings", () => { SetView("settings"); return Done(); });
            Click("BtnTheme", () => { ShowThemes(); return Done(); }); Click("BtnSettingsTheme", () => { ShowThemes(); return Done(); }); Click("BtnSettingsGame", BrowseGame); Click("BtnChange", () => { ShowGameMenu(); return Done(); });
            Click("BtnGlobalLaunch", LaunchGame); Click("BtnLaunch", LaunchGame);
            Click("DlgOk", () => { CompleteDialog(true); return Done(); }); Click("DlgCancel", () => { CompleteDialog(false); return Done(); });
            Click("BtnRefresh", ReloadLibrary); Click("BtnEnableAll", () => ModifyLibrary(l => l.SetAll(true))); Click("BtnDisableAll", () => ModifyLibrary(l => l.SetAll(false)));
            Click("BtnPreset", () => { ShowPresets(); return Done(); }); Click("BtnPresetSave", SavePreset); Click("BtnPresetNew", NewPreset); Click("BtnPresetDelete", DeletePreset);
            Click("BtnOpenMod", () => { var mod = Element<ListBox>("ModList").SelectedItem as ModItem; if (mod != null) NativeShell.OpenFolder(mod.Folder); return Done(); });
            Click("BtnModsFolder", () => { if (RequireGame()) NativeShell.OpenFolder(System.IO.Path.Combine(settings.GameDir, "mods")); return Done(); });
            Click("BtnRemove", UninstallSelected); Click("BtnRestore", ShowRestore); Click("BtnFixIssues", FixIssues);
            Click("BtnInstallZip", InstallZip); Click("BtnInstallDir", InstallFolder);
            Element<TextBox>("SearchBox").TextChanged += (s, e) => FillLibrary(); Element<ListBox>("ModList").SelectionChanged += (s, e) => LibraryDetails();
            Element<ListBox>("ModList").AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((s, e) => { var box = e.OriginalSource as CheckBox; if (box != null && box.DataContext is ModItem) { var mod = (ModItem)box.DataContext; Fire(() => ToggleMod(mod)); } }));
            Element<Hyperlink>("DetSource").Click += (s, e) => Fire(() => { var selected = Element<ListBox>("ModList").SelectedItem as ModItem; var entry = selected == null ? null : listings.Items.FirstOrDefault(x => String.Equals(x.ModId, selected.Id, StringComparison.OrdinalIgnoreCase)); if (entry != null) NativeShell.OpenUrl(entry.PageUrl); return Done(); });
            Window.PreviewKeyDown += OnKeyDown;
            Window.PreviewDragOver += (s, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) && !installing && !mutating ? DragDropEffects.Copy : DragDropEffects.None; Visible("DropLayer", e.Effects != DragDropEffects.None); e.Handled = true; };
            Window.DragLeave += (s, e) => Visible("DropLayer", false);
            Window.PreviewDrop += (s, e) => { Visible("DropLayer", false); e.Handled = true; if (dialog != null || installing || mutating) return; var files = e.Data.GetData(DataFormats.FileDrop) as string[]; if (files != null) Fire(() => InstallLocal(files)); };
        }
        void OnKeyDown(object sender, KeyEventArgs e) {
            if (dialog != null) { if (e.Key == Key.Escape) { e.Handled = true; CompleteDialog(Element<Button>("DlgCancel").Visibility != Visibility.Visible); } else if (e.Key == Key.Enter) { e.Handled = true; CompleteDialog(Keyboard.FocusedElement != Element<Button>("DlgCancel")); } return; }
            if (e.Key == Key.Escape && new[] { "StoreBuild", "StoreCategory", "StoreSourceFilter", "StoreSort" }.Any(n => Element<ComboBox>(n).IsDropDownOpen)) return;
            bool control = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
            if (control && e.Key == Key.F && (activeView == "store" || activeView == "library")) { e.Handled = true; if (activeView == "store") CloseDetail(); Element<TextBox>(activeView == "store" ? "StoreSearch" : "SearchBox").Focus(); }
            else if (e.Key == Key.F5 && (activeView == "store" || activeView == "library")) { e.Handled = true; Fire(activeView == "store" ? (Func<Task>)(() => Sync(true)) : ReloadLibrary); }
            else if (activeView == "store" && e.Key == Key.Escape) { e.Handled = true; if (Element<UIElement>("ImageOverlay").Visibility == Visibility.Visible) Visible("ImageOverlay", false); else CloseDetail(); }
            else if (activeView == "library" && e.Key == Key.Delete && !(Keyboard.FocusedElement is TextBoxBase)) { e.Handled = true; Fire(UninstallSelected); }
        }
        sealed class DialogAnswer { public bool Accepted; public string Text; }
        async Task<DialogAnswer> ShowDialog(string title, string message, string ok, string cancel, bool input) {
            if (dialog != null) return new DialogAnswer(); lifetime.Token.ThrowIfCancellationRequested();
            Text("DlgTitle", title); Text("DlgMsg", message); Visible("DlgMsg", !String.IsNullOrEmpty(message)); Element<Button>("DlgOk").Content = ok; Element<Button>("DlgCancel").Content = cancel; Visible("DlgCancel", !String.IsNullOrEmpty(cancel)); Visible("DlgInputWrap", input); Element<TextBox>("DlgInput").Text = "";
            var previousFocus = Keyboard.FocusedElement;
            var layer = Element<FrameworkElement>("DialogLayer"); KeyboardNavigation.SetTabNavigation(layer, KeyboardNavigationMode.Cycle); KeyboardNavigation.SetControlTabNavigation(layer, KeyboardNavigationMode.Cycle);
            bool destructive = ok == "Uninstall" || ok == "Delete"; Element<Button>("DlgOk").Style = (Style)Window.FindResource(destructive ? "BtnDanger" : "BtnAccent"); Text("DlgIcon", destructive ? "\uE74D" : "\uE946");
            Visible("DialogLayer", true); dialog = new TaskCompletionSource<DialogAnswer>(); var completion = dialog;
            var pending = Window.Dispatcher.BeginInvoke(new Action(() => { if (input) Element<TextBox>("DlgInput").Focus(); else Element<Button>("DlgOk").Focus(); }), DispatcherPriority.Input);
            try { using (lifetime.Token.Register(() => completion.TrySetCanceled())) return await completion.Task; }
            finally { if (dialog == completion) dialog = null; Visible("DialogLayer", false); if (!closing && previousFocus != null) Keyboard.Focus(previousFocus); }
        }
        void CompleteDialog(bool accepted) { if (dialog != null) dialog.TrySetResult(new DialogAnswer { Accepted = accepted, Text = Element<TextBox>("DlgInput").Text.Trim() }); }
        ContextMenu Menu(string target) { var menu = new ContextMenu { PlacementTarget = Element<FrameworkElement>(target), Placement = PlacementMode.Bottom, Style = (Style)Window.FindResource("MenuS") }; return menu; }
        MenuItem Item(string label, Func<Task> action) { var item = new MenuItem { Header = label, Style = (Style)Window.FindResource("MenuItemS") }; item.Click += (s, e) => Fire(action); return item; }
        void ShowThemes() {
            var menu = Menu("BtnTheme");
            foreach (var theme in ThemeService.Keys) { var key = theme; var row = new StackPanel { Orientation = Orientation.Horizontal }; row.Children.Add(new Image { Source = MediaService.Bitmap(paths.Asset(System.IO.Path.Combine("themes", key + "_thumb.jpg")), 128), Width = 64, Height = 36, Margin = new Thickness(0, 0, 12, 0), Stretch = Stretch.UniformToFill }); row.Children.Add(new TextBlock { Text = ThemeService.Name(key) + (settings.Theme == key ? "  ✓" : ""), VerticalAlignment = VerticalAlignment.Center }); var item = Item(ThemeService.Name(key), () => { settings.Theme = key; ThemeService.Apply(Window, paths, key); settings.Save(paths); LibraryDetails(); return Done(); }); item.Header = row; menu.Items.Add(item); }
            menu.IsOpen = true;
        }
        bool RequireGame() { if (GameLocator.Valid(settings.GameDir)) return true; SetView("settings"); Status("Choose the R5Reloaded game folder in Settings.", true); return false; }
        async Task BrowseGame() { if (mutating) { Status("Wait for the current mod operation to finish.", true); return; } var picked = NativeShell.PickFolder(new WindowInteropHelper(Window).Handle, "Choose the R5Reloaded folder", settings.GameDir); if (String.IsNullOrEmpty(picked)) return; var game = await Task.Run(() => GameLocator.Resolve(picked), lifetime.Token); if (game == null) { await ShowDialog("R5Reloaded not found", "The selected folder does not contain r5apex.exe or r5apex_ds.exe.", "OK", null, false); return; } await SelectGame(game); }
        void ShowGameMenu() { var menu = Menu("BtnChange"); foreach (var game in installs) { var path = game; menu.Items.Add(Item(path + (String.Equals(path, settings.GameDir, StringComparison.OrdinalIgnoreCase) ? "  ✓" : ""), () => SelectGame(path))); } menu.Items.Add(Item("Browse…", BrowseGame)); menu.IsOpen = true; }
        async Task SelectGame(string game) {
            if (mutating) { Status("Wait for the current mod operation to finish.", true); return; }
            if (!GameLocator.Valid(game)) throw new IOException("The selected folder is not an R5Reloaded installation.");
            game = Files.DirectoryPath(game); if (!String.Equals(game, settings.GameDir, StringComparison.OrdinalIgnoreCase)) { if (operationCancellation != null) operationCancellation.Cancel(); if (queueCancellation != null) queueCancellation.Cancel(); }
            settings.GameDir = game; if (!installs.Contains(game, StringComparer.OrdinalIgnoreCase)) installs.Insert(0, game); settings.Save(paths); Text("GamePath", game); Text("SettingsGamePath", game); Text("SidebarGameStatus", "R5Reloaded S3 selected"); await ReloadLibrary();
        }
        Task LaunchGame() { if (!RequireGame()) return Done(); if (installing || mutating || scanning) { Status("Wait for the current mod operation to finish before launching R5Reloaded.", true); return Done(); } if (GameLocator.Running()) { Status("R5Reloaded is already running.", true); return Done(); } var executable = System.IO.Path.Combine(settings.GameDir, "r5apex.exe"); if (!File.Exists(executable)) throw new IOException("r5apex.exe was not found in the selected game folder."); Process.Start(new ProcessStartInfo(executable) { WorkingDirectory = settings.GameDir, UseShellExecute = true }); Status("Launching R5Reloaded", false); return Done(); }
    }
}
