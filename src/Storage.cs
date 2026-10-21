using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace R5R {
    public static class Json {
        static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = 33554432, RecursionLimit = 100 }; }
        public static string Encode(object value) { return Serializer().Serialize(value); }
        public static T Decode<T>(string text) { return Serializer().Deserialize<T>(text); }
        public static T Read<T>(string path) { try { return File.Exists(path) ? Decode<T>(File.ReadAllText(path)) : default(T); } catch (IOException) { return default(T); } catch (ArgumentException) { return default(T); } catch (InvalidOperationException) { return default(T); } }
        public static void Write(string path, object value) { Files.WriteAtomic(path, Encode(value)); }
    }
    public static class Files {
        public static string DirectoryPath(string path) { var full = Path.GetFullPath(path); return full.Length > Path.GetPathRoot(full).Length ? full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) : full; }
        public static void WriteAtomic(string path, string text) {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try { File.WriteAllText(temp, text, new UTF8Encoding(false)); if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path); }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        public static bool Inside(string path, string root) { return Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
        public static string Hash(string text) { using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(text))); }
        public static string HashFile(string path) { using (var input = File.OpenRead(path)) using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(input)); }
        public static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", ""); }
        public static bool IsLink(string path) { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
        public static IEnumerable<string> Walk(string root, string pattern, int depth, System.Threading.CancellationToken token) {
            token.ThrowIfCancellationRequested();
            if (!Directory.Exists(root) || IsLink(root)) yield break;
            string[] files, dirs;
            try { files = Directory.GetFiles(root, pattern); dirs = depth > 0 ? Directory.GetDirectories(root) : new string[0]; } catch (UnauthorizedAccessException) { yield break; } catch (IOException) { yield break; }
            foreach (var file in files) { token.ThrowIfCancellationRequested(); if (!IsLink(file)) yield return file; }
            foreach (var dir in dirs) foreach (var file in Walk(dir, pattern, depth - 1, token)) yield return file;
        }
        public static void CopyTree(string source, string target, System.Threading.CancellationToken token) {
            token.ThrowIfCancellationRequested();
            if (IsLink(source)) throw new IOException("Symbolic links and junctions cannot be installed.");
            Directory.CreateDirectory(target);
            foreach (var file in Directory.GetFiles(source)) { token.ThrowIfCancellationRequested(); if (IsLink(file)) throw new IOException("Symbolic links cannot be installed."); File.Copy(file, Path.Combine(target, Path.GetFileName(file)), true); }
            foreach (var dir in Directory.GetDirectories(source)) CopyTree(dir, Path.Combine(target, Path.GetFileName(dir)), token);
        }
        public static void RemoveStage(string path, string game) {
            var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
            if (!Inside(full, game) || !Path.GetFileName(full).StartsWith(".r5mm-stage-", StringComparison.Ordinal) || IsLinkParent(full, game)) throw new IOException("Invalid package staging path.");
            if (Directory.Exists(full)) Directory.Delete(full, true);
        }
        public static bool IsLinkParent(string path, string root) { var current = Path.GetFullPath(path); var end = Path.GetFullPath(root).TrimEnd('\\'); while (current.Length >= end.Length) { if (Directory.Exists(current) && IsLink(current)) return true; if (current.Equals(end, StringComparison.OrdinalIgnoreCase)) break; current = Path.GetDirectoryName(current); if (current == null) break; } return false; }
    }
    public sealed class AppPaths {
        public string Root { get; private set; }
        public string Data { get; private set; }
        public string Cache { get { return Path.Combine(Data, "catalog"); } }
        public AppPaths(string root, string data) { Root = Files.DirectoryPath(root); Data = Files.DirectoryPath(data); Directory.CreateDirectory(Data); Directory.CreateDirectory(Cache); }
        public string Asset(string path) { return Path.Combine(Root, "assets", path); }
        public void Log(string message) { try { File.AppendAllText(Path.Combine(Data, "error.log"), DateTime.Now.ToString("s") + " " + message + Environment.NewLine); } catch (IOException) { } }
    }
    public sealed class AppSettings {
        public string GameDir { get; set; }
        public string Theme { get; set; }
        public int StoreLayoutVersion { get; set; }
        public string ActivePreset { get; set; }
        public Dictionary<string, Dictionary<string, string>> Presets { get; set; }
        public Dictionary<string, string[]> ConVarCache { get; set; }
        public AppSettings() { Theme = "obsidian"; StoreLayoutVersion = 1; ActivePreset = ""; Presets = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase); ConVarCache = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase); }
        public static AppSettings Load(AppPaths paths) {
            var file = Path.Combine(paths.Data, "settings.json");
            if (File.Exists(file) && !File.Exists(file + ".pre-3.3.bak")) File.Copy(file, file + ".pre-3.3.bak");
            var value = Json.Read<AppSettings>(file) ?? new AppSettings();
            value.Presets = new Dictionary<string, Dictionary<string, string>>(value.Presets ?? new Dictionary<string, Dictionary<string, string>>(), StringComparer.OrdinalIgnoreCase);
            foreach (var key in value.Presets.Keys.ToArray()) value.Presets[key] = new Dictionary<string, string>(value.Presets[key] ?? new Dictionary<string, string>(), StringComparer.OrdinalIgnoreCase);
            value.ConVarCache = new Dictionary<string, string[]>(value.ConVarCache ?? new Dictionary<string, string[]>(), StringComparer.OrdinalIgnoreCase);
            if (String.IsNullOrEmpty(value.Theme)) value.Theme = "obsidian";
            return value;
        }
        public void Save(AppPaths paths) { Json.Write(Path.Combine(paths.Data, "settings.json"), this); }
    }
    public static class GameLocator {
        public static bool Valid(string path) { return !String.IsNullOrEmpty(path) && (File.Exists(Path.Combine(path, "r5apex.exe")) || File.Exists(Path.Combine(path, "r5apex_ds.exe"))); }
        public static bool Running() { return Process.GetProcessesByName("r5apex").Concat(Process.GetProcessesByName("r5apex_ds")).Any(); }
        public static string Resolve(string picked) { var dir = picked; for (int i = 0; i < 4 && !String.IsNullOrEmpty(dir); i++, dir = Path.GetDirectoryName(dir)) if (Valid(dir)) return Path.GetFullPath(dir); return Files.Walk(picked, "r5apex*.exe", 3, System.Threading.CancellationToken.None).Select(Path.GetDirectoryName).FirstOrDefault(Valid); }
        public static List<string> Find(string appRoot, System.Threading.CancellationToken token) {
            var found = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var bases = new List<string> { Path.GetDirectoryName(appRoot), Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) };
            foreach (var drive in DriveInfo.GetDrives()) if (drive.DriveType == DriveType.Fixed && drive.IsReady) { bases.Add(drive.RootDirectory.FullName); bases.Add(Path.Combine(drive.RootDirectory.FullName, "Games")); }
            foreach (var root in bases.Where(p => !String.IsNullOrEmpty(p) && Directory.Exists(p)).Distinct(StringComparer.OrdinalIgnoreCase)) {
                token.ThrowIfCancellationRequested();
                if (Valid(root)) found.Add(root);
                string[] dirs; try { dirs = Directory.GetDirectories(root); } catch (IOException) { continue; } catch (UnauthorizedAccessException) { continue; }
                foreach (var dir in dirs.Where(p => Path.GetFileName(p).IndexOf("r5", StringComparison.OrdinalIgnoreCase) >= 0 || Path.GetFileName(p).IndexOf("apex", StringComparison.OrdinalIgnoreCase) >= 0)) {
                    if (Valid(dir)) found.Add(dir);
                    foreach (var file in Files.Walk(dir, "r5apex*.exe", 3, token)) if (Valid(Path.GetDirectoryName(file))) found.Add(Path.GetDirectoryName(file));
                }
            }
            return found.ToList();
        }
    }
}
