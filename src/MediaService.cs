using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;

namespace R5R {
    public sealed class MediaService {
        readonly AppPaths paths;
        readonly INetwork network;
        public MediaService(AppPaths paths, INetwork network) { this.paths = paths; this.network = network; }
        static string First(CatalogEntry entry) { return (entry.PreviewUrls ?? new string[0]).FirstOrDefault() ?? entry.IconUrl; }
        public string Preview(CatalogEntry entry) { var url = First(entry); if (String.IsNullOrEmpty(url)) return null; var path = Path.Combine(paths.Cache, "images", Files.Hash(url) + ".img"); return File.Exists(path) ? path : null; }
        public static BitmapImage Bitmap(string path, int width) { if (String.IsNullOrEmpty(path) || !File.Exists(path)) return null; try { var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.UriSource = new Uri(Path.GetFullPath(path)); if (width > 0) image.DecodePixelWidth = width; image.EndInit(); image.Freeze(); return image; } catch (IOException) { return null; } catch (NotSupportedException) { return null; } }
        public async Task<string> Image(string url, CancellationToken token) {
            if (!Network.SafeUrl(url)) return null; var path = Path.Combine(paths.Cache, "images", Files.Hash(url) + ".img"); if (File.Exists(path)) return path;
            Directory.CreateDirectory(Path.GetDirectoryName(path)); var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                await network.Download(url, temp, 8388608, null, token).ConfigureAwait(false);
                using (var input = File.OpenRead(temp)) { var decoder = BitmapDecoder.Create(input, BitmapCreateOptions.None, BitmapCacheOption.OnLoad); var frame = decoder.Frames[0]; if (frame.PixelWidth > 16384 || frame.PixelHeight > 16384 || (long)frame.PixelWidth * frame.PixelHeight > 64000000) throw new InvalidDataException("Preview image exceeds the size limit."); }
                if (!File.Exists(path)) File.Move(temp, path); return path;
            } catch (OperationCanceledException) { throw; } catch (Exception ex) { if (!(ex is IOException) && !(ex is NotSupportedException) && !(ex is ArgumentException)) paths.Log("Preview: " + ex.Message); return null; }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        public async Task CacheImages(IEnumerable<CatalogEntry> entries, Action<string, string> ready, CancellationToken token) {
            foreach (var entry in entries) { token.ThrowIfCancellationRequested(); var path = await Image(First(entry), token).ConfigureAwait(false); if (path != null) ready(entry.Key, path); }
        }
        public async Task<ModDetails> Details(CatalogEntry entry, CancellationToken token) {
            var path = Path.Combine(paths.Cache, "details", Files.Hash(entry.Key + ":" + entry.Version + ":" + entry.Commit) + ".json"); var cached = Json.Read<ModDetails>(path); DateTime updated;
            if (cached != null && DateTime.TryParse(cached.Updated, out updated) && updated.ToUniversalTime() > DateTime.UtcNow.AddHours(-1)) return cached;
            var body = entry.Description ?? ""; var urls = new List<string>(entry.PreviewUrls ?? new string[0]);
            if (entry.SourceId == "flowstate-thunderstore" && Data.Match(entry.ModId, "^[\\w-]+\\.[\\w-]+$") && Data.Match(entry.Version, "^[\\w.-]+$")) {
                try {
                    var parts = entry.ModId.Split('.'); var readme = Json.Decode<object>(await network.Text("https://thunderstore.io/api/experimental/package/" + parts[0] + "/" + parts[1] + "/" + entry.Version + "/readme/", token).ConfigureAwait(false)); var markdown = Data.Text(readme, "markdown");
                    if (markdown.Length > 0) { body = markdown; foreach (Match match in Regex.Matches(body, "!\\[[^\\]]*\\]\\((https://[^\\s)]+)(?:\\s+\"[^\"]*\")?\\)")) urls.Add(match.Groups[1].Value); foreach (Match match in Regex.Matches(body, "<img[^>]+src=[\"'](https://[^\"']+)", RegexOptions.IgnoreCase)) urls.Add(match.Groups[1].Value); }
                } catch (OperationCanceledException) { throw; } catch (IOException) { if (cached != null) return cached; }
            }
            if (urls.Count == 0 && !String.IsNullOrEmpty(entry.IconUrl)) urls.Add(entry.IconUrl);
            var images = new List<string>(); foreach (var url in urls.Distinct().Take(8)) { var image = await Image(url, token).ConfigureAwait(false); if (image != null) images.Add(image); }
            var details = new ModDetails { Key = entry.Key, Body = PlainText(body), Images = images.ToArray(), Updated = DateTime.UtcNow.ToString("o") }; Json.Write(path, details); return details;
        }
        public static string PlainText(string body) { body = Regex.Replace(body ?? "", "<(script|style)\\b[^>]*>.*?</\\1>", "", RegexOptions.IgnoreCase | RegexOptions.Singleline); body = Regex.Replace(body, "!\\[[^\\]]*\\]\\([^)]*\\)", ""); body = Regex.Replace(body, "<[^>]+>", ""); body = Regex.Replace(body, "^#{1,6}\\s+", "", RegexOptions.Multiline); body = Regex.Replace(body, "\\[([^\\]]+)\\]\\((https://[^)]+)\\)", "$1 ($2)"); return WebUtility.HtmlDecode(body).Trim(); }
    }
}
