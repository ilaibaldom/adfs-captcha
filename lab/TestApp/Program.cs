// OIDC test app for the AD FS lab. One process per application group:
//   dotnet run -- --App Research    (https://localhost:44301, captcha scoped here)
//   dotnet run -- --App Control     (https://localhost:44302, control: no captcha)
// Client id/secret come from lab\lab-credentials.json (written by Build-Lab.ps1).

using System.Net;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;

var builder = WebApplication.CreateBuilder(args);

var appKey = builder.Configuration["App"] ?? "Research";
var labDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
var apps = new Dictionary<string, (string Name, int Port, string Resource)>
{
    ["Research"] = ("Research Portal", 44301, "https://research.adfslab.test/"),
    ["Control"] = ("Control App", 44302, "https://control.adfslab.test/"),
};
var app = apps[appKey];

using var secretsDoc = JsonDocument.Parse(File.ReadAllText(Path.Combine(labDir, "lab-credentials.json")));
var appSecrets = secretsDoc.RootElement.GetProperty("Apps").GetProperty(appKey);
var clientId = appSecrets.GetProperty("ClientId").GetString()!;
var clientSecret = appSecrets.GetProperty("ClientSecret").GetString()!;

// Trust exactly the lab's self-signed AD FS certificate for back-channel calls (metadata, token),
// without adding it to this PC's trust store.
var adfsCert = new X509Certificate2(@"C:\HyperV\AdfsLab\adfs-ssl.cer");
var backchannel = new HttpClientHandler
{
    ServerCertificateCustomValidationCallback = (_, cert, _, errors) =>
        errors == System.Net.Security.SslPolicyErrors.None || (cert != null && cert.Thumbprint == adfsCert.Thumbprint),
};

builder.WebHost.UseUrls($"https://localhost:{app.Port}");

builder.Services
    .AddAuthentication(o =>
    {
        o.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        o.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
    })
    .AddCookie(o => o.Cookie.Name = $".Lab.{appKey}")   // cookies ignore ports: keep the two apps apart
    .AddOpenIdConnect(o =>
    {
        o.Authority = "https://adfs.adfslab.test/adfs";
        o.ClientId = clientId;
        o.ClientSecret = clientSecret;
        o.Resource = app.Resource;            // AD FS evaluates THIS Web API's access control policy
        o.ResponseType = "code";
        o.UsePkce = true;
        o.Scope.Add("allatclaims");           // put the Web API's issued claims into the id_token
        o.SaveTokens = true;
        o.MapInboundClaims = false;
        o.GetClaimsFromUserInfoEndpoint = false;
        o.BackchannelHttpHandler = backchannel;
        o.CorrelationCookie.Name = $".Lab.{appKey}.Correlation.";
        o.NonceCookie.Name = $".Lab.{appKey}.Nonce.";
    });
builder.Services.AddAuthorization();

var web = builder.Build();
web.UseAuthentication();
web.UseAuthorization();

web.MapGet("/", (HttpContext ctx) =>
{
    var rows = string.Join("", ctx.User.Claims.Select(c =>
        $"<tr><td>{WebUtility.HtmlEncode(c.Type)}</td><td>{WebUtility.HtmlEncode(c.Value)}</td></tr>"));
    var captcha = ctx.User.Claims.Any(c => c.Value == "urn:phototag:captcha:poc");
    var badge = captcha
        ? "<p class='ok'>Signed in <b>through the PhotoTagCaptcha step</b> (urn:phototag:captcha:poc).</p>"
        : "<p class='plain'>Signed in <b>without</b> the PhotoTagCaptcha step.</p>";
    return Results.Content($@"<!DOCTYPE html><html><head><meta charset='utf-8'><title>{app.Name}</title>
<style>body{{font-family:Segoe UI,sans-serif;margin:32px;max-width:960px}} td{{border-bottom:1px solid #ddd;padding:4px 8px;font-size:13px;word-break:break-all}}
.ok{{background:#e6f4ea;padding:8px}} .plain{{background:#f1f3f4;padding:8px}}</style></head>
<body><h1>{app.Name}</h1><p>Hello {WebUtility.HtmlEncode(ctx.User.FindFirst("upn")?.Value ?? ctx.User.Identity?.Name)}</p>{badge}
<h3>Claims</h3><table>{rows}</table><p><a href='/logout'>Sign out of this app</a></p></body></html>", "text/html");
}).RequireAuthorization();

web.MapGet("/logout", async (HttpContext ctx) =>
{
    await ctx.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    return Results.Content("Signed out of the app (AD FS SSO session still active).", "text/plain");
});

web.Run();
