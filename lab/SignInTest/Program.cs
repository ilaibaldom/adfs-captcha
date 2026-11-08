// Scripted end-to-end sign-in, doing what a browser does:
//   app -> AD FS forms sign-in -> [PhotoTagCaptcha page -> Approve] -> form_post back to app -> app page
//
//   dotnet run -- --app Research --expect captcha      (expects the photo step)
//   dotnet run -- --app Control  --expect none         (expects NO photo step)
//   optional: --user bob   --no-approve (stop at the photo page and report it)
//
// Trusts only the lab AD FS certificate and the localhost dev certificate. Exit code 0 = expectation met.

using System.Net;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.RegularExpressions;

string Arg(string name, string def) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : def; }
var appKey = Arg("--app", "Research");
var expect = Arg("--expect", "captcha");           // captcha | none | skip (photo unavailable -> fail-open) | blocked (guard refused)
var user = Arg("--user", "alice");
var approve = !args.Contains("--no-approve");
var port = appKey == "Research" ? 44301 : 44302;

var labDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
using var secrets = JsonDocument.Parse(File.ReadAllText(Path.Combine(labDir, "lab-credentials.json")));
var password = secrets.RootElement.GetProperty("UserPassword").GetString()!;
var adfsThumb = new X509Certificate2(@"C:\HyperV\AdfsLab\adfs-ssl.cer").Thumbprint;

// --node <ip>: send adfs.adfslab.test traffic to one specific farm node (default: DNS/hosts).
var node = Arg("--node", "");
var handler = new SocketsHttpHandler
{
    CookieContainer = new CookieContainer(),
    AllowAutoRedirect = true,
    SslOptions = new System.Net.Security.SslClientAuthenticationOptions
    {
        RemoteCertificateValidationCallback = (_, cert, _, errors) =>
            errors == System.Net.Security.SslPolicyErrors.None
            || (cert != null && new X509Certificate2(cert).Thumbprint == adfsThumb)
            || (cert != null && cert.Subject == "CN=localhost"),
    },
    ConnectCallback = async (ctx, ct) =>
    {
        var host = node != "" && ctx.DnsEndPoint.Host == "adfs.adfslab.test" ? node : ctx.DnsEndPoint.Host;
        var socket = new System.Net.Sockets.Socket(System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Tcp) { NoDelay = true };
        await socket.ConnectAsync(host, ctx.DnsEndPoint.Port, ct);
        return new System.Net.Sockets.NetworkStream(socket, ownsSocket: true);
    },
};
using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(60) };
http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 LabSignInTest");

void Step(string m) => Console.WriteLine($"  {m}");
int Fail(string m) { Console.WriteLine($"FAIL [{appKey}/{user}]: {m}"); return 1; }

Console.WriteLine($"== {appKey} (https://localhost:{port}) as {user}{(node != "" ? $" via AD FS node {node}" : "")}, expecting {(expect == "captcha" ? "the PhotoTagCaptcha step" : "NO captcha step")}");

// 1. App -> AD FS sign-in page
var resp = await http.GetAsync($"https://localhost:{port}/");
var html = await resp.Content.ReadAsStringAsync();
Step($"GET app -> {(int)resp.StatusCode} at {resp.RequestMessage!.RequestUri!.GetLeftPart(UriPartial.Path)}");
var login = Form.Find(html, f => f.Fields.ContainsKey("UserName"));
if (login == null) return Fail("AD FS forms sign-in page not reached.");

// 2. Credentials
login.Fields["UserName"] = $"{user}@adfslab.test";
login.Fields["Password"] = password;
login.Fields["AuthMethod"] = "FormsAuthentication";
(resp, html) = await Post(login, resp.RequestMessage.RequestUri);
Step($"POST credentials -> {(int)resp.StatusCode} at {resp.RequestMessage!.RequestUri!.GetLeftPart(UriPartial.Path)}");

// 3. Additional authentication?
// Guard refused this application: the "not available" page, no form, no way to complete.
if (html.Contains("data-ptc=\"not-available\""))
{
    Step("PhotoTagCaptcha REFUSED this application (\"not available\" page, no claim issued)");
    if (expect == "blocked") { Console.WriteLine($"PASS [{appKey}/{user}]: captcha refused for this application, sign-in not completed by it, as expected."); return 0; }
    return Fail("the captcha refused this application, which was not expected.");
}
if (expect == "blocked" && Form.Find(html, f => f.Fields.ContainsKey("ChallengeId")) != null)
    return Fail("the photo was offered to an application the guard should refuse (MFA bypass).");

var sawCaptcha = false;
var captcha = Form.Find(html, f => f.Fields.ContainsKey("ChallengeId"));
if (captcha != null)
{
    sawCaptcha = true;
    var photo = Regex.Match(html, @"Photo ([\w\-\.]+)</p>").Groups[1].Value;
    var mode = html.Contains("ptc-modal") ? "popup dialog" : "inline page";
    Step($"PhotoTagCaptcha page shown (photo {photo}, {mode}, AuthMethod={captcha.Fields.GetValueOrDefault("AuthMethod")})");
    if (!approve)
    {
        Console.WriteLine(expect == "captcha" ? $"PASS [{appKey}/{user}]: stopped at the photo page as asked." : "");
        return expect == "captcha" ? 0 : Fail("photo page shown but not expected.");
    }
    captcha.Fields["Approve"] = "Approve";
    (resp, html) = await Post(captcha, resp.RequestMessage.RequestUri);
    Step($"POST Approve -> {(int)resp.StatusCode}");
}
// Fail-open page (photo unavailable): a self-submitting "Continuing..." form.
var sawSkip = false;
var skip = Form.Find(html, f => f.Fields.ContainsKey("PtcContinue"));
if (skip != null)
{
    sawSkip = true;
    Step("Fail-open \"Continuing...\" page shown (photo unavailable); submitting it like the page script does");
    (resp, html) = await Post(skip, resp.RequestMessage!.RequestUri!);
    Step($"POST continue -> {(int)resp.StatusCode}");
}
else if (Regex.IsMatch(html, "errorText|Incorrect user ID or password", RegexOptions.IgnoreCase) && Form.Find(html, f => f.Fields.ContainsKey("UserName")) != null)
{
    return Fail("AD FS rejected the credentials.");
}

// 4. AD FS form_post (code + state) back to the app
var formPost = Form.Find(html, f => f.Fields.ContainsKey("code") && f.Fields.ContainsKey("state"));
if (formPost == null)
{
    var snippet = Regex.Replace(Regex.Replace(html, "<[^>]+>", " "), @"\s+", " ").Trim();
    return Fail($"no authorization response from AD FS. Page text: {snippet[..Math.Min(300, snippet.Length)]}");
}
(resp, html) = await Post(formPost, resp.RequestMessage!.RequestUri!);
Step($"POST code to app -> {(int)resp.StatusCode} at {resp.RequestMessage!.RequestUri}");

// 5. App page
var upn = Regex.Match(html, @"<p>Hello ([^<]+)</p>").Groups[1].Value;
var appSaysCaptcha = html.Contains("through the PhotoTagCaptcha step");
var amr = Regex.Matches(html, @"<td>(amr|http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod|authmethod)</td><td>([^<]+)</td>")
    .Select(m => m.Groups[2].Value).ToArray();
Step($"App page: Hello {upn}; auth methods in token: {string.Join(", ", amr)}");
if (string.IsNullOrEmpty(upn)) return Fail("app page not reached after sign-in.");

if (expect == "skip")
{
    // Photo unavailable: no photo page, the continue page, and the user still gets in.
    if (sawCaptcha || !sawSkip)
        return Fail($"expected the fail-open path; photo page shown={sawCaptcha}, continue page shown={sawSkip}.");
    Console.WriteLine($"PASS [{appKey}/{user}]: photo unavailable -> signed in WITHOUT seeing the captcha (fail-open), as expected.");
    return 0;
}
var wantCaptcha = expect == "captcha";
if (sawCaptcha != wantCaptcha || appSaysCaptcha != wantCaptcha || sawSkip)
    return Fail($"captcha page shown={sawCaptcha}, continue page shown={sawSkip}, token says captcha={appSaysCaptcha}, expected captcha={wantCaptcha}.");
Console.WriteLine($"PASS [{appKey}/{user}]: signed in {(wantCaptcha ? "WITH" : "WITHOUT")} the captcha step, as expected.");
return 0;

async Task<(HttpResponseMessage, string)> Post(Form f, Uri baseUri)
{
    var target = new Uri(baseUri, WebUtility.HtmlDecode(f.Action));
    var r = await http.PostAsync(target, new FormUrlEncodedContent(f.Fields));
    return (r, await r.Content.ReadAsStringAsync());
}

sealed class Form
{
    public string Action = "";
    public Dictionary<string, string> Fields = new();

    public static Form? Find(string html, Func<Form, bool> match)
    {
        foreach (Match fm in Regex.Matches(html, @"<form\b([^>]*)>(.*?)</form>", RegexOptions.Singleline | RegexOptions.IgnoreCase))
        {
            var f = new Form { Action = Attr(fm.Groups[1].Value, "action") ?? "" };
            foreach (Match im in Regex.Matches(fm.Groups[2].Value, @"<input\b([^>]*)>", RegexOptions.IgnoreCase))
            {
                var name = Attr(im.Groups[1].Value, "name");
                var type = Attr(im.Groups[1].Value, "type") ?? "text";
                if (name == null || type.Equals("submit", StringComparison.OrdinalIgnoreCase) || type.Equals("checkbox", StringComparison.OrdinalIgnoreCase)) continue;
                f.Fields[name] = WebUtility.HtmlDecode(Attr(im.Groups[1].Value, "value") ?? "");
            }
            if (match(f)) return f;
        }
        return null;
    }

    static string? Attr(string tag, string name)
    {
        var m = Regex.Match(tag, $@"\b{name}\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))", RegexOptions.IgnoreCase);
        return m.Success ? (m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Value) : null;
    }
}
