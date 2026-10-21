using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace R5R {
    public interface INetwork {
        Task<string> Text(string url, CancellationToken token);
        Task Download(string url, string path, long limit, IProgress<PackageProgress> progress, CancellationToken token);
    }
    public sealed class HttpCache { public string Etag { get; set; } public string Body { get; set; } }
    public sealed class Network : INetwork {
        readonly string cache;
        public Network(string cacheDirectory) { cache = cacheDirectory; ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; }
        public static bool SafeUrl(string value) { Uri uri; return Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.Scheme == "https" && String.IsNullOrEmpty(uri.UserInfo); }
        static HttpWebRequest Request(string url) {
            if (!SafeUrl(url)) throw new InvalidDataException("Downloads require an HTTPS URL without embedded credentials.");
            var request = (HttpWebRequest)WebRequest.Create(url); request.UserAgent = "R5R-Mod-Manager/3.3"; request.Timeout = 15000; request.ReadWriteTimeout = 30000; request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate; return request;
        }
        public async Task<string> Text(string url, CancellationToken token) {
            var path = Path.Combine(cache, "http", Files.Hash(url) + ".json"); var cached = Json.Read<HttpCache>(path); var request = Request(url);
            if (cached != null && !String.IsNullOrEmpty(cached.Etag)) request.Headers[HttpRequestHeader.IfNoneMatch] = cached.Etag;
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                timeout.CancelAfter(TimeSpan.FromSeconds(20));
                using (timeout.Token.Register(request.Abort)) try {
                    using (var response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false)) {
                        if (!SafeUrl(response.ResponseUri.AbsoluteUri)) throw new InvalidDataException("An insecure source redirect was rejected.");
                        if (response.ContentLength > 33554432) throw new InvalidDataException("Catalog response exceeds the size limit.");
                        using (var input = response.GetResponseStream()) using (var data = new MemoryStream()) {
                            var buffer = new byte[65536]; int count;
                            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) > 0) { if (data.Length + count > 33554432) throw new InvalidDataException("Catalog response exceeds the size limit."); data.Write(buffer, 0, count); }
                            var body = Encoding.UTF8.GetString(data.ToArray()).TrimStart('\uFEFF'); Json.Write(path, new HttpCache { Etag = response.Headers["ETag"], Body = body }); return body;
                        }
                    }
                } catch (WebException ex) {
                    token.ThrowIfCancellationRequested();
                    using (var response = ex.Response as HttpWebResponse) {
                        if (response != null && response.StatusCode == HttpStatusCode.NotModified && cached != null) return cached.Body;
                        if (response != null && ((int)response.StatusCode == 403 || (int)response.StatusCode == 429)) throw new IOException("Source rate limit reached. Cached listings remain available.");
                    }
                    throw new IOException("Source unavailable. Cached listings remain available.", ex);
                }
            }
        }
        public async Task Download(string url, string path, long limit, IProgress<PackageProgress> progress, CancellationToken token) {
            var request = Request(url);
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                timeout.CancelAfter(TimeSpan.FromMinutes(15));
                using (timeout.Token.Register(request.Abort)) try {
                    using (var response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false)) {
                        if (!SafeUrl(response.ResponseUri.AbsoluteUri)) throw new InvalidDataException("An insecure package redirect was rejected.");
                        if (response.ContentLength > limit) throw new InvalidDataException("Download exceeds the size limit.");
                        Directory.CreateDirectory(Path.GetDirectoryName(path));
                        using (var input = response.GetResponseStream()) using (var output = File.Create(path)) {
                            var buffer = new byte[65536]; long received = 0; int count;
                            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) > 0) {
                                received += count; if (received > limit) throw new InvalidDataException("Download exceeds the size limit.");
                                await output.WriteAsync(buffer, 0, count, timeout.Token).ConfigureAwait(false);
                                if (progress != null) progress.Report(new PackageProgress("Downloading") { Bytes = received, Total = response.ContentLength });
                            }
                        }
                    }
                } catch (WebException ex) { token.ThrowIfCancellationRequested(); throw new IOException("Package download failed. Check the connection and retry.", ex); }
            }
        }
    }
}
