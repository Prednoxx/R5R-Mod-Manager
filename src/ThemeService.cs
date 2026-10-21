using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Microsoft.Win32;

namespace R5R {
    public static class ThemeService {
        public static readonly string[] Keys = { "obsidian", "aero_day", "aero_night", "aqua", "aurora", "eco", "metro", "sunburst", "sweetheart", "win11" };
        public static readonly string[] Names = { "Obsidian", "Aero Day", "Aero Night", "Aqua", "Aurora", "Eco", "Metro", "Sunburst", "Sweetheart", "Windows 11" };
        public static string Name(string key) { int index = Array.IndexOf(Keys, key); return index < 0 ? "Obsidian" : Names[index]; }
        public static bool DarkSystem() { try { using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) return key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0; } catch (Exception) { return false; } }
        static Color Accent(bool dark) {
            long value = 0xFFD47800; try { using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM")) if (key != null) value = Convert.ToInt64(key.GetValue("AccentColor", value)) & 0xFFFFFFFF; } catch (Exception) { }
            var rgb = new[] { (byte)(value & 255), (byte)((value >> 8) & 255), (byte)((value >> 16) & 255) }; double amount = dark ? 0.45 : 0.15; double target = dark ? 255 : 0;
            return Color.FromRgb((byte)Math.Round(rgb[0] + (target - rgb[0]) * amount), (byte)Math.Round(rgb[1] + (target - rgb[1]) * amount), (byte)Math.Round(rgb[2] + (target - rgb[2]) * amount));
        }
        public static void Apply(Window window, AppPaths paths, string theme) {
            if (Array.IndexOf(Keys, theme) < 0) theme = "obsidian";
            var file = theme == "win11" && DarkSystem() ? "win11_dark" : theme;
            var dictionary = (ResourceDictionary)XamlReader.Parse(File.ReadAllText(Path.Combine(paths.Root, "ui", "themes", file + ".xaml")));
            if (theme == "win11") foreach (var resourceKey in new[] { "Accent", "AccentStrong", "AccentBg", "AccentBorder" }) dictionary[resourceKey] = new SolidColorBrush(Accent(file == "win11_dark"));
            window.Resources.MergedDictionaries.Clear(); window.Resources.MergedDictionaries.Add(dictionary);
            var wallpaper = window.FindName("Wallpaper") as Image; if (wallpaper != null) wallpaper.Source = theme == "win11" || theme == "obsidian" ? null : MediaService.Bitmap(paths.Asset(Path.Combine("themes", theme + ".jpg")), 1920);
            var name = window.FindName("ThemeName") as TextBlock; if (name != null) name.Text = Name(theme);
            foreach (var id in new[] { "TitleShade", "TitleGloss" }) { var element = window.FindName(id) as UIElement; if (element != null) element.Visibility = theme == "win11" || theme == "obsidian" ? Visibility.Collapsed : Visibility.Visible; }
            var title = window.FindName("TitleLabel") as TextBlock; if (title != null) title.Effect = theme == "win11" || theme == "obsidian" ? null : new DropShadowEffect { BlurRadius = 8, ShadowDepth = 0, Opacity = 0.7 };
        }
        public static void Fit(Window window, Rect area) { double width = Math.Max(1, area.Width - 24), height = Math.Max(1, area.Height - 24); window.MinWidth = Math.Min(window.MinWidth, width); window.MinHeight = Math.Min(window.MinHeight, height); window.Width = Math.Min(window.Width, width); window.Height = Math.Min(window.Height, height); window.WindowStartupLocation = WindowStartupLocation.Manual; window.Left = area.Left + (area.Width - window.Width) / 2; window.Top = area.Top + (area.Height - window.Height) / 2; }
    }
}
