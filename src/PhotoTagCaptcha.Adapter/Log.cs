using System;
using System.Diagnostics;

namespace PhotoTagCaptcha
{
    /// <summary>Event IDs written to the Application log (source "PhotoTagCaptcha").</summary>
    public enum LogEvent
    {
        // 1xxx information
        PipelineLoaded = 1000,
        PipelineUnloaded = 1001,
        ChallengeIssued = 1100,
        ChallengeApproved = 1101,
        ChallengeReissued = 1102,
        SkipCompleted = 1200,     // user continued without the captcha (after a 2xxx skip)
        Diagnostics = 1900,       // only with "diagnostics": true

        // 2xxx warnings: the user was let through WITHOUT the captcha (fail-open)
        SkippedPhotoUnavailable = 2000,
        SkippedUnexpectedError = 2001,
        ConfigInvalid = 2100,
        GuardDisabled = 2101,     // no allowedApplications: any app requiring MFA can use the captcha

        // 22xx warnings: the guard REFUSED (no claim issued; MFA not satisfied by this captcha)
        BlockedApplication = 2200,

        // 3xxx errors
        AdfsReportedError = 3000,
        TryEndFailedOpen = 3001,
    }

    /// <summary>
    /// Writes to the Windows "Application" event log under source "PhotoTagCaptcha", with a
    /// distinct Event ID per event type (see LogEvent) for filtering and forwarding.
    /// Chosen over a log file: the AD FS service account can write it without extra folder
    /// permissions, there is no rotation to manage, and Windows Event Forwarding / a SIEM can
    /// collect it from every farm node.
    /// The AD FS service account cannot create event sources, so the install script creates it.
    /// If the source does not exist, logging is silently skipped; it never breaks sign-in.
    /// </summary>
    internal static class Log
    {
        public const string Source = "PhotoTagCaptcha";

        public static void Info(LogEvent id, string message) => Write(id, message, EventLogEntryType.Information);

        public static void Warn(LogEvent id, string message) => Write(id, message, EventLogEntryType.Warning);

        public static void Error(LogEvent id, string message) => Write(id, message, EventLogEntryType.Error);

        private static void Write(LogEvent id, string message, EventLogEntryType type)
        {
            // No EventLog.SourceExists() check: it scans the Security log and throws for the
            // (non-admin) AD FS service account. WriteEntry works once the source is registered.
            try
            {
                WriteCore((int)id, message, type);
            }
            catch (Exception)
            {
                // Logging must never affect authentication.
            }
        }

        // Separate, non-inlined method so that even a type-load failure while JIT-compiling the
        // EventLog call surfaces inside the try block above.
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        private static void WriteCore(int id, string message, EventLogEntryType type)
        {
            // Event log messages are limited to ~31k characters.
            if (message.Length > 30000) message = message.Substring(0, 30000) + " ...(truncated)";
            EventLog.WriteEntry(Source, message, type, id);
        }
    }
}
