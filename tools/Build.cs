using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;

internal static class Build {
    static string root, output;
    static int Run(string executable, string arguments) { var process = Process.Start(new ProcessStartInfo(executable, arguments) { WorkingDirectory = root, UseShellExecute = false }); process.WaitForExit(); return process.ExitCode; }
    static string Q(string value) { return "\"" + value + "\""; }
    static void Copy(string source, string destination) { if (Directory.Exists(source)) { Directory.CreateDirectory(destination); foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), true); foreach (var dir in Directory.GetDirectories(source)) Copy(dir, Path.Combine(destination, Path.GetFileName(dir))); } else { Directory.CreateDirectory(Path.GetDirectoryName(destination)); File.Copy(source, destination, true); } }
    static void Compile(bool tests) {
        var framework = RuntimeEnvironment.GetRuntimeDirectory(); var files = Directory.GetFiles(Path.Combine(root, "src"), "*.cs").ToList(); if (tests) files.AddRange(Directory.GetFiles(Path.Combine(root, "tests"), "*.cs"));
        var references = new List<string> { "System.dll", "System.Core.dll", "System.Web.Extensions.dll", "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll", "System.Xaml.dll", "Microsoft.CSharp.dll", "WPF\\WindowsBase.dll", "WPF\\PresentationCore.dll", "WPF\\PresentationFramework.dll" }.Select(p => Path.Combine(framework, p)).ToList();
        var basic = Directory.GetFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Microsoft.NET", "assembly", "GAC_MSIL", "Microsoft.VisualBasic"), "Microsoft.VisualBasic.dll", SearchOption.AllDirectories).First(); references.Add(basic);
        var target = Path.Combine(output, tests ? "R5R.Tests.exe" : "R5R Mod Manager.exe"); var arguments = "/nologo /optimize+ /platform:x64 /target:" + (tests ? "exe" : "winexe") + " /main:" + (tests ? "R5R.Tests.TestRunner" : "R5R.Program") + " /out:" + Q(target) + " /win32icon:" + Q(Path.Combine(root, "assets", "app.ico")) + " " + String.Join(" ", references.Select(p => "/reference:" + Q(p))) + " " + String.Join(" ", files.Select(Q));
        if (Run(Path.Combine(framework, "csc.exe"), arguments) != 0) throw new Exception("Compilation failed.");
        Copy(Path.Combine(root, "app.config"), target + ".config");
    }
    public static int Main(string[] args) {
        try {
            root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..")); output = Path.Combine(root, "bin", "Release"); Directory.CreateDirectory(output); Compile(false);
            foreach (var name in new[] { "ui", "assets", "catalog", "docs", "README.md", "LICENSE" }) Copy(Path.Combine(root, name), Path.Combine(output, name));
            Console.WriteLine("Built bin/Release/R5R Mod Manager.exe");
            if (args.Contains("test")) { Compile(true); if (Run(Path.Combine(output, "R5R.Tests.exe"), (args.Contains("live") ? "--live " : "") + (args.Contains("recycle") ? "--recycle" : "")) != 0) throw new Exception("Tests failed."); }
            if (args.Contains("package")) {
                var dist = Path.Combine(root, "dist"); Directory.CreateDirectory(dist); var staging = Path.Combine(dist, "package-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(staging);
                try { foreach (var name in new[] { "R5R Mod Manager.exe", "R5R Mod Manager.exe.config", "ui", "assets", "catalog", "docs", "README.md", "LICENSE" }) Copy(Path.Combine(output, name), Path.Combine(staging, name)); var archive = Path.Combine(dist, "R5R-Mod-Manager-3.3.1.zip"); if (File.Exists(archive)) File.Delete(archive); ZipFile.CreateFromDirectory(staging, archive, CompressionLevel.Optimal, false); Console.WriteLine("Built dist/R5R-Mod-Manager-3.3.1.zip"); } finally { if (Directory.Exists(staging) && staging.StartsWith(dist + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) Directory.Delete(staging, true); }
            }
            return 0;
        } catch (Exception ex) { Console.Error.WriteLine(ex.Message); return 1; }
    }
}
