using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Claims;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.IdentityServer.Web.Authentication.External;
using PhotoTagCaptcha;

internal sealed class FakeContext : IAuthenticationContext
{
    public string ActivityId { get; } = Guid.NewGuid().ToString();
    public string ContextId { get; } = Guid.NewGuid().ToString();
    public Dictionary<string, object> Data { get; } = new Dictionary<string, object>();
    public int Lcid => 1033;
}

internal sealed class FakeProof : IProofData
{
    public FakeProof(Dictionary<string, object> properties) => Properties = properties;
    public Dictionary<string, object> Properties { get; }
}

internal sealed class FakeConfig : IAuthenticationMethodConfigData
{
    public FakeConfig(string json, bool bom = false) =>
        Data = new MemoryStream((bom ? new byte[] { 0xEF, 0xBB, 0xBF } : new byte[0]).Concat(new UTF8Encoding(false).GetBytes(json)).ToArray());
    public Stream Data { get; }
}

/// <summary>Tiny HTTP server for photo-source tests (no HttpListener: that needs URL ACLs).</summary>
internal sealed class TestPhotoServer : IDisposable
{
    private readonly TcpListener _listener = new TcpListener(IPAddress.Loopback, 0);
    private readonly byte[] _jpeg;
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public TestPhotoServer(byte[] jpeg)
    {
        _jpeg = jpeg;
        _listener.Start();
        Task.Run(Loop);
    }

    private async Task Loop()
    {
        while (true)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(); } catch { return; }
            _ = Task.Run(() => Handle(client));
        }
    }

    private void Handle(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        {
            var reader = new StreamReader(stream, Encoding.ASCII);
            var path = (reader.ReadLine() ?? "").Split(' ').ElementAtOrDefault(1) ?? "/";
            while (!string.IsNullOrEmpty(reader.ReadLine())) { }
            byte[] body; string type; int status = 200; string extra = "";
            switch (path)
            {
                case "/photo.jpg": body = _jpeg; type = "image/jpeg"; extra = "X-Photo-Id: research-42\r\n"; break;
                case "/html": body = Encoding.UTF8.GetBytes("<html>login page</html>"); type = "text/html"; break;
                case "/big": body = new byte[3 * 1024 * 1024]; type = "image/jpeg"; break;
                case "/slow": Thread.Sleep(5000); body = _jpeg; type = "image/jpeg"; break;
                default: status = 404; body = Encoding.UTF8.GetBytes("not found"); type = "text/plain"; break;
            }
            var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} X\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\n{extra}Connection: close\r\n\r\n");
            try { stream.Write(head, 0, head.Length); stream.Write(body, 0, body.Length); } catch { }
        }
    }

    public void Dispose() => _listener.Stop();
}

internal static class Program
{
    private static int _failures;
    private static readonly Claim User = new Claim("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn", "alice@contoso.com");

    private static int Main(string[] args)
    {
        var outDir = args.Length > 0 ? args[0] : Path.Combine(AppContext.BaseDirectory, "out");
        Directory.CreateDirectory(outDir);

        var adapter = new PhotoTagAdapter();
        adapter.OnAuthenticationPipelineLoad(null);

        // Metadata sanity
        Check("metadata: requires identity (MFA stage)", adapter.Metadata.RequiresIdentity);
        Check("metadata: one auth method URI", adapter.Metadata.AuthenticationMethods.SequenceEqual(new[] { PhotoTagMetadata.AuthenticationMethodUri }));
        Check("metadata: friendly name for every LCID", adapter.Metadata.AvailableLcids.All(l => adapter.Metadata.FriendlyNames.ContainsKey(l) && adapter.Metadata.Descriptions.ContainsKey(l)));

        // 1. Default config: embedded photo, popup dialog
        var ctx = new FakeContext();
        var page = adapter.BeginAuthentication(User, (Uri)null, ctx) as IAdapterPresentationForm;
        Check("begin: returns a form", page != null);
        var html = page.GetFormHtml(1033);
        Check("begin: form posts AuthMethod/Context placeholders", html.Contains("%AuthMethod%") && html.Contains("%Context%"));
        // Verified on AD FS 2019: %PageActionUrl% is NOT substituted; the form must post to the current URL.
        Check("begin: no action attribute / %PageActionUrl%", !html.Contains("%PageActionUrl%") && !System.Text.RegularExpressions.Regex.IsMatch(html, @"<form[^>]*\saction\s*="));
        Check("begin: embedded photo as data URI", html.Contains("data:image/jpeg;base64,") && html.Contains("Photo sample-001"));
        Check("begin: popup dialog by default", html.Contains("ptc-modal") && html.Contains("role=\"dialog\""));
        Check("begin: challenge page has no <script>", !html.Contains("<script", StringComparison.OrdinalIgnoreCase));
        var challenge = (string)ctx.Data["ptc.challengeId"];
        WritePreview(Path.Combine(outDir, "preview.html"), page);

        // 2. Approve with the right challenge -> claim, no presentation
        var ok = adapter.TryEndAuthentication(ctx, Proof(challenge, approve: true), null, out var claims);
        Check("approve: no further presentation", ok == null);
        Check("approve: emits authenticationmethod claim", IsSuccess(claims));

        // 3. Tampered / stale challenge -> re-prompt with new challenge, no claims
        var ctx2 = new FakeContext();
        adapter.BeginAuthentication(User, (Uri)null, ctx2);
        var oldChallenge = (string)ctx2.Data["ptc.challengeId"];
        var bad = adapter.TryEndAuthentication(ctx2, Proof("not-the-challenge", approve: true), null, out var badClaims);
        Check("wrong challenge: re-prompts", bad is IAdapterPresentationForm f2 && f2.GetFormHtml(1033).Contains("ChallengeId"));
        Check("wrong challenge: no claims", badClaims == null);
        Check("wrong challenge: challenge rotated", (string)ctx2.Data["ptc.challengeId"] != oldChallenge);
        WritePreview(Path.Combine(outDir, "preview-error.html"), (IAdapterPresentationForm)bad);

        // 4. Posted without pressing Approve -> re-prompt
        var ctx3 = new FakeContext();
        adapter.BeginAuthentication(User, (Uri)null, ctx3);
        var noApprove = adapter.TryEndAuthentication(ctx3, Proof((string)ctx3.Data["ptc.challengeId"], approve: false), null, out var noClaims);
        Check("no approve: re-prompts without claims", noApprove != null && noClaims == null);

        // 5. A client cannot skip: posting PtcContinue without a server-side skip decision does nothing
        var ctx4 = new FakeContext();
        adapter.BeginAuthentication(User, (Uri)null, ctx4);
        var forged = adapter.TryEndAuthentication(ctx4, new FakeProof(new Dictionary<string, object> { ["PtcContinue"] = "1" }), null, out var forgedClaims);
        Check("forged continue: no claims, re-prompted", forgedClaims == null && forged != null);

        // 6. OnError renders something
        var err = adapter.OnError(null, new ExternalAuthenticationException("boom", ctx)) as IAdapterPresentationForm;
        Check("onError: returns a form with a message", err != null && err.GetFormHtml(1033).Contains("ptc-error"));

        // 7. Photo sources and FAIL-OPEN
        var jpeg = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "photo.jpg"));
        var tmp = Path.Combine(Path.GetTempPath(), $"ptc-{Guid.NewGuid():N}.jpg");
        File.WriteAllBytes(tmp, jpeg);
        using (var server = new TestPhotoServer(jpeg))
        {
            var fileUrl = new Uri(tmp).AbsoluteUri;
            var http = $"http://127.0.0.1:{server.Port}";

            ExpectPhoto("file:// photo shown", $"{{\"photoUrl\":\"{fileUrl}\"}}", Path.GetFileNameWithoutExtension(tmp));
            ExpectPhoto("http photo shown, X-Photo-Id used", $"{{\"photoUrl\":\"{http}/photo.jpg\"}}", "research-42");
            ExpectPhoto("displayMode=page renders inline", $"{{\"displayMode\":\"page\"}}", "sample-001", popup: false);
            // Windows PowerShell 5.1 / Notepad write a UTF-8 BOM; the lab config was rejected because of it.
            ExpectPhoto("config file with UTF-8 BOM is accepted", $"{{\"photoUrl\":\"{http}/photo.jpg\"}}", "research-42", bom: true);

            ExpectSkip("missing file -> skip", "{\"photoUrl\":\"file:///C:/does/not/exist.jpg\"}", outDir);
            ExpectSkip("HTTP 404 -> skip", $"{{\"photoUrl\":\"{http}/nope.jpg\"}}");
            ExpectSkip("non-image response -> skip", $"{{\"photoUrl\":\"{http}/html\"}}");
            ExpectSkip("oversized image -> skip", $"{{\"photoUrl\":\"{http}/big\",\"maxBytes\":1048576}}");
            ExpectSkip("connection refused -> skip", "{\"photoUrl\":\"http://127.0.0.1:9/photo.jpg\"}");
            var sw = Stopwatch.StartNew();
            ExpectSkip("slow source -> skip at timeout", $"{{\"photoUrl\":\"{http}/slow\",\"timeoutMs\":1500}}");
            Check($"slow source: gave up within ~timeout ({sw.ElapsedMilliseconds} ms)", sw.ElapsedMilliseconds < 4000);
            ExpectSkip("unsupported scheme -> skip", "{\"photoUrl\":\"ftp://example/x.jpg\"}");
            ExpectSkip("invalid JSON config -> skip", "{ this is not json");
        }
        File.Delete(tmp);

        // 8. Application guard
        GuardTests();

        adapter.OnAuthenticationPipelineUnload();

        Console.WriteLine();
        Console.WriteLine($"Preview: {Path.Combine(outDir, "preview.html")}");
        Console.WriteLine(_failures == 0 ? "ALL CHECKS PASSED" : $"{_failures} CHECK(S) FAILED");
        return _failures == 0 ? 0 : 1;
    }

    private const string Adfs = "https://adfs.contoso.com/adfs/oauth2/authorize/?client-request-id=1&response_type=code";

    private static void GuardTests()
    {
        // Target identification
        Check("guard: resource is the target", AppGuard.IdentifyTarget(new Uri(Adfs + "&client_id=abc&resource=https%3A%2F%2Fresearch.contoso.com%2F")) == ("https://research.contoso.com/", "resource"));
        Check("guard: client_id only when no target", AppGuard.IdentifyTarget(new Uri(Adfs + "&client_id=abc")) == ("abc", "client_id"));
        Check("guard: WS-Fed wtrealm", AppGuard.IdentifyTarget(new Uri("https://adfs.contoso.com/adfs/ls/?wa=wsignin1.0&wtrealm=urn%3Aresearch")) == ("urn:research", "wtrealm"));
        Check("guard: SAML redirect-binding issuer", AppGuard.IdentifyTarget(new Uri("https://adfs.contoso.com/adfs/ls/?SAMLRequest=" + Uri.EscapeDataString(SamlRedirect("https://sp.research.contoso.com")))) == ("https://sp.research.contoso.com", "saml-issuer"));
        Check("guard: no identifiers -> unidentified", AppGuard.IdentifyTarget(new Uri(Adfs)).Target == null && AppGuard.IdentifyTarget(null).Target == null);

        const string allow = "{\"allowedApplications\":[\"https://Research.contoso.com\", \"urn:research\"]}";
        var research = new Uri(Adfs + "&client_id=abc&resource=https%3A%2F%2Fresearch.contoso.com%2F");
        var other = new Uri(Adfs + "&client_id=abc&resource=https%3A%2F%2Fpayroll.contoso.com%2F");

        // Allowed app: photo, approve -> claim (case and trailing slash ignored)
        var a = WithConfig(allow);
        var ctx = new FakeContext();
        var html = ((IAdapterPresentationForm)a.BeginAuthentication(User, research, ctx)).GetFormHtml(1033);
        var ok = a.TryEndAuthentication(ctx, Proof((string)ctx.Data["ptc.challengeId"], approve: true), null, out var claims);
        Check("guard: allowed app gets the photo and the claim", html.Contains("ChallengeId") && ok == null && IsSuccess(claims));

        // Other app: refused; forged approve/continue never yields a claim
        var ctx2 = new FakeContext();
        var page = (IAdapterPresentationForm)a.BeginAuthentication(User, other, ctx2);
        var refused = page.GetFormHtml(1033).Contains("not-available") && !page.GetFormHtml(1033).Contains("<form");
        a.TryEndAuthentication(ctx2, new FakeProof(new Dictionary<string, object> { ["Approve"] = "Approve", ["PtcContinue"] = "1", ["ChallengeId"] = "x" }), null, out var c2);
        Check("guard: other app refused, forged post gives no claim", refused && c2 == null && ctx2.Data.ContainsKey("ptc.blocked"));
        WritePreview(Path.Combine(AppContext.BaseDirectory, "preview-blocked.html"), page);

        // The bypass the target rule prevents: an allowed client_id asking for another resource
        var a2 = WithConfig("{\"allowedApplications\":[\"abc\"]}");
        var ctx3 = new FakeContext();
        var p3 = ((IAdapterPresentationForm)a2.BeginAuthentication(User, other, ctx3)).GetFormHtml(1033);
        Check("guard: allowed client_id + other resource is refused", p3.Contains("not-available"));
        var ctx3b = new FakeContext();
        Check("guard: client_id listed, no resource -> allowed", ((IAdapterPresentationForm)a2.BeginAuthentication(User, new Uri(Adfs + "&client_id=abc"), ctx3b)).GetFormHtml(1033).Contains("ChallengeId"));

        // Unidentified request
        var ctx4 = new FakeContext();
        Check("guard: unidentified app refused by default", ((IAdapterPresentationForm)a.BeginAuthentication(User, (Uri)null, ctx4)).GetFormHtml(1033).Contains("not-available"));
        var a3 = WithConfig("{\"allowedApplications\":[\"urn:research\"],\"allowUnidentified\":true}");
        var ctx5 = new FakeContext();
        Check("guard: unidentified app allowed with allowUnidentified", ((IAdapterPresentationForm)a3.BeginAuthentication(User, (Uri)null, ctx5)).GetFormHtml(1033).Contains("ChallengeId"));

        // Fail-open still applies to the allowed app, never to a refused one
        var a4 = WithConfig("{\"allowedApplications\":[\"https://research.contoso.com/\"],\"photoUrl\":\"file:///C:/does/not/exist.jpg\"}");
        var ctx6 = new FakeContext();
        var skip = ((IAdapterPresentationForm)a4.BeginAuthentication(User, research, ctx6)).GetFormHtml(1033);
        a4.TryEndAuthentication(ctx6, new FakeProof(new Dictionary<string, object> { ["PtcContinue"] = "1" }), null, out var c6);
        Check("guard: allowed app + photo unavailable -> fail-open", skip.Contains("PtcContinue") && IsSuccess(c6));
        var ctx7 = new FakeContext();
        var blockedSkip = ((IAdapterPresentationForm)a4.BeginAuthentication(User, other, ctx7)).GetFormHtml(1033);
        a4.TryEndAuthentication(ctx7, new FakeProof(new Dictionary<string, object> { ["PtcContinue"] = "1" }), null, out var c7);
        Check("guard: other app + photo unavailable -> still refused", blockedSkip.Contains("not-available") && c7 == null);

        // Guard off (no list): previous behavior
        var ctx8 = new FakeContext();
        Check("guard: off without allowedApplications", ((IAdapterPresentationForm)WithConfig("{}").BeginAuthentication(User, other, ctx8)).GetFormHtml(1033).Contains("ChallengeId"));
    }

    private static string SamlRedirect(string issuer)
    {
        var xml = $"<samlp:AuthnRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" ID=\"_1\" Version=\"2.0\" IssueInstant=\"2026-01-01T00:00:00Z\"><saml:Issuer xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\">{issuer}</saml:Issuer></samlp:AuthnRequest>";
        using var ms = new MemoryStream();
        using (var d = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
        {
            var b = Encoding.UTF8.GetBytes(xml);
            d.Write(b, 0, b.Length);
        }
        return Convert.ToBase64String(ms.ToArray());
    }

    private static PhotoTagAdapter WithConfig(string json, bool bom = false)
    {
        var a = new PhotoTagAdapter();
        a.OnAuthenticationPipelineLoad(new FakeConfig(json, bom));
        return a;
    }

    private static void ExpectPhoto(string name, string json, string photoId, bool popup = true, bool bom = false)
    {
        var a = WithConfig(json, bom);
        var ctx = new FakeContext();
        var html = ((IAdapterPresentationForm)a.BeginAuthentication(User, (Uri)null, ctx)).GetFormHtml(1033);
        Check($"{name}", html.Contains("ChallengeId") && html.Contains("data:image/") && html.Contains($"Photo {photoId}") && html.Contains("ptc-modal") == popup);
    }

    private static void ExpectSkip(string name, string json, string previewDir = null)
    {
        var a = WithConfig(json);
        var ctx = new FakeContext();
        var page = (IAdapterPresentationForm)a.BeginAuthentication(User, (Uri)null, ctx);
        var html = page.GetFormHtml(1033);
        var skipPage = html.Contains("PtcContinue") && !html.Contains("ChallengeId") && html.Contains("%Context%");
        var end = a.TryEndAuthentication(ctx, new FakeProof(new Dictionary<string, object> { ["PtcContinue"] = "1" }), null, out var claims);
        Check($"{name}: continue page, then signed in", skipPage && end == null && IsSuccess(claims) && ctx.Data.ContainsKey("ptc.skipReason"));
        if (previewDir != null) WritePreview(Path.Combine(previewDir, "preview-skip.html"), page);
    }

    private static bool IsSuccess(Claim[] claims) =>
        claims != null && claims.Length == 1 && claims[0].Type == ClaimTypes.AuthenticationMethod && claims[0].Value == PhotoTagMetadata.AuthenticationMethodUri;

    private static FakeProof Proof(string challenge, bool approve)
    {
        var props = new Dictionary<string, object> { { "ChallengeId", challenge }, { "AuthMethod", "PhotoTagCaptcha" } };
        if (approve) props["Approve"] = "Approve";
        return new FakeProof(props);
    }

    private static void Check(string name, bool condition)
    {
        Console.WriteLine($"  [{(condition ? "PASS" : "FAIL")}] {name}");
        if (!condition) _failures++;
    }

    // Approximates the AD FS 2019 sign-in page so the form can be eyeballed in a browser.
    private static void WritePreview(string path, IAdapterPresentationForm page)
    {
        var form = page.GetFormHtml(1033)
            .Replace("%AuthMethod%", "PhotoTagCaptcha")
            .Replace("%Context%", "preview-context")
            .Replace("document.getElementById('ptcContinueForm').submit();", "/* auto-submit disabled in preview */");

        var doc = $@"<!DOCTYPE html>
<html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">
<title>{page.GetPageTitle(1033)} - AD FS preview</title>
<style>
  body {{ margin:0; font-family:'Segoe UI','Segoe',Tahoma,Helvetica,Arial,sans-serif; font-size:15px; color:#262626; background:#e9ecef; }}
  #fullPage {{ min-height:100vh; display:flex; align-items:center; justify-content:center; padding:16px; box-sizing:border-box; }}
  #contentWrapper {{ background:#fff; width:100%; max-width:440px; padding:44px; box-sizing:border-box; box-shadow:0 2px 6px rgba(0,0,0,.2); }}
  #companyName {{ font-size:1.6em; margin-bottom:24px; }}
  #header {{ font-size:1.2em; margin:0 0 16px; }}
  input.submit {{ background:#0067b8; color:#fff; border:none; padding:6px 20px; font-size:15px; cursor:pointer; }}
  input.submit:hover {{ background:#005da6; }}
  #previewNote {{ font-size:12px; color:#888; margin-top:24px; border-top:1px solid #eee; padding-top:8px; }}
</style>
{page.GetFormPreRenderHtml(1033)}
</head><body><div id=""fullPage""><div id=""contentWrapper"">
  <div id=""companyName"">Contoso</div>
  <div id=""header"">alice@contoso.com</div>
  {form}
  <div id=""previewNote"">Local preview. On AD FS this form is rendered inside your farm's sign-in theme.</div>
</div></div></body></html>";
        File.WriteAllText(path, doc);
    }
}
