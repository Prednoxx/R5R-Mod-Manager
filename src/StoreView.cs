using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace R5R {
    public sealed partial class MainWindowController {
        void InitStore() {
            foreach (var name in new[] { "Name", "Recently updated", "Most downloaded", "Installed first" }) Element<ComboBox>("StoreSort").Items.Add(name);
            Element<ComboBox>("StoreSort").SelectedIndex = 0;
            Click("BtnStoreRefresh", () => Sync(true)); Click("BtnStoreBack", () => { CloseDetail(); return Done(); }); Click("BtnStoreInstall", () => InstallStore(CurrentEntry(), lifetime.Token));
            Click("BtnStorePage", () => { var entry = CurrentEntry(); if (entry != null) NativeShell.OpenUrl(entry.PageUrl); return Done(); });
            Click("BtnStoreFavorite", () => { var entry = CurrentEntry(); if (entry != null) { if (!favorites.Remove(entry.Key)) favorites.Add(entry.Key); Json.Write(System.IO.Path.Combine(paths.Data, "favorites.json"), new FavoritesDocument { Keys = favorites.ToArray() }); FillStore(); UpdateStoreDetails(); } return Done(); });
            Click("BtnStoreClear", () => { filtersLoading = true; Element<TextBox>("StoreSearch").Clear(); foreach (var name in new[] { "StoreBuild", "StoreSourceFilter", "StoreCategory" }) Element<ComboBox>(name).SelectedIndex = 0; Element<CheckBox>("StoreFavoritesOnly").IsChecked = false; filtersLoading = false; FillStore(); return Done(); });
            foreach (var name in new[] { "BtnStoreSources", "BtnSidebarSources", "BtnSettingsSources" }) Click(name, SourceInfo);
            foreach (var name in new[] { "BtnStoreCancel", "BtnDownloadCancel" }) Click(name, () => { if (operationCancellation != null) operationCancellation.Cancel(); if (queueCancellation != null) queueCancellation.Cancel(); UpdateDownload("Cancelling download", null); return Done(); });
            Click("BtnImageClose", () => { Visible("ImageOverlay", false); return Done(); });
            Element<TextBox>("StoreSearch").TextChanged += (s, e) => FillStore(); Element<CheckBox>("StoreFavoritesOnly").Click += (s, e) => FillStore();
            foreach (var name in new[] { "StoreBuild", "StoreSourceFilter", "StoreCategory", "StoreSort" }) Element<ComboBox>(name).SelectionChanged += (s, e) => FillStore();
            var list = Element<ListBox>("StoreList"); list.SelectionChanged += (s, e) => UpdateStoreDetails();
            list.SizeChanged += (s, e) => { double available = list.ActualWidth - 22; if (available > 0) Window.Resources["StoreCardWidth"] = Math.Floor(available / Math.Max(1, Math.Floor(available / 235))) - 14; };
            list.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((s, e) => { var button = ParentButton(e.OriginalSource as DependencyObject); var card = button == null ? null : button.DataContext as CatalogCard; if (card == null) return; e.Handled = true; if (Convert.ToString(button.Tag) == "details") Fire(() => OpenDetail(card.Entry)); else if (Convert.ToString(button.Tag) == "install") Fire(() => InstallStore(card.Entry, lifetime.Token)); }));
            list.KeyDown += (s, e) => { if (e.Key == Key.Enter && !(e.OriginalSource is Button)) { var card = list.SelectedItem as CatalogCard; if (card != null) { e.Handled = true; Fire(() => OpenDetail(card.Entry)); } } };
            Element<ItemsControl>("StoreGallery").AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((s, e) => { var button = ParentButton(e.OriginalSource as DependencyObject); if (button != null && Convert.ToString(button.Tag) == "gallery") { Element<Image>("FullPreview").Source = MediaService.Bitmap(Convert.ToString(button.DataContext), 1600); Visible("ImageOverlay", true); e.Handled = true; } }));
            SetStoreFilters(); FillStore();
        }
        static Button ParentButton(DependencyObject value) { while (value != null) { var button = value as Button; if (button != null) return button; value = VisualTreeHelper.GetParent(value); } return null; }
        void SetStoreFilters() {
            filtersLoading = true;
            try {
                var values = new Dictionary<string, IEnumerable<string>> { { "StoreBuild", listings.Items.Select(e => e.Build) }, { "StoreSourceFilter", listings.Items.Select(e => e.Source) }, { "StoreCategory", listings.Items.SelectMany(e => CatalogService.Categories(e.Category)) } };
                foreach (var name in values.Keys) { var control = Element<ComboBox>(name); var selected = control.SelectedItem as string; control.Items.Clear(); control.Items.Add(name == "StoreBuild" ? "All builds" : name == "StoreSourceFilter" ? "All sources" : "All categories"); foreach (var value in values[name].Where(s => !String.IsNullOrEmpty(s)).Distinct().OrderBy(s => s)) control.Items.Add(value); control.SelectedItem = selected != null && control.Items.Contains(selected) ? selected : control.Items[0]; }
            } finally { filtersLoading = false; }
        }
        string FilterValue(string name) { var control = Element<ComboBox>(name); return control.SelectedIndex > 0 ? control.SelectedItem as string : null; }
        void FillStore() {
            if (filtersLoading) return; var list = Element<ListBox>("StoreList"); var previous = list.SelectedItem as CatalogCard;
            var rows = CatalogService.Filter(listings.Items, Element<TextBox>("StoreSearch").Text, FilterValue("StoreBuild"), FilterValue("StoreSourceFilter"), FilterValue("StoreCategory"), Element<CheckBox>("StoreFavoritesOnly").IsChecked == true ? favorites : null);
            switch (Convert.ToString(Element<ComboBox>("StoreSort").SelectedItem)) {
                case "Most downloaded": rows = rows.OrderByDescending(e => e.Downloads).ThenBy(e => e.Name).ToList(); break;
                case "Recently updated": rows = rows.OrderByDescending(e => e.Updated, StringComparer.Ordinal).ThenBy(e => e.Name).ToList(); break;
                case "Installed first": rows = rows.OrderBy(e => library != null && library.Find(e.ModId) != null ? 0 : 1).ThenBy(e => e.Name).ToList(); break;
                default: rows = rows.OrderBy(e => e.Name).ThenBy(e => e.Author).ToList(); break;
            }
            var cards = rows.Select(e => new CatalogCard { Entry = e, PreviewPath = media.Preview(e), Status = CatalogService.Status(e, library, receipts), CanInstall = e.Build == CatalogService.SupportedBuild && e.InstallKind != "manual" && !installing && !mutating && !scanning }).ToList();
            list.ItemsSource = cards; list.SelectedItem = previous == null ? cards.FirstOrDefault() : cards.FirstOrDefault(c => c.Key == previous.Key) ?? cards.FirstOrDefault();
            Text("StoreCount", cards.Count + (cards.Count == 1 ? " mod" : " mods") + "  /  " + listings.Items.Count + " in catalog"); Text("StoreEmpty", listings.Items.Count == 0 ? "No catalog available. Refresh to retry." : "No matching mods"); Visible("StoreEmpty", cards.Count == 0); UpdateStoreDetails();
        }
        CatalogEntry CurrentEntry() { if (!String.IsNullOrEmpty(detailKey)) return listings.Items.FirstOrDefault(e => e.Key == detailKey); var selected = Element<ListBox>("StoreList").SelectedItem as CatalogCard; return selected == null ? null : selected.Entry; }
        void UpdateStoreDetails() {
            if (String.IsNullOrEmpty(detailKey)) return; var entry = CurrentEntry(); if (entry == null) { CloseDetail(); return; }
            Text("StoreDetailName", entry.Name); Text("StoreDetailAuthor", entry.Author); Text("StoreDetailCategory", entry.Category); Text("StoreDetailSource", entry.Source); Text("StoreDetailVersion", String.IsNullOrEmpty(entry.Version) ? "Unspecified" : entry.Version); Text("StoreDetailDownloads", entry.Downloads > 0 ? entry.Downloads.ToString("N0") : "Unavailable");
            var status = CatalogService.Status(entry, library, receipts); var meta = new List<string> { entry.Build }; if (status != entry.Build) meta.Add(status); if (entry.Size > 0) meta.Add((entry.Size / 1048576.0).ToString("N1") + " MB"); DateTime updated; if (DateTime.TryParse(entry.Updated, out updated)) meta.Add("Updated " + updated.ToString("MMM d, yyyy")); Text("StoreDetailMeta", String.Join("  ·  ", meta));
            Text("StoreDetailDependencies", entry.Dependencies != null && entry.Dependencies.Length > 0 ? "Dependencies: " + String.Join(", ", entry.Dependencies) : "");
            Element<Button>("BtnStoreFavorite").Content = favorites.Contains(entry.Key) ? "★ Favorited" : "☆ Favorite";
            var button = Element<Button>("BtnStoreInstall"); button.IsEnabled = false;
            if (entry.Build != CatalogService.SupportedBuild) { Text("StoreCompatibility", "Requires " + entry.Build + ". Installation is supported for R5Reloaded S3 only."); button.Content = "Different game build"; }
            else if (entry.InstallKind == "manual") { Text("StoreCompatibility", "Follow the installation instructions on the source page."); button.Content = "Manual installation"; }
            else if (!GameLocator.Valid(settings.GameDir)) { Text("StoreCompatibility", "Choose the R5Reloaded game folder before installing mods."); button.Content = "Choose game folder"; button.IsEnabled = !installing && !mutating && !scanning; }
            else { Text("StoreCompatibility", "Installs to the selected R5Reloaded mods folder. Existing copies require replacement confirmation."); button.Content = status == "Installed" ? "Reinstall" : status == "Update available" ? "Update" : status == "Newer installed" ? "Install older version" : status == "Different version" ? "Change version" : "Install"; button.IsEnabled = !installing && !mutating && !scanning; }
        }
        async Task OpenDetail(CatalogEntry entry) {
            if (entry == null) return; if (detailCancellation != null) detailCancellation.Cancel(); detailCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); var token = detailCancellation.Token;
            detailKey = entry.Key; Visible("StoreBrowse", false); Visible("StoreDetails", true); Element<ScrollViewer>("StoreDetails").ScrollToTop(); Element<Image>("StoreHero").Source = MediaService.Bitmap(media.Preview(entry), 1200); Text("StoreDetailDescription", entry.Description); Element<ItemsControl>("StoreGallery").ItemsSource = null; Visible("StoreGalleryWrap", false); UpdateStoreDetails();
            try { var details = await Task.Run(() => media.Details(entry, token), token); if (token.IsCancellationRequested || detailKey != entry.Key || closing) return; Text("StoreDetailDescription", details.Body); var images = (details.Images ?? new string[0]).Where(File.Exists).ToArray(); Element<ItemsControl>("StoreGallery").ItemsSource = images; Visible("StoreGalleryWrap", images.Length > 0); if (images.Length > 0) Element<Image>("StoreHero").Source = MediaService.Bitmap(images[0], 1200); }
            catch (OperationCanceledException) { } catch (Exception ex) { paths.Log("Mod details: " + ex.Message); }
        }
        void CloseDetail() { detailKey = null; if (detailCancellation != null) detailCancellation.Cancel(); Visible("StoreBrowse", true); Visible("StoreDetails", false); Visible("ImageOverlay", false); }
        async Task Sync(bool force) {
            if (synchronizing || closing) return; synchronizing = true; Element<Button>("BtnStoreRefresh").IsEnabled = false;
            try {
                var progress = new Progress<string>(message => { if (!closing) Text("StoreSyncText", message); });
                var result = await Task.Run(() => catalog.Sync(force, progress, lifetime.Token), lifetime.Token); lifetime.Token.ThrowIfCancellationRequested(); listings = result; SetStoreFilters(); FillStore();
                int unavailable = result.Sources.Count(s => s.State != "Current"); Text("StoreSyncText", unavailable == 0 ? "Catalog current" : unavailable + (unavailable == 1 ? " source unavailable" : " sources unavailable")); Element<TextBlock>("StoreSyncText").ToolTip = String.Join(Environment.NewLine, result.Sources.Select(s => s.Name + ": " + s.State + (String.IsNullOrEmpty(s.Error) ? "" : " — " + s.Error))); BeginImages(); LibraryDetails();
            } catch (OperationCanceledException) { } catch (Exception ex) { paths.Log("Catalog: " + ex.Message); Text("StoreSyncText", "Catalog unavailable. Refresh to retry."); }
            finally { synchronizing = false; Element<Button>("BtnStoreRefresh").IsEnabled = true; }
        }
        void BeginImages() {
            if (imageCancellation != null) imageCancellation.Cancel(); imageCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); var token = imageCancellation.Token; var entries = listings.Items.ToArray();
            Fire(async () => { try { await Task.Run(() => media.CacheImages(entries, (key, path) => Window.Dispatcher.BeginInvoke(new Action(() => { if (closing || token.IsCancellationRequested) return; foreach (var row in Element<ListBox>("StoreList").Items.OfType<CatalogCard>().Where(c => c.Key == key)) row.PreviewPath = path; if (detailKey == key && Element<ItemsControl>("StoreGallery").Items.Count == 0) Element<Image>("StoreHero").Source = MediaService.Bitmap(path, 1200); })), token), token); } catch (OperationCanceledException) { } });
        }
        async Task SourceInfo() { var text = String.Join(Environment.NewLine + Environment.NewLine, listings.Sources.Select(s => s.Name + " — " + s.State + " (" + s.Count + " listings)" + (String.IsNullOrEmpty(s.Error) ? "" : Environment.NewLine + s.Error))); await ShowDialog("Catalog sources", text.Length > 0 ? text : "Sources are loading.", "OK", null, false); }
    }
}
