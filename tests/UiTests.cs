using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;

namespace R5R.Tests {
    internal static partial class TestRunner {
        static void UiTests() {
            var root = Area("interface"); var paths = new AppPaths(appRoot, Path.Combine(root, "data")); var settings = new AppSettings { GameDir = Game(root) }; settings.Save(paths);
            var controller = new MainWindowController(paths); var window = controller.Window;
            Check(window.Title == "R5R Mod Manager" && controller.Element<TextBlock>("FooterText").Text.Contains("3.3"), "C# controller loads the complete WPF application layout");
            foreach (var view in new[] { "StoreView", "LibraryView", "SettingsView", "DownloadsView", "ImageOverlay", "DialogLayer" }) Check(window.FindName(view) != null, "WPF layout includes " + view);
            controller.Element<Button>("BtnNavLibrary").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Check(controller.Element<UIElement>("LibraryView").Visibility == Visibility.Visible && controller.Element<UIElement>("StoreView").Visibility == Visibility.Collapsed, "Library navigation switches the active view");
            controller.Element<Button>("BtnNavSettings").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Check(controller.Element<UIElement>("SettingsView").Visibility == Visibility.Visible && controller.Element<TextBlock>("SettingsGamePath").Text == settings.GameDir, "Settings navigation displays the selected game path");
            controller.Element<Button>("BtnNavDownloads").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Check(controller.Element<UIElement>("DownloadsView").Visibility == Visibility.Visible, "Download navigation displays the operation view");
            controller.Element<Button>("BtnNavStore").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Check(controller.Element<UIElement>("StoreView").Visibility == Visibility.Visible, "Store navigation returns from utility views");
            foreach (var theme in ThemeService.Keys) { ThemeService.Apply(window, paths, theme); Check(window.FindResource("Text") is Brush && window.FindResource("PanelBg") is Brush, "Theme resources load for " + theme); }
            ThemeService.Apply(window, paths, "obsidian"); var previous = controller.Element<Button>("BtnNavStore").Background; ThemeService.Apply(window, paths, "aero_day"); Check(!Object.ReferenceEquals(previous, controller.Element<Button>("BtnNavStore").Background), "Active navigation follows theme changes");
            ThemeService.Fit(window, new Rect(0, 0, 1200, 700)); Check(window.Top >= 0 && window.Left >= 0 && window.Height + window.Top <= 700 && window.Width + window.Left <= 1200, "Window startup bounds fit smaller desktop work areas");
            var card = new CatalogCard { Entry = Listing("Preview.Mod", "Map"), PreviewPath = Path.Combine(appRoot, "assets", "icon.png") }; var image = new Image { DataContext = card }; image.SetBinding(Image.SourceProperty, new Binding("PreviewPath")); image.Dispatcher.Invoke(new Action(() => { }), DispatcherPriority.DataBind); Check(image.Source != null && image.Source.Width > 0, "Catalog cards bind previews directly to WPF images");
            var favorite = new FavoritesDocument { Keys = new[] { "fixture:Preview.Mod" } }; Json.Write(Path.Combine(root, "favorites.json"), favorite); Check(Json.Read<FavoritesDocument>(Path.Combine(root, "favorites.json")).Keys.Single() == favorite.Keys[0], "Favorites persist across C# application sessions");
            window.Close(); window.Dispatcher.Invoke(new Action(() => { }), DispatcherPriority.ApplicationIdle);
        }
    }
}
