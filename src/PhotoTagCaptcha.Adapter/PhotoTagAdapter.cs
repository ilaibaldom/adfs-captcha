using System;
using System.Collections.Generic;
using System.Net;
using System.Security.Claims;
using Microsoft.IdentityServer.Web.Authentication.External;

namespace PhotoTagCaptcha
{
    /// <summary>
    /// AD FS external authentication adapter (IAuthenticationAdapter).
    ///
    /// Flow, after primary authentication for an application whose policy requires MFA:
    ///   1. BeginAuthentication  -> photo + "Approve" (shown as a dialog over the AD FS page).
    ///   2. User clicks Approve  -> the form posts back to the current AD FS URL.
    ///   3. TryEndAuthentication -> we check the post and return the authenticationmethod claim.
    ///   4. AD FS completes sign-in and redirects the user back to the application.
    ///
    /// APPLICATION GUARD: with "allowedApplications" configured, the adapter refuses (no claim) for
    /// any other application, so it cannot stand in for real MFA elsewhere (see AppGuard). The guard
    /// runs first and never fails open.
    ///
    /// FAIL-OPEN (allowed applications only): the captcha must never lock a user out. If the photo cannot be shown (source
    /// unreachable, timeout, bad response, broken config) or the adapter hits an unexpected error,
    /// the user is let through WITHOUT the captcha and a warning is logged (event 2000/2001/3001).
    /// AD FS gives an adapter no way to finish straight from BeginAuthentication, so the skip is
    /// one self-submitting "Continuing..." page; the skip decision itself is stored server-side in
    /// IAuthenticationContext.Data (tamper-protected by AD FS), so a client cannot trigger it.
    ///
    /// AD FS creates one instance of this class and shares it across requests and threads, so
    /// per-request state goes into IAuthenticationContext.Data, never into fields on this class.
    /// </summary>
    public sealed class PhotoTagAdapter : IAuthenticationAdapter
    {
        internal const string ChallengeIdKey = "ptc.challengeId";
        internal const string PhotoIdKey = "ptc.photoId";
        internal const string UpnKey = "ptc.upn";
        internal const string SkipReasonKey = "ptc.skipReason";
        internal const string AllowedKey = "ptc.allowedTarget";   // guard passed (value = matched app)
        internal const string BlockedKey = "ptc.blocked";         // guard refused (value = reason)

        internal const string ChallengeIdField = "ChallengeId";
        internal const string ApproveField = "Approve";
        internal const string ContinueField = "PtcContinue";

        // Replaced atomically in OnAuthenticationPipelineLoad; null = configuration invalid.
        private volatile AdapterConfig _config = AdapterConfig.Default();

        public IAuthenticationAdapterMetadata Metadata { get; } = new PhotoTagMetadata();

        public void OnAuthenticationPipelineLoad(IAuthenticationMethodConfigData configData)
        {
            // Must not throw: an exception here stops AD FS from loading the provider, which would
            // break sign-in for the scoped application instead of failing open.
            try
            {
                var cfg = AdapterConfig.Load(configData?.Data, out var error);
                _config = cfg;
                if (cfg == null)
                {
                    Log.Warn(LogEvent.ConfigInvalid, $"The PhotoTagCaptcha configuration could not be read ({error}). Users will be let through without the captcha until it is fixed.");
                }
                Log.Info(LogEvent.PipelineLoaded, $"Pipeline loaded. Version {typeof(PhotoTagAdapter).Assembly.GetName().Version}, file version {FileVersion()}. Config: {(cfg?.ToString() ?? "INVALID (fail-open)")}.");
                if (cfg != null && !cfg.GuardEnabled)
                {
                    Log.Warn(LogEvent.GuardDisabled, "No allowedApplications configured: ANY application that requires MFA can be satisfied by this captcha. Set allowedApplications to the scoped application's identifier.");
                }
            }
            catch (Exception ex)
            {
                _config = null;
                Log.Warn(LogEvent.ConfigInvalid, $"Pipeline load failed; failing open. {ex}");
            }
        }

        public void OnAuthenticationPipelineUnload()
        {
            Log.Info(LogEvent.PipelineUnloaded, "Pipeline unloaded.");
        }

        public bool IsAvailableForUser(Claim identityClaim, IAuthenticationContext context)
        {
            // Which application triggers the adapter is decided by AD FS policy (see deploy\
            // Enable-PhotoTagCaptchaForApp.ps1), not here. Every user of that app is eligible.
            // Returning false would NOT fail open: AD FS would then report that no additional
            // authentication method is available and block the sign-in.
            // AD FS passes no request here, so the application guard runs in BeginAuthentication.
            if (_config?.Diagnostics == true)
            {
                Log.Info(LogEvent.Diagnostics, $"IsAvailableForUser for {identityClaim?.Value}:\n{AppGuard.Describe(null, context?.Data)}");
            }
            return true;
        }

        public IAdapterPresentation BeginAuthentication(Claim identityClaim, HttpListenerRequest request, IAuthenticationContext context)
        {
            Uri url = null;
            try { url = request?.Url; } catch (Exception) { }
            return BeginAuthentication(identityClaim, url, context);
        }

        /// <summary>Same as the AD FS entry point, with the request URL only (also used by the smoke tests).</summary>
        public IAdapterPresentation BeginAuthentication(Claim identityClaim, Uri requestUrl, IAuthenticationContext context)
        {
            var upn = identityClaim?.Value ?? string.Empty;
            var config = _config;

            if (config?.Diagnostics == true)
            {
                Log.Info(LogEvent.Diagnostics, $"BeginAuthentication for {upn}:\n{AppGuard.Describe(requestUrl, context?.Data)}");
            }

            // 1. Application guard. Runs before anything else and NEVER fails open: letting a
            //    non-allowed application through is exactly the MFA bypass the guard prevents.
            AppGuard.Result guard;
            try { guard = AppGuard.Check(config, requestUrl); }
            catch (Exception ex) { guard = new AppGuard.Result { Allowed = false, Detail = $"guard error: {ex.Message}" }; }

            if (!guard.Allowed)
            {
                try { context.Data[BlockedKey] = Truncate(guard.Detail, 500); } catch (Exception) { }
                Log.Warn(LogEvent.BlockedApplication, $"Refused the captcha for {upn}: {guard.Detail}. No claim issued; the user must use another method (activity {context?.ActivityId}).");
                return PhotoTagPresentation.NotAvailable();
            }

            // 2. Allowed application: show the photo, or fail open if it can't be shown.
            try
            {
                context.Data[AllowedKey] = guard.Target ?? "(guard off)";
                context.Data[UpnKey] = upn;
                return Issue(context, upn, message: null, reissue: false);
            }
            catch (Exception ex)
            {
                return Skip(context, upn, LogEvent.SkippedUnexpectedError, $"unexpected error while preparing the captcha: {ex}");
            }
        }

        public IAdapterPresentation TryEndAuthentication(IAuthenticationContext context, IProofData proofData, HttpListenerRequest request, out Claim[] claims)
        {
            claims = null;
            var upn = GetString(context?.Data, UpnKey);

            // Guard refused in BeginAuthentication: whatever is posted, never issue a claim.
            if (GetString(context?.Data, BlockedKey) != null || GetString(context?.Data, AllowedKey) == null)
            {
                return PhotoTagPresentation.NotAvailable();
            }

            try
            {
                // Fail-open path: decided in BeginAuthentication, stored server-side.
                var skipReason = GetString(context.Data, SkipReasonKey);
                if (skipReason != null)
                {
                    Log.Info(LogEvent.SkipCompleted, $"{upn} continued WITHOUT the captcha (reason: {skipReason}; activity {context.ActivityId}).");
                    claims = SuccessClaims();
                    return null;
                }

                var expectedChallenge = GetString(context.Data, ChallengeIdKey);
                var postedChallenge = GetString(proofData?.Properties, ChallengeIdField);
                var approved = proofData?.Properties != null && proofData.Properties.ContainsKey(ApproveField);

                if (string.IsNullOrEmpty(expectedChallenge) || !string.Equals(expectedChallenge, postedChallenge, StringComparison.Ordinal))
                {
                    Log.Info(LogEvent.ChallengeReissued, $"Challenge mismatch for {upn} (expected '{expectedChallenge}', got '{postedChallenge}', activity {context.ActivityId}). Re-issuing.");
                    return Issue(context, upn, "This page expired. Please review the photo again.", reissue: true);
                }

                if (!approved)
                {
                    return Issue(context, upn, "Click Approve to continue.", reissue: true);
                }

                // POC: this is where the research answer (tags) would be recorded.
                Log.Info(LogEvent.ChallengeApproved, $"Challenge {expectedChallenge} approved by {upn} (photo {GetString(context.Data, PhotoIdKey)}).");
                claims = SuccessClaims();
                return null; // null presentation + claims => AD FS treats this step as satisfied.
            }
            catch (Exception ex)
            {
                // Never lock the user out because of a bug in this adapter. Only reached for
                // sign-ins the guard already allowed (checked above).
                Log.Error(LogEvent.TryEndFailedOpen, $"Unexpected error completing the captcha for {upn}; letting the user through WITHOUT it. {ex}");
                claims = SuccessClaims();
                return null;
            }
        }

        public IAdapterPresentation OnError(HttpListenerRequest request, ExternalAuthenticationException ex)
        {
            // Called by AD FS for its own errors around this step; no claims can be issued here.
            Log.Error(LogEvent.AdfsReportedError, $"AD FS reported an error: {ex}");
            return PhotoTagPresentation.Error("Something went wrong. Please try signing in again.");
        }

        private IAdapterPresentation Issue(IAuthenticationContext context, string upn, string message, bool reissue)
        {
            var config = _config;
            if (!PhotoStore.TryGet(config, out var photo, out var reason))
            {
                return Skip(context, upn, LogEvent.SkippedPhotoUnavailable, $"photo unavailable: {reason}");
            }

            var challengeId = Guid.NewGuid().ToString("N");
            context.Data[ChallengeIdKey] = challengeId;
            context.Data[PhotoIdKey] = photo.Id;
            if (!reissue)
            {
                Log.Info(LogEvent.ChallengeIssued, $"Challenge {challengeId} issued to {upn} (photo {photo.Id}, activity {context.ActivityId}).");
            }
            return PhotoTagPresentation.Challenge(photo, challengeId, message, config.Popup);
        }

        private static IAdapterPresentation Skip(IAuthenticationContext context, string upn, LogEvent id, string reason)
        {
            try
            {
                context.Data.Remove(ChallengeIdKey);
                context.Data[SkipReasonKey] = Truncate(reason, 500);
            }
            catch (Exception)
            {
                // If even the context is unusable there is nothing better to do than show the page.
            }
            Log.Warn(id, $"Letting {upn} through WITHOUT the captcha: {reason} (activity {context?.ActivityId}).");
            return PhotoTagPresentation.Continue();
        }

        private static Claim[] SuccessClaims() => new[]
        {
            new Claim(ClaimTypes.AuthenticationMethod, PhotoTagMetadata.AuthenticationMethodUri)
        };

        private static string GetString(IDictionary<string, object> bag, string key)
        {
            if (bag == null || !bag.TryGetValue(key, out var value) || value == null)
            {
                return null;
            }
            return value as string ?? value.ToString();
        }

        private static string Truncate(string s, int max) => s == null || s.Length <= max ? s : s.Substring(0, max);

        private static string FileVersion()
        {
            try { return System.Diagnostics.FileVersionInfo.GetVersionInfo(typeof(PhotoTagAdapter).Assembly.Location).FileVersion; }
            catch (Exception) { return "?"; }
        }
    }
}
