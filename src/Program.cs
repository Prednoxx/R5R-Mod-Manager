using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;

[assembly: AssemblyTitle("R5R Mod Manager")]
[assembly: AssemblyProduct("R5R Mod Manager")]
[assembly: AssemblyCompany("Prednoxx")]
[assembly: AssemblyCopyright("Copyright (C) 2026 Prednoxx")]
[assembly: AssemblyVersion("3.3.0.0")]
[assembly: AssemblyFileVersion("3.3.0.0")]
namespace R5R {
    public static class Program {
        [STAThread] public static int Main(string[] arguments) {
            AppPaths paths = null;
            try {
                var data = Environment.GetEnvironmentVariable("R5MM_SETTINGS_DIR"); if (String.IsNullOrEmpty(data)) data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "R5RModManager");
                paths = new AppPaths(AppDomain.CurrentDomain.BaseDirectory, data);
                bool first; using (var mutex = new Mutex(true, "Local\\R5RModManager-" + Files.Hash(paths.Data.ToUpperInvariant()).Substring(0, 24), out first)) {
                    if (!first) { MessageBox.Show("R5R Mod Manager is already running.", "R5R Mod Manager", MessageBoxButton.OK, MessageBoxImage.Information); return 0; }
                    var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                    var controller = new MainWindowController(paths); app.MainWindow = controller.Window;
                    app.DispatcherUnhandledException += (s, e) => { paths.Log(e.Exception.ToString()); MessageBox.Show(controller.Window, e.Exception.Message, "R5R Mod Manager", MessageBoxButton.OK, MessageBoxImage.Error); e.Handled = true; };
                    return app.Run(controller.Window);
                }
            } catch (Exception ex) { if (paths != null) paths.Log(ex.ToString()); MessageBox.Show(ex.Message, "R5R Mod Manager", MessageBoxButton.OK, MessageBoxImage.Error); return 1; }
        }
    }
}
