using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace R5R.Tests {
    internal static partial class TestRunner {
        static async Task MediaTests() {
            var root = Area("media"); var paths = new AppPaths(appRoot, Path.Combine(root, "data")); var network = new FakeNetwork(); var service = new MediaService(paths, network); var entry = Listing("Media.Mod", "Map"); entry.IconUrl = "https://example.org/icon.png";
            network.Downloads[entry.IconUrl] = File.ReadAllBytes(Path.Combine(appRoot, "assets", "icon.png")); var image = await service.Image(entry.IconUrl, None); Check(image != null && service.Preview(entry) == image, "Publisher previews are validated and cached by URL");
            var requests = network.Requests.Count; Check(await service.Image(entry.IconUrl, None) == image && network.Requests.Count == requests, "Cached previews load without another network request");
            var bitmap = MediaService.Bitmap(image, 240); Check(bitmap != null && bitmap.IsFrozen && bitmap.PixelWidth > 0, "Cached preview decoding produces a thread-safe WPF image");
            network.Downloads["https://example.org/invalid.png"] = new byte[] { 1, 2, 3 }; Check(await service.Image("https://example.org/invalid.png", None) == null, "Invalid publisher image bytes do not enter the preview cache"); Check(await service.Image("http://example.org/image.png", None) == null, "Image retrieval rejects insecure URLs");
            var details = await service.Details(entry, None); Check(details.Images.Single() == image && details.Body == entry.Description, "Mod pages retain descriptions and cached publisher artwork"); requests = network.Requests.Count; await service.Details(entry, None); Check(network.Requests.Count == requests, "Fresh cached mod details do not fetch remote content");
            entry.SourceId = "flowstate-thunderstore"; entry.ModId = "Author.Media"; entry.Version = "1.0.0";
            var path = Path.Combine(paths.Cache, "details", Files.Hash(entry.Key + ":" + entry.Version + ":" + entry.Commit) + ".json"); Json.Write(path, new ModDetails { Key = entry.Key, Body = "Offline description", Images = new[] { image }, Updated = DateTime.UtcNow.AddHours(-2).ToString("o") });
            details = await service.Details(entry, None); Check(details.Body == "Offline description" && details.Images.Single() == image, "Unavailable description sources fall back to older cached details");
            var text = MediaService.PlainText("# Title\n<script>alert('x')</script><style>hidden</style>![image](https://example.org/a.png)\n[Source](https://example.org) &amp; text"); Check(!text.Contains("alert") && !text.Contains("hidden") && text.Contains("Source (https://example.org) & text"), "Publisher markup is converted to text without executing scripts");
        }
    }
}
