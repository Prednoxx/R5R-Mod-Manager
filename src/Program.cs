using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("R5R Mod Manager")]
[assembly: AssemblyProduct("R5R Mod Manager")]
[assembly: AssemblyCompany("Prednoxx")]
[assembly: AssemblyCopyright("Copyright (C) 2026 Prednoxx")]
[assembly: AssemblyVersion("3.2.0.0")]
internal static class Program {
    [STAThread]
    private static void Main() {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        Environment.SetEnvironmentVariable("R5MM_SELF", Application.ExecutablePath);
        try {
            using (Runspace runspace = RunspaceFactory.CreateRunspace()) {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell shell = PowerShell.Create()) {
                    shell.Runspace = runspace;
                    shell.AddScript(File.ReadAllText(Path.Combine(root, "app.ps1")));
                    shell.Invoke();
                    if (shell.HadErrors) throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                }
            }
        } catch (Exception error) {
            string data = Environment.GetEnvironmentVariable("R5MM_SETTINGS_DIR") ??
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "R5RModManager");
            Directory.CreateDirectory(data);
            File.AppendAllText(Path.Combine(data, "error.log"), DateTime.Now.ToString("s") + " " + error + Environment.NewLine);
            MessageBox.Show(error.Message, "R5R Mod Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
