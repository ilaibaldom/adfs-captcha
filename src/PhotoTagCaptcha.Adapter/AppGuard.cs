using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Xml;

namespace PhotoTagCaptcha
{
    /// <summary>
    /// Restricts the captcha to the applications listed in the configuration ("allowedApplications").
    ///
    /// Why: AD FS has no per-application list of additional providers. Once this provider is enabled
    /// farm-wide, EVERY application that requires MFA can offer it, and a user could pick the photo
    /// and click Approve instead of doing real MFA. The guard makes the adapter refuse to complete
    /// for anything but the configured application(s).
    ///
    /// The TARGET application is read from the AD FS protocol request:
    ///   OAuth/OIDC  resource=...      (the app group's Web API identifier)
    ///   WS-Fed      wtrealm=...       (relying party identifier)
    ///   SAML        SAMLRequest=...   (Issuer of the AuthnRequest, redirect binding)
    ///   fallback    client_id=...     (only when none of the above is present)
    /// The target is used rather than client_id because the access policy that triggered MFA belongs
    /// to the target; a permitted client asking for another (MFA-protected) resource must not pass.
    /// </summary>
    public static class AppGuard
    {
        public sealed class Result
        {
            public bool Allowed;
            public string Target;      // identifier that was matched against the list (null = unidentified)
            public string Source;      // resource | wtrealm | saml-issuer | client_id
            public string Detail;      // human-readable, for logs
        }

        public static Result Check(AdapterConfig config, Uri requestUrl)
        {
            var (target, source) = IdentifyTarget(requestUrl);
            var allowed = config?.AllowedApplications ?? new string[0];

            if (allowed.Length == 0)
                return new Result { Allowed = true, Target = target, Source = source, Detail = "guard disabled (no allowedApplications configured)" };

            if (target == null)
                return new Result
                {
                    Allowed = config.AllowUnidentified,
                    Detail = config.AllowUnidentified
                        ? "application could not be identified; allowed because allowUnidentified=true"
                        : "application could not be identified from the request (no resource, wtrealm, SAML issuer or client_id)",
                };

            var match = allowed.Any(a => Same(a, target));
            return new Result
            {
                Allowed = match,
                Target = target,
                Source = source,
                Detail = match ? $"{source} '{target}' is allowed" : $"{source} '{target}' is not in allowedApplications",
            };
        }

        public static (string Target, string Source) IdentifyTarget(Uri requestUrl)
        {
            if (requestUrl == null) return (null, null);
            var q = ParseQuery(requestUrl.Query);

            if (q.TryGetValue("resource", out var resource) && !string.IsNullOrWhiteSpace(resource)) return (resource.Trim(), "resource");
            if (q.TryGetValue("wtrealm", out var wtrealm) && !string.IsNullOrWhiteSpace(wtrealm)) return (wtrealm.Trim(), "wtrealm");
            if (q.TryGetValue("SAMLRequest", out var saml) && !string.IsNullOrWhiteSpace(saml))
            {
                var issuer = SamlIssuer(saml);
                if (issuer != null) return (issuer, "saml-issuer");
            }
            if (q.TryGetValue("client_id", out var clientId) && !string.IsNullOrWhiteSpace(clientId)) return (clientId.Trim(), "client_id");
            return (null, null);
        }

        // Identifiers are compared case-insensitively and without a trailing slash, so
        // "https://research.contoso.com/" and "https://research.contoso.com" are the same app.
        private static bool Same(string a, string b) =>
            string.Equals(a?.Trim().TrimEnd('/'), b?.Trim().TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

        internal static Dictionary<string, string> ParseQuery(string query)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrEmpty(query)) return result;
            foreach (var part in query.TrimStart('?').Split('&'))
            {
                if (part.Length == 0) continue;
                var i = part.IndexOf('=');
                var key = Decode(i < 0 ? part : part.Substring(0, i));
                var value = i < 0 ? string.Empty : Decode(part.Substring(i + 1));
                if (!result.ContainsKey(key)) result[key] = value;   // first occurrence wins
            }
            return result;
        }

        private static string Decode(string s) => Uri.UnescapeDataString(s.Replace('+', ' '));

        /// <summary>Issuer of a SAML AuthnRequest (redirect binding = base64 of raw DEFLATE; also accepts plain base64 XML).</summary>
        internal static string SamlIssuer(string samlRequest)
        {
            byte[] raw;
            try { raw = Convert.FromBase64String(samlRequest.Replace(' ', '+')); }
            catch (FormatException) { return null; }

            foreach (var xml in new[] { Inflate(raw), raw })
            {
                if (xml == null) continue;
                try
                {
                    var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_000_000 };
                    using (var reader = XmlReader.Create(new MemoryStream(xml), settings))
                    {
                        while (reader.Read())
                        {
                            if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "Issuer" &&
                                reader.NamespaceURI == "urn:oasis:names:tc:SAML:2.0:assertion")
                            {
                                var issuer = reader.ReadElementContentAsString().Trim();
                                return issuer.Length > 0 ? issuer : null;
                            }
                        }
                    }
                }
                catch (XmlException) { }
            }
            return null;
        }

        private static byte[] Inflate(byte[] data)
        {
            try
            {
                using (var input = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress))
                using (var output = new MemoryStream())
                {
                    var buffer = new byte[8192];
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        output.Write(buffer, 0, read);
                        if (output.Length > 1_000_000) return null;
                    }
                    return output.Length > 0 ? output.ToArray() : null;
                }
            }
            catch (InvalidDataException) { return null; }
        }

        /// <summary>For diagnostics logging: what AD FS gave us, with long values shortened.</summary>
        internal static string Describe(Uri url, IDictionary<string, object> data)
        {
            var sb = new StringBuilder();
            sb.Append("URL: ").Append(url?.GetLeftPart(UriPartial.Path) ?? "(none)");
            if (url != null)
            {
                foreach (var kv in ParseQuery(url.Query))
                    sb.Append("\n  query ").Append(kv.Key).Append(" = ").Append(Short(kv.Value));
            }
            if (data != null)
            {
                foreach (var kv in data)
                    sb.Append("\n  context.Data ").Append(kv.Key).Append(" (").Append(kv.Value?.GetType().Name ?? "null").Append(") = ").Append(Short(kv.Value?.ToString()));
            }
            return sb.ToString();
        }

        private static string Short(string s) => s == null ? "null" : s.Length <= 200 ? s : s.Substring(0, 200) + "...";
    }
}
