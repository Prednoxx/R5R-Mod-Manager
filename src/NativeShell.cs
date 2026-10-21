using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualBasic.FileIO;

namespace R5R {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] internal class FileOpenDialogCo { }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv); void GetParent(out IShellItem item); void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name); void GetAttributes(uint mask, out uint attributes); void Compare(IShellItem item, uint hint, out int order);
    }
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr owner); void SetFileTypes(uint count, IntPtr filter); void SetFileTypeIndex(uint index); void GetFileTypeIndex(out uint index); void Advise(IntPtr events, out uint cookie); void Unadvise(uint cookie); void SetOptions(uint options); void GetOptions(out uint options); void SetDefaultFolder(IShellItem item); void SetFolder(IShellItem item); void GetFolder(out IShellItem item); void GetCurrentSelection(out IShellItem item); void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name); void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name); void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title); void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text); void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text); void GetResult(out IShellItem item);
    }
    public static class NativeShell {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);
        public static string PickFolder(IntPtr owner, string title, string initial) {
            var dialog = (IFileOpenDialog)new FileOpenDialogCo();
            try {
                uint options; dialog.GetOptions(out options); dialog.SetOptions(options | 0x20 | 0x40 | 0x800); dialog.SetTitle(title);
                if (!String.IsNullOrEmpty(initial) && Directory.Exists(initial)) { IShellItem folder; var iid = typeof(IShellItem).GUID; if (SHCreateItemFromParsingName(initial, IntPtr.Zero, ref iid, out folder) == 0) { try { dialog.SetFolder(folder); } finally { Marshal.ReleaseComObject(folder); } } }
                if (dialog.Show(owner) != 0) return null;
                IShellItem item; dialog.GetResult(out item); try { string path; item.GetDisplayName(0x80058000, out path); return path; } finally { Marshal.ReleaseComObject(item); }
            } finally { Marshal.ReleaseComObject(dialog); }
        }
        public static void OpenUrl(string url) { if (!Network.SafeUrl(url)) throw new InvalidDataException("The source URL must use HTTPS."); Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        public static void OpenFolder(string path) { if (!Directory.Exists(path)) Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true }); }
    }
    public sealed class RecycledMod { public string Name; public DateTime? Date; public bool ManagedBackup; public object Item; }
    public interface IRecoveryService { void Recycle(string path); List<RecycledMod> List(string game); Task Restore(RecycledMod item, string game, CancellationToken token); }
    public sealed class WindowsRecovery : IRecoveryService {
        public void Recycle(string path) { if (Directory.Exists(path)) FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException); }
        public static bool Origin(string game, string name, string deletedFrom, out bool managed) {
            managed = false;
            if (String.IsNullOrEmpty(name) || String.IsNullOrEmpty(deletedFrom) || Path.GetFileName(name) != name || name == "." || name == "..") return false;
            try {
                var source = Path.GetFullPath(deletedFrom).TrimEnd('\\'); var mods = Path.Combine(Path.GetFullPath(game), "mods").TrimEnd('\\');
                if (String.Equals(source, mods, StringComparison.OrdinalIgnoreCase)) return true;
                managed = String.Equals(Path.GetDirectoryName(source), Path.Combine(Path.GetFullPath(game), ".r5mm-backups"), StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(Path.GetFileName(source), "^[a-f0-9]{32}$"); return managed;
            } catch (ArgumentException) { return false; }
        }
        public List<RecycledMod> List(string game) {
            var result = new List<RecycledMod>(); dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
            try {
                foreach (dynamic item in shell.NameSpace(10).Items()) {
                    bool folder = item.IsFolder; if (!folder) continue; string name = item.Name; string from = Convert.ToString(item.ExtendedProperty("System.Recycle.DeletedFrom")); bool managed;
                    if (!Origin(game, name, from, out managed)) continue;
                    DateTime deleted; var date = Convert.ToString(item.ExtendedProperty("System.Recycle.DateDeleted")); result.Add(new RecycledMod { Name = name, Item = item, ManagedBackup = managed, Date = DateTime.TryParse(date, out deleted) ? (DateTime?)deleted : null });
                }
            } finally { Marshal.ReleaseComObject(shell); }
            result.Sort((a, b) => Nullable.Compare(b.Date, a.Date)); return result;
        }
        public async Task Restore(RecycledMod entry, string game, CancellationToken token) {
            ArchiveRules.CheckPart(entry.Name); var mods = Path.Combine(game, "mods"); var target = Path.Combine(mods, entry.Name);
            if (Directory.Exists(target) || File.Exists(target)) throw new IOException(entry.Name + " is already in the mods folder.");
            Directory.CreateDirectory(mods); dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
            try { shell.NameSpace(mods).MoveHere(entry.Item, 0x14); } finally { Marshal.ReleaseComObject(shell); }
            for (int i = 0; i < 100 && !Directory.Exists(target); i++) await Task.Delay(100, token).ConfigureAwait(false);
            if (!Directory.Exists(target)) throw new IOException("The mod could not be restored from the Recycle Bin.");
        }
    }
}
