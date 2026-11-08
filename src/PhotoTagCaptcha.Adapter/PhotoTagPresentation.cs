using System.Net;
using Microsoft.IdentityServer.Web.Authentication.External;

namespace PhotoTagCaptcha
{
    /// <summary>
    /// The HTML AD FS places inside its sign-in page. AD FS replaces %AuthMethod% and %Context%
    /// before sending it; posting AuthMethod and Context back is what routes the request to
    /// TryEndAuthentication. Forms have NO action attribute, so they post back to the current
    /// AD FS URL (protocol query string included). AD FS 2019 does not substitute a
    /// %PageActionUrl% placeholder; using one makes the browser post to a literal
    /// ".../%PageActionUrl%" path and AD FS fails with MSIS7065.
    ///
    /// An external adapter always renders INSIDE the AD FS sign-in page (it is a step of that
    /// page, not a redirect elsewhere). "Popup" mode therefore draws the step as a modal dialog
    /// over the dimmed AD FS page with plain CSS; no browser pop-up window is involved.
    ///
    /// The photo is an inline data: URI (allowed by the default img-src 'self' data:).
    /// </summary>
    public sealed class PhotoTagPresentation : IAdapterPresentationForm
    {
        private enum Kind { Challenge, Continue, Error, NotAvailable }

        private readonly Kind _kind;
        private readonly Photo _photo;
        private readonly string _challengeId;
        private readonly string _message;
        private readonly bool _popup;

        private PhotoTagPresentation(Kind kind, Photo photo = null, string challengeId = null, string message = null, bool popup = true)
        {
            _kind = kind;
            _photo = photo;
            _challengeId = challengeId;
            _message = message;
            _popup = popup;
        }

        public static PhotoTagPresentation Challenge(Photo photo, string challengeId, string message, bool popup) =>
            new PhotoTagPresentation(Kind.Challenge, photo, challengeId, message, popup);

        /// <summary>Fail-open: a page that immediately posts back so TryEndAuthentication can let the user in.</summary>
        public static PhotoTagPresentation Continue() => new PhotoTagPresentation(Kind.Continue);

        public static PhotoTagPresentation Error(string message) => new PhotoTagPresentation(Kind.Error, message: message);

        /// <summary>Guard refused: this application may not use the captcha. No form, nothing to submit.</summary>
        public static PhotoTagPresentation NotAvailable() => new PhotoTagPresentation(Kind.NotAvailable);

        public string GetPageTitle(int lcid) =>
            _kind == Kind.Continue ? "Signing in" : _kind == Kind.NotAvailable ? "Not available" : "Review a photo";

        public string GetFormPreRenderHtml(int lcid) => @"
<style>
  #ptc .ptc-title { font-size: 1.3em; margin: 0 0 8px 0; }
  #ptc .ptc-intro { margin: 0 0 12px 0; }
  #ptc .ptc-frame { border: 1px solid #ccc; border-radius: 4px; padding: 4px; background: #fff; }
  #ptc .ptc-photo { display: block; width: 100%; height: auto; }
  #ptc .ptc-caption { color: #666; font-size: 0.85em; margin: 6px 0 0 0; }
  #ptc .ptc-error { color: #c00; margin: 12px 0 0 0; }
  #ptc .ptc-actions { margin-top: 16px; }
  #ptc .ptc-actions input.submit { min-width: 120px; }

  /* Popup mode: modal dialog over the dimmed AD FS page (pure CSS, no pop-up window). */
  #ptc.ptc-modal { position: fixed; top: 0; right: 0; bottom: 0; left: 0; z-index: 10000;
                   background: rgba(0, 0, 0, 0.55); display: flex; align-items: center; justify-content: center;
                   padding: 16px; box-sizing: border-box; }
  #ptc.ptc-modal .ptc-dialog { background: #fff; color: #1b1b1b; width: 100%; max-width: 560px;
                   max-height: 100%; overflow: auto; padding: 24px; box-sizing: border-box;
                   border-radius: 6px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45); text-align: left; }
</style>";

        public string GetFormHtml(int lcid)
        {
            switch (_kind)
            {
                case Kind.Continue:
                    return ContinueHtml();
                case Kind.Error:
                    return $@"<div id=""ptc""><p class=""ptc-error"">{Encode(_message)}</p></div>";
                case Kind.NotAvailable:
                    return @"<div id=""ptc"" data-ptc=""not-available"">
  <div class=""ptc-title"">This verification isn't available here</div>
  <p class=""ptc-intro"">The photo review can't be used to sign in to this application.
    Please go back and choose a different verification method, or contact the helpdesk.</p>
</div>";
                default:
                    return ChallengeHtml();
            }
        }

        private string ChallengeHtml()
        {
            var error = string.IsNullOrEmpty(_message)
                ? string.Empty
                : $@"<p class=""ptc-error"" role=""alert"">{Encode(_message)}</p>";

            return $@"
<div id=""ptc""{(_popup ? @" class=""ptc-modal""" : string.Empty)}>
  <div class=""ptc-dialog"" role=""dialog"" aria-modal=""true"" aria-labelledby=""ptcTitle"">
    <form method=""post"" id=""ptcForm"" autocomplete=""off"">
      <input type=""hidden"" name=""AuthMethod"" value=""%AuthMethod%"" />
      <input type=""hidden"" name=""Context"" value=""%Context%"" />
      <input type=""hidden"" name=""{PhotoTagAdapter.ChallengeIdField}"" value=""{Encode(_challengeId)}"" />

      <div class=""ptc-title"" id=""ptcTitle"">Help our research</div>
      <p class=""ptc-intro"">To finish signing in, look at the photo below and click <b>Approve</b>.
        Your review helps our data science research.</p>

      <div class=""ptc-frame"">
        <img class=""ptc-photo"" src=""{_photo.DataUri}"" alt=""Photo to review"" />
      </div>
      <p class=""ptc-caption"">Photo {Encode(_photo.Id)}</p>
      {error}
      <div class=""ptc-actions submitMargin"">
        <input type=""submit"" class=""submit"" id=""ptcApprove"" name=""{PhotoTagAdapter.ApproveField}"" value=""Approve"" />
      </div>
    </form>
  </div>
</div>";
        }

        // Fail-open page. The inline script submits it at once; the button stays visible in case
        // scripts are blocked (e.g. a stricter Content-Security-Policy), so the user is never stuck.
        private static string ContinueHtml() => $@"
<div id=""ptc"">
  <form method=""post"" id=""ptcContinueForm"" autocomplete=""off"">
    <input type=""hidden"" name=""AuthMethod"" value=""%AuthMethod%"" />
    <input type=""hidden"" name=""Context"" value=""%Context%"" />
    <input type=""hidden"" name=""{PhotoTagAdapter.ContinueField}"" value=""1"" />
    <p class=""ptc-intro"">Continuing to the application&hellip;</p>
    <div class=""ptc-actions submitMargin"">
      <input type=""submit"" class=""submit"" id=""ptcContinue"" value=""Continue"" />
    </div>
  </form>
  <script>document.getElementById('ptcContinueForm').submit();</script>
</div>";

        private static string Encode(string value) => WebUtility.HtmlEncode(value ?? string.Empty);
    }
}
