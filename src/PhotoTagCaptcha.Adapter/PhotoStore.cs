using System;
using System.IO;
using System.Net;

namespace PhotoTagCaptcha
{
    public sealed class Photo
    {
        public Photo(string id, string dataUri)
        {
            Id = id;
            DataUri = dataUri;
        }

        public string Id { get; }

        public string DataUri { get; }
    }

    /// <summary>
    /// Gets the photo to show. Never throws: any failure (missing resource, unreachable URL,
    /// timeout, non-image response, oversized image) returns false with a reason, and the adapter
    /// then lets the user through without the captcha.
    ///
    /// Sources:
    ///   * no photoUrl configured  -> the sample embedded in the DLL (Assets\photo.jpg)
    ///   * http(s)://...           -> fetched per sign-in (future research image service).
    ///                                Optional response header "X-Photo-Id" names the photo.
    ///   * file:///...             -> a file on the AD FS node (handy for testing)
    /// </summary>
    internal static class PhotoStore
    {
        private const string ResourceName = "PhotoTagCaptcha.Assets.photo.jpg";
        private static readonly Lazy<Photo> Embedded = new Lazy<Photo>(LoadEmbedded);

        public static bool TryGet(AdapterConfig config, out Photo photo, out string reason)
        {
            photo = null;
            reason = null;
            try
            {
                if (config == null)
                {
                    reason = "adapter configuration is invalid (see event 2100)";
                    return false;
                }

                if (config.PhotoUrl == null)
                {
                    photo = Embedded.Value;
                    if (photo == null) reason = $"embedded resource '{ResourceName}' is missing";
                    return photo != null;
                }

                return TryFetch(config, out photo, out reason);
            }
            catch (Exception ex)
            {
                reason = $"{ex.GetType().Name}: {ex.Message}";
                return false;
            }
        }

        private static bool TryFetch(AdapterConfig config, out Photo photo, out string reason)
        {
            photo = null;
            if (!Uri.TryCreate(config.PhotoUrl, UriKind.Absolute, out var uri) ||
                (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeFile))
            {
                reason = $"photoUrl '{config.PhotoUrl}' is not an absolute http(s):// or file:/// URL";
                return false;
            }

            var request = WebRequest.Create(uri);
            request.Timeout = config.TimeoutMs;
            if (request is HttpWebRequest http)
            {
                http.ReadWriteTimeout = config.TimeoutMs;
                http.UserAgent = "PhotoTagCaptcha-ADFS/1.1";
                http.Accept = "image/*";
            }

            try
            {
                using (var response = request.GetResponse())
                using (var stream = response.GetResponseStream())
                {
                    string contentType;
                    string id = null;
                    if (response is HttpWebResponse httpResponse)
                    {
                        contentType = (httpResponse.ContentType ?? string.Empty).Split(';')[0].Trim().ToLowerInvariant();
                        id = httpResponse.Headers["X-Photo-Id"];
                    }
                    else
                    {
                        contentType = ContentTypeFromExtension(uri.LocalPath);
                    }

                    if (!contentType.StartsWith("image/", StringComparison.Ordinal))
                    {
                        reason = $"'{uri}' returned content type '{contentType}', not an image";
                        return false;
                    }

                    var bytes = ReadCapped(stream, config.MaxBytes);
                    if (bytes == null)
                    {
                        reason = $"'{uri}' is larger than maxBytes={config.MaxBytes}";
                        return false;
                    }
                    if (bytes.Length == 0)
                    {
                        reason = $"'{uri}' returned an empty body";
                        return false;
                    }

                    if (string.IsNullOrEmpty(id)) id = Path.GetFileNameWithoutExtension(uri.LocalPath);
                    photo = new Photo(id, $"data:{contentType};base64,{Convert.ToBase64String(bytes)}");
                    reason = null;
                    return true;
                }
            }
            catch (WebException ex)
            {
                var status = (ex.Response as HttpWebResponse)?.StatusCode;
                reason = status.HasValue
                    ? $"'{uri}' returned HTTP {(int)status.Value} {status.Value}"
                    : $"'{uri}' unavailable: {ex.Status} - {ex.Message}";
                return false;
            }
        }

        private static byte[] ReadCapped(Stream stream, int maxBytes)
        {
            using (var buffer = new MemoryStream())
            {
                var chunk = new byte[81920];
                int read;
                while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
                {
                    buffer.Write(chunk, 0, read);
                    if (buffer.Length > maxBytes) return null;
                }
                return buffer.ToArray();
            }
        }

        private static string ContentTypeFromExtension(string path)
        {
            switch (Path.GetExtension(path).ToLowerInvariant())
            {
                case ".jpg":
                case ".jpeg": return "image/jpeg";
                case ".png": return "image/png";
                case ".gif": return "image/gif";
                case ".webp": return "image/webp";
                default: return "application/octet-stream";
            }
        }

        private static Photo LoadEmbedded()
        {
            using (var stream = typeof(PhotoStore).Assembly.GetManifestResourceStream(ResourceName))
            {
                if (stream == null) return null;
                using (var buffer = new MemoryStream())
                {
                    stream.CopyTo(buffer);
                    return new Photo("sample-001", "data:image/jpeg;base64," + Convert.ToBase64String(buffer.ToArray()));
                }
            }
        }
    }
}
