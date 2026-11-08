# PhotoTagCaptcha: AD FS custom authentication adapter (POC)

An AD FS **external authentication provider** (`IAuthenticationAdapter`) that, after normal sign-in,
shows the user a photo with an **Approve** button, as a dialog over the AD FS sign-in page.
Clicking Approve completes sign-in and AD FS returns the user to the application. It applies to
**one application group** only. If the photo can't be shown, the user is **let through without the
captcha** and a warning is logged. The captcha never locks anyone out.

This is the base for the real feature: an iframe captcha in which users tag photos for the data
science team.

```
User --> App --> AD FS primary auth (forms / WIA)
                    |  app policy requires MFA (only the scoped app)
                    v
          PhotoTagAdapter.BeginAuthentication
             |-- photo available:   dialog with photo + [Approve]
             |                         | POST (AuthMethod, Context, ChallengeId, Approve)
             |                         v
             |                      TryEndAuthentication -> claim authenticationmethod = urn:phototag:captcha:poc
             |
             `-- photo unavailable: "Continuing..." page, submits itself       (event 2000, Warning)
                                       v
                                    TryEndAuthentication -> same claim, user gets in (event 1200)
                    v
          AD FS issues token --> redirect back to App
```

## Layout

| Path | What |
|---|---|
| `src/PhotoTagCaptcha.Adapter/` | The adapter (net472, strong-named). Sample photo embedded from `Assets/photo.jpg`; other sources via config. |
| `src/Microsoft.IdentityServer.Web.Stub/` | Compile-time-only stand-in for the AD FS assembly. **Never deploy.** |
| `tools/PreviewHarness/` | Local smoke tests; drives the adapter like AD FS does and writes `out/preview.html`. |
| `deploy/` | AD FS PowerShell: install, configure, scope to one app, report scope, roll back, uninstall. |
| `keys/` | `PhotoTagCaptcha.snk` (adapter signing key, **keep it**) and Microsoft's public key for the stub. |
| `build.ps1` | Build, verify, test, stage everything into `dist/`. |

## Build (dev machine)

Requires the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`). Nothing else: the .NET Framework
4.7.2 reference assemblies come from NuGet.

```powershell
.\build.ps1
```

This will:

1. Build `PhotoTagCaptcha.Adapter.dll`.
2. Verify it is strong-named and references
   `Microsoft.IdentityServer.Web, Version=10.0.0.0, PublicKeyToken=31bf3856ad364e35`.
3. If `lib\Microsoft.IdentityServer.Web.dll` is present, compile against it and compare the stub
   with it interface by interface (`tools\Compare-AdfsStub.ps1`). The build fails on any
   difference.
4. Run 15 smoke tests and write `out/preview.html`.
5. Stage the DLL and scripts into `dist/`.

### About the reference stub

`Microsoft.IdentityServer.Web.dll` exists only on AD FS servers and is not on NuGet. The stub has
the same assembly identity and the same interfaces, delay-signed with Microsoft's public key. That
key is public and is read from `System.Web.Extensions.dll`. The adapter therefore compiles with the
correct reference, and on the server the CLR binds it to the real assembly in the GAC.

The stub has been verified against the real assembly from an **AD FS 2019 (build 17763)** farm in
the lab: every public interface, base interface and member signature is identical. The first
version of the stub was not. It flattened `IAuthenticationAdapterBase` into
`IAuthenticationAdapter` and typed `IProofData.Properties` as `IDictionary`. Both compile fine but
fail when AD FS loads the adapter, which is why the build now checks automatically.

**Recommended for your own farm:** copy `C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll` from one
of your AD FS servers into `lib\` and run `.\build.ps1` again. The build then compiles against your
exact version and re-runs the comparison. Do not commit or redistribute that DLL.

## Deploy (AD FS 2016 / 2019 / 2022 / 2025)

Copy `dist\` to every AD FS server (not to the WAP servers). Run in an elevated Windows PowerShell.

This order was verified on a two-node AD FS 2019 WID farm in the lab (see `lab\`).

**1. On every secondary node, put the DLL in the GAC.** This doesn't restart AD FS yet, so there is
no outage:

```powershell
.\Install-PhotoTagCaptcha.ps1 -GacOnly
```

**2. Install on the primary node** (WID farm; for a SQL farm, any one node). Pass a configuration
whose `allowedApplications` contains your app group's Web API identifier (see
**Application guard**):

```powershell
Copy-Item .\phototag-config.sample.json .\phototag-config.json   # then edit allowedApplications
.\Install-PhotoTagCaptcha.ps1 -ConfigFile .\phototag-config.json
```

This adds the DLL to the GAC, creates the event source, runs `Register-AdfsAuthenticationProvider`,
adds the provider to the global additional providers, and restarts `adfssrv` on the primary.
Registration is farm-wide, which is why every node must already have the DLL.

**3. On every secondary, after it has synced, run the same command again**, one node at a time,
drained at the load balancer:

```powershell
Get-AdfsSyncProperties          # LastSyncTime must be later than step 2 (WID polls every 5 min)
.\Install-PhotoTagCaptcha.ps1 -GacOnly
```

Now the node's configuration contains the provider, so the script restarts AD FS and the node
loads it. A secondary restarted *before* its sync does not load the provider. Check the
Application log for source `PhotoTagCaptcha`, message "Pipeline loaded.", on every node.

At this point **no application uses it yet.** AD FS only calls additional providers for
applications whose policy requires MFA. In the lab, both test apps signed in exactly as before on
both nodes at this stage.

**4. Scope it to your application group** (primary node):

```powershell
.\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier '<your application group>'
# or, for a classic relying party trust:
.\Enable-PhotoTagCaptchaForApp.ps1 -RelyingPartyName '<rp name>'
```

**5. Confirm only that app is affected:**

```powershell
.\Get-PhotoTagCaptchaScope.ps1
```

**Replication delay.** Policy changes, both scoping and rollback, reach WID secondaries only at
their next sync, up to 5 minutes later. Until then, a user whose request lands on a secondary
gets the old behavior. In the lab, Research Portal showed the photo through the primary
immediately, but not through the secondary until its sync.

**Expected transient errors.** When a secondary's sync coincides with the primary restarting,
which every install or configuration change on the primary does, the secondary logs AD FS/Admin
events **344, 345 and 543** ("server is shutting down"). The next sync succeeds. Seen in the lab
and harmless.

### How "only one application" works

AD FS has no per-application provider setting. Scope comes from two facts:

* The provider is in the global list of additional providers. On its own this does nothing.
* Additional authentication runs only for applications whose access policy requires MFA.

For an application group, the policy lives on the group's **Web API application**: the resource
the client asks a token for. Native and server apps in the group have no policy. The Enable script
changes only that Web API's policy:

| Current policy on the Web API | What the script does |
|---|---|
| `Permit everyone` | Switches it to `Permit everyone and require MFA`. |
| Already an MFA policy | Nothing. |
| No access control policy (legacy claim rules) | Appends an MFA trigger rule to `AdditionalAuthenticationRules`; authorization rules are untouched. |
| Anything else, e.g. `Permit specific group` | **Refuses**, because replacing the policy would change who may sign in. Create a copy of that policy with "require MFA" in the AD FS console, then pass `-AccessControlPolicyName '<copy>'`. |

The previous settings are saved to `phototag-scope-state.json`. To restore them:

```powershell
.\Disable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier '<group>'
```

Check these before relying on the POC. `Get-PhotoTagCaptchaScope.ps1` warns about each one:

* **Other apps that already require MFA** will also offer the captcha. Set `allowedApplications`
  (see **Application guard**) so the captcha refuses for them.
* **A global MFA rule** (`Get-AdfsAdditionalAuthenticationRule`) applies to every application.
* **Other enabled providers** (Azure MFA, certificate, and so on): users of your app see a
  "choose a method" page instead of going straight to the photo.

### Test it

* Sign in to the application. After the password step you should see the photo; Approve sends you
  back to the app.
* Event Viewer, **Application** log, source `PhotoTagCaptcha`: challenge issued and approved, with
  the UPN. See **Logging** below for the Event IDs.
* Event Viewer, **AD FS/Admin**: load or registration errors from AD FS itself.
* The token contains the `authenticationmethod` claim `urn:phototag:captcha:poc`. On OIDC it also
  appears in `amr`.

### Update / remove

* **Same `AssemblyVersion`:** copy the new DLL and run `Install-PhotoTagCaptcha.ps1 -GacOnly` on
  each secondary, then `Install-PhotoTagCaptcha.ps1` on the primary. Each overwrites the GAC copy
  (even while AD FS has it loaded) and restarts AD FS. Verified in the lab.
* **New `AssemblyVersion` or signing key:** run `Uninstall-PhotoTagCaptcha.ps1` first. AD FS
  stores the full type name, including version and token.
* **Remove**, in this order:
  1. `Disable-PhotoTagCaptchaForApp.ps1` on the primary.
  2. `Uninstall-PhotoTagCaptcha.ps1` on the primary.
  3. On each secondary, once it has synced (`Get-AdfsSyncProperties`):
     `Uninstall-PhotoTagCaptcha.ps1 -GacOnly`.

  `lab\Test-LabRollback.ps1` runs exactly this sequence and checks both apps through both nodes
  after each step.

## Configuration

Optional. Without it, the sample photo embedded in the DLL is shown as a dialog. Pass a JSON file
at install time (`Install-PhotoTagCaptcha.ps1 -ConfigFile`), or change it later on the primary with
`Set-PhotoTagCaptchaConfig.ps1 -ConfigFile`. After a change, restart each secondary once it has
synced (`Install-PhotoTagCaptcha.ps1 -GacOnly`). Each node logs its active configuration in event
1000. Template: [`deploy/phototag-config.sample.json`](deploy/phototag-config.sample.json).

| Setting | Default | Meaning |
|---|---|---|
| `photoUrl` | empty (embedded sample) | `https://...` fetched on each sign-in (the future research image service; an optional `X-Photo-Id` response header names the photo), or `file:///C:/...` on the AD FS node. |
| `timeoutMs` | `3000` | Longest wait for the photo. Slower means the user continues **without** the captcha. |
| `maxBytes` | `2097152` | Larger photos are treated as unavailable. |
| `displayMode` | `popup` | `popup` shows a dialog over the dimmed AD FS page; `page` shows it inline. |
| `allowedApplications` | empty (guard **off**) | **The only applications the captcha may complete for.** See **Application guard**. Use the app group's Web API identifier, the RP identifier, or the `client_id` for apps that send no resource. |
| `allowUnidentified` | `false` | Guard on, and the application can't be identified from the request: `false` refuses, `true` allows. |
| `diagnostics` | `false` | Logs what AD FS passes to the adapter (event 1900). For troubleshooting. |

**Popup, not a pop-up window.** An external adapter always renders *inside* the AD FS sign-in
page. It is a step of that page, not a redirect elsewhere. "Popup" mode draws it as a CSS modal
dialog over that page. A real browser pop-up window would be stopped by pop-up blockers, needs
script, and couldn't hand the result back into the AD FS sign-in.

## Application guard

**Configure this before production.** AD FS has no per-application list of additional providers.
Once this provider is enabled farm-wide, *every* application that requires MFA can offer it. If
your farm already uses real MFA (Azure MFA, certificates, Duo...), users of those apps would see
the photo on the "choose a method" page and could click Approve instead of doing real MFA.

With `allowedApplications` set, the adapter refuses for every other application. It shows
"This verification isn't available here", issues no claim (so MFA is **not** satisfied), and
logs warning **2200**. The user goes back and picks their real MFA method. The guard runs before
anything else and **never fails open**; failing open there would be the bypass itself.

How the application is identified, from the AD FS protocol request:

| Protocol | Identifier used | Put this in `allowedApplications` |
|---|---|---|
| OAuth / OIDC (application groups) | `resource` | The app group's **Web API identifier**, the same one `Enable-PhotoTagCaptchaForApp.ps1` changed |
| WS-Federation | `wtrealm` | The relying party identifier |
| SAML 2.0 (redirect binding) | Issuer of the AuthnRequest | The relying party identifier |
| OAuth without `resource` | `client_id` (fallback only) | The client id |

The *target* is used rather than `client_id` because the access policy that required MFA belongs
to the target. A permitted client asking for a different, MFA-protected resource is refused; the
smoke tests cover it. Identifiers are compared case-insensitively, ignoring a trailing `/`. A
request with no identifier (for example SAML POST binding) is refused unless
`allowUnidentified` is `true`.

The adapter can't hide itself from other apps' "choose a method" page. In the lab (diagnostics,
event 1900), AD FS 2019 passed `IsAvailableForUser` no request and an **empty**
`IAuthenticationContext.Data`. Nothing there identifies the application, so the refusal has to
happen after a user picks the photo. `BeginAuthentication` does get the full protocol URL,
including `resource` and `client_id`, which is what the guard uses. With the guard off, event
**2101** is logged at every start as a reminder.

Verified on the lab farm, through both nodes (`lab\Test-LabGuard.ps1`):

| Scenario | Research Portal (allowed) | Control App made to require MFA |
|---|---|---|
| Guard off | Photo | **Photo: one click satisfies MFA (the bypass)** |
| Guard on | Photo | Refused, no claim, event 2200 |
| Guard on, photo unavailable | Let through without captcha (fail-open) | Still refused |

## Fail-open

The captcha must never lock a user out of an **allowed** application. In each of these cases the user sees a brief
"Continuing..." page that submits itself, and is then signed in without the captcha:

* the photo source is unreachable, slower than `timeoutMs`, returns an HTTP error, a non-image or
  an empty body, or the photo is larger than `maxBytes`;
* the configuration can't be read;
* any unexpected error inside the adapter, while showing the photo or while completing.

AD FS gives an adapter no way to finish directly from `BeginAuthentication`, hence the one
self-submitting page. Its button stays visible in case scripts are blocked. The inline script is
allowed by the AD FS 2019 default policy `default-src 'self' 'unsafe-inline' 'unsafe-eval'`. The
decision to skip is stored server-side in AD FS's protected context, so a client can't trigger a
skip by posting the form itself; the smoke tests cover this.

Limits:
* If AD FS can't **load** the DLL at all (for example it's missing from one node's GAC), the adapter
  code never runs and can't fail open. Use `Disable-PhotoTagCaptchaForApp.ps1`.
* A skipped user's token carries the same `urn:phototag:captcha:poc` claim as an approved one. The
  event log (2000 + 1200) is the record of the skip. If the application needs to tell the two
  apart, add a second authentication method value; that requires re-registering the provider.

## Logging

Windows **Application** event log, source **`PhotoTagCaptcha`**, on every AD FS node. This was
chosen over a log file: the AD FS service account can write it without extra folder permissions,
there's no rotation to manage, and Windows Event Forwarding or a SIEM can collect it from all
nodes. The install script creates the event source.

| Event ID | Level | Meaning |
|---|---|---|
| 1000 | Information | Adapter loaded: version, file version, active configuration |
| 1001 | Information | Adapter unloaded |
| 1100 | Information | Photo shown: challenge id, UPN, photo id |
| 1101 | Information | Approved: challenge id, UPN, photo id |
| 1102 | Information | Stale or replayed page, new photo shown |
| 1200 | Information | User completed sign-in **without** the captcha (after a 2000/2001) |
| **2000** | **Warning** | **Photo unavailable, user let through without the captcha** (reason included) |
| 2001 | Warning | Unexpected error while preparing the captcha, user let through |
| 2100 | Warning | Configuration unreadable; all users let through until fixed |
| 2101 | Warning | Guard off (no `allowedApplications`): any app requiring MFA can use the captcha |
| **2200** | **Warning** | **Guard refused: an application not in `allowedApplications` reached the captcha**; no claim issued |
| 1900 | Information | Diagnostics (only with `"diagnostics": true`) |
| 3000 | Error | AD FS reported an error around this step |
| 3001 | Error | Unexpected error while completing, user let through |

```powershell
# Everyone who skipped the captcha in the last day, on this node:
Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='PhotoTagCaptcha'; Id=2000,2001,3001; StartTime=(Get-Date).AddDays(-1) }
```

## Adapter internals

* **`PhotoTagMetadata`** sets `RequiresIdentity = true` (it is an MFA-stage provider and receives the
  UPN), declares one auth method URI, and English (1033) strings.
* **`PhotoTagAdapter`**:
  * AD FS keeps one shared instance, so per-request state goes in `IAuthenticationContext.Data`.
    AD FS round-trips that data, tamper-protected, in the `Context` form field.
  * A per-page `ChallengeId` is stored there and must come back with the post. Stale or replayed
    pages get a fresh challenge instead of a claim.
  * Fail-open decisions are stored there too (see **Fail-open**).
* **`PhotoStore`** gets the photo from the embedded resource, an http(s) URL or a file. It never
  throws; failures come back as a reason.
* **`PhotoTagPresentation`**:
  * Forms post `AuthMethod` and `Context` back to the **current** AD FS URL, with no `action`
    attribute; AD FS fills those two placeholders. AD FS 2019 does **not** substitute a
    `%PageActionUrl%` placeholder. Using one broke Approve in the lab (MSIS7065).
  * The photo is a `data:` URI, allowed by the default `img-src 'self' data:`, so no extra web
    content is hosted on AD FS. The challenge page has no script; the fail-open page has one line.
* **`Log`** writes Event IDs to the Application event log. It never throws into the sign-in path.

## Lab: AD FS 2019 farm on Hyper-V

`lab\` builds a disposable test farm on this PC and runs the same production scripts against it.

| VM | Role | IP |
|---|---|---|
| LAB-DC01 | Domain controller, `adfslab.test` | 192.168.77.10 |
| LAB-ADFS01 | AD FS 2019 primary, `adfs.adfslab.test` | 192.168.77.11 |
| LAB-ADFS02 | AD FS 2019 secondary (WID farm) | 192.168.77.12 |

Two application groups (OIDC server app + Web API) back the test app running on this PC:

* **Research Portal**, https://localhost:44301: the captcha is scoped here.
* **Control App**, https://localhost:44302: never scoped; proves other apps are unaffected.

| Script | What it does |
|---|---|
| `Prepare-Host.ps1` | Once, elevated: Hyper-V Administrators membership, `AdfsLab` switch + NAT, hosts entry. Then sign out and back in. |
| `Build-Lab.ps1` | Creates the three VMs from the Server 2019 eval VHD and builds the domain, farm and app groups. Can be re-run. |
| `Start-TestApps.ps1` | Starts both test apps on this PC. |
| `Deploy-LabAdapter.ps1` | Builds against the lab's real AD FS DLL and deploys with the production scripts in the verified order. |
| `SignInTest\` | Scripted sign-in (`dotnet run -- --app Research --expect captcha [--node 192.168.77.12]`). |
| `Test-LabGuard.ps1` | Shows the MFA-bypass risk (another app requiring MFA gets the photo), then the guard refusing it while Research still works, on both nodes. |
| `Test-LabFailOpen.ps1` | Points the adapter at a photo file, then deletes and restores it: photo, skip (event 2000), photo again, on both nodes. |
| `Test-LabRollback.ps1` | Disable + uninstall with the production scripts, then checks both apps on both nodes. |
| `Get-LabScreens.ps1` | Saves console screenshots of the VMs. |
| `Remove-LabHost.ps1` | Elevated: deletes the VMs and undoes `Prepare-Host.ps1`. |

The Hyper-V checkpoint **"Baseline - farm built, no adapter"** on all three VMs returns the lab
to a clean farm. Generated passwords and client secrets are in `lab\lab-credentials.json`, which
is gitignored.

## Next: the iframe captcha

1. **Allow the frame.** AD FS sends a Content-Security-Policy header. Add your captcha origin to it,
   for example:

   ```powershell
   Set-AdfsResponseHeaders -SetHeaderName 'Content-Security-Policy' -SetHeaderValue "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; frame-src https://captcha.research.contoso.com"
   ```

   Read the current value with `Get-AdfsResponseHeaders` first and extend it rather than replacing
   it. Also, your captcha service must not send `X-Frame-Options: DENY`.
2. **Render the iframe** in `PhotoTagPresentation.GetFormHtml`. Have the iframe `postMessage` a
   result token to the page, and have a small inline script put it in a hidden field and submit
   the form.
3. **Verify the result on the server, in `TryEndAuthentication`.** Validate that token against the
   captcha service, or check its signature, before returning the claim. Bind it to `ChallengeId` and
   the UPN. Never trust the browser's word that tagging happened.
4. **Configure without rebuilding.** Put the service URL and keys in a JSON file and pass it with
   `Register-AdfsAuthenticationProvider -ConfigurationFilePath`; read it in
   `OnAuthenticationPipelineLoad(configData)`. To change it later, use
   `Import-AdfsAuthenticationProviderConfigurationData`.
5. **Prefer a dedicated policy.** Use a custom access control policy (for example "Permit
   researchers and require MFA") so the captcha is shown only to the people who should tag.
