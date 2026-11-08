using System;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;

namespace PhotoTagCaptcha
{
    /// <summary>
    /// Optional JSON configuration, registered with
    ///   Register-AdfsAuthenticationProvider ... -ConfigurationFilePath phototag-config.json
    /// or updated later with
    ///   Import-AdfsAuthenticationProviderConfigurationData -Name PhotoTagCaptcha -FilePath ...
    /// (then restart AD FS on every node). AD FS stores it in the farm configuration and hands it
    /// to OnAuthenticationPipelineLoad. Without a configuration the defaults below apply.
    ///
    /// {
    ///   "photoUrl":    "https://images.research.contoso.com/next",  // or file:///C:/path/photo.jpg; empty = embedded sample
    ///   "timeoutMs":   3000,       // max time to fetch the photo before skipping the captcha
    ///   "maxBytes":    2097152,    // larger photos are treated as unavailable
    ///   "displayMode": "popup",    // "popup" (dialog over the AD FS page) or "page" (inline)
    ///   "allowedApplications": ["https://research.contoso.com/"],  // guard: only these apps (see AppGuard)
    ///   "allowUnidentified": false,  // guard on + app not identifiable => refuse
    ///   "diagnostics": false         // log what AD FS passes to the adapter (event 1900)
    /// }
    /// </summary>
    [DataContract]
    public sealed class AdapterConfig
    {
        public const int DefaultTimeoutMs = 3000;
        public const int DefaultMaxBytes = 2 * 1024 * 1024;

        [DataMember(Name = "photoUrl", EmitDefaultValue = false)]
        public string PhotoUrl { get; set; }

        [DataMember(Name = "timeoutMs", EmitDefaultValue = false)]
        public int TimeoutMs { get; set; }

        [DataMember(Name = "maxBytes", EmitDefaultValue = false)]
        public int MaxBytes { get; set; }

        [DataMember(Name = "displayMode", EmitDefaultValue = false)]
        public string DisplayMode { get; set; }

        /// <summary>
        /// Application identifiers the captcha may complete for (see AppGuard): Web API identifier
        /// (OAuth "resource"), relying party identifier (WS-Fed wtrealm / SAML issuer), or client_id
        /// for apps that send no resource. Empty = guard off (any app that requires MFA can use it).
        /// </summary>
        [DataMember(Name = "allowedApplications", EmitDefaultValue = false)]
        public string[] AllowedApplications { get; set; }

        /// <summary>When the guard is on and the app cannot be identified from the request: allow (true) or refuse (false, default).</summary>
        [DataMember(Name = "allowUnidentified", EmitDefaultValue = false)]
        public bool AllowUnidentified { get; set; }

        /// <summary>Logs what AD FS passes to the adapter (event 1900). For troubleshooting only.</summary>
        [DataMember(Name = "diagnostics", EmitDefaultValue = false)]
        public bool Diagnostics { get; set; }

        public bool GuardEnabled => AllowedApplications != null && AllowedApplications.Length > 0;

        public bool Popup => !string.Equals(DisplayMode, "page", StringComparison.OrdinalIgnoreCase);

        public static AdapterConfig Default() => new AdapterConfig().Normalize();

        /// <summary>Parses the registered configuration. Never throws: a broken config is reported in <paramref name="error"/>.</summary>
        public static AdapterConfig Load(Stream data, out string error)
        {
            error = null;
            if (data == null) return Default();
            try
            {
                // Decode as text first: files written by Windows PowerShell 5.1 (Set-Content -Encoding
                // UTF8) or Notepad start with a UTF-8 byte-order mark, which DataContractJsonSerializer
                // rejects ("unexpected character 'ï'"). Found in the lab.
                string json;
                using (var reader = new StreamReader(data, System.Text.Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
                {
                    json = reader.ReadToEnd().Trim().TrimStart('﻿');
                }
                if (json.Length == 0) return Default();
                using (var buffer = new MemoryStream(new System.Text.UTF8Encoding(false).GetBytes(json)))
                {
                    var cfg = (AdapterConfig)new DataContractJsonSerializer(typeof(AdapterConfig)).ReadObject(buffer);
                    return (cfg ?? new AdapterConfig()).Normalize();
                }
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return null;
            }
        }

        // DataContractJsonSerializer does not run constructors or initializers, so defaults go here.
        private AdapterConfig Normalize()
        {
            if (TimeoutMs <= 0) TimeoutMs = DefaultTimeoutMs;
            if (MaxBytes <= 0) MaxBytes = DefaultMaxBytes;
            PhotoUrl = string.IsNullOrWhiteSpace(PhotoUrl) ? null : PhotoUrl.Trim();
            AllowedApplications = (AllowedApplications ?? new string[0])
                .Where(a => !string.IsNullOrWhiteSpace(a)).Select(a => a.Trim()).ToArray();
            return this;
        }

        public override string ToString() =>
            $"photoUrl={(PhotoUrl ?? "(embedded sample)")}, timeoutMs={TimeoutMs}, maxBytes={MaxBytes}, displayMode={(Popup ? "popup" : "page")}, " +
            (GuardEnabled
                ? $"allowedApplications=[{string.Join(", ", AllowedApplications)}], allowUnidentified={AllowUnidentified}"
                : "allowedApplications=NONE (guard OFF: any application that requires MFA can be satisfied by this captcha)") +
            (Diagnostics ? ", diagnostics=ON" : "");
    }
}
