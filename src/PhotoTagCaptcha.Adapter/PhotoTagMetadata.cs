using System.Collections.Generic;
using Microsoft.IdentityServer.Web.Authentication.External;

namespace PhotoTagCaptcha
{
    /// <summary>
    /// Describes the provider to AD FS. AD FS reads this once, at Register-AdfsAuthenticationProvider
    /// time and on every service start.
    /// </summary>
    public sealed class PhotoTagMetadata : IAuthenticationAdapterMetadata
    {
        /// <summary>
        /// Value of the http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod
        /// claim this adapter emits on success. Relying parties can see it in the token.
        /// </summary>
        public const string AuthenticationMethodUri = "urn:phototag:captcha:poc";

        public const int English = 1033;

        // Shown in the AD FS management console (Authentication Methods).
        public string AdminName => "Photo Tag Captcha (POC)";

        public string[] AuthenticationMethods => new[] { AuthenticationMethodUri };

        public int[] AvailableLcids => new[] { English };

        // Shown to users on the AD FS "choose a method" page if several additional providers apply.
        public Dictionary<int, string> FriendlyNames => new Dictionary<int, string>
        {
            { English, "Help research: review a photo" }
        };

        public Dictionary<int, string> Descriptions => new Dictionary<int, string>
        {
            { English, "Review a photo for a research data set to continue signing in." }
        };

        // Used as an additional (MFA-stage) provider: AD FS has already identified the user
        // with primary authentication and hands us their UPN.
        public bool RequiresIdentity => true;

        public string[] IdentityClaims => new[] { "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn" };
    }
}
