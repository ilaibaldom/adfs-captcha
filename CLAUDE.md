# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this is

**PhotoTagCaptcha**: an AD FS 2019 custom authentication adapter (`IAuthenticationAdapter`) that,
after normal sign-in, shows a photo with an **Approve** button for **one application group only**.
It is the POC for a future iframe captcha in which users tag photos for the data science team.

Three non-negotiable behaviors:

1. **Scoped to one app.** Scope comes from that app's access policy requiring MFA, plus the
   in-adapter **application guard** (`allowedApplications`). The guard must **never fail open**;
   failing open there turns the captcha into an MFA bypass for other apps.
2. **Fail-open for the allowed app.** If the photo or configuration is unavailable, or anything
   unexpected throws, the user is let through without the captcha and an event is logged. The
   captcha must never lock anyone out of the allowed app.
3. **Never harm the farm.** The adapter runs inside `adfssrv`. It must never throw into the AD FS
   pipeline, never block for long (`timeoutMs`), and never change global AD FS behavior.

Full design and operator documentation: [README.md](README.md).
How to work here: [docs/WORKFLOW.md](docs/WORKFLOW.md). "I need to X": [docs/RUNBOOK.md](docs/RUNBOOK.md).
Symptoms and Event IDs: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Layout

| Path | What |
|---|---|
| `src/PhotoTagCaptcha.Adapter/` | The adapter (net472, strong-named with `keys/PhotoTagCaptcha.snk`). |
| `src/Microsoft.IdentityServer.Web.Stub/` | Compile-time stand-in for the AD FS assembly. Must match the real one exactly. **Never deploy.** |
| `tools/PreviewHarness/` | net8 smoke tests that drive the adapter as AD FS does; writes `out/preview*.html`. |
| `tools/Compare-AdfsStub.ps1` | Reflection diff, stub vs real `Microsoft.IdentityServer.Web.dll`. |
| `deploy/` | Production PowerShell: install, configure, scope, report, disable, uninstall. |
| `lab/` | Hyper-V AD FS 2019 farm (DC + 2 AD FS nodes), test apps, scripted sign-in tests. |
| `build.ps1` | Build, verify identity, compare stub (if real DLL present), run harness, stage `dist/`. |
| `.claude/agents/` | Sub-agents for this repo (see below). |

## Commands

```powershell
.\build.ps1                     # build + verify + smoke tests + stage dist\   (always run before committing)
.\build.ps1 -SkipTests          # build only
dotnet run --project tools\PreviewHarness -- out   # harness only (after a build)
```

`dotnet` may be the per-user install at `%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe`; `build.ps1`
finds it. Lab scripts (`lab\*.ps1`) need Hyper-V Administrators membership and take minutes: run
them in the background and read the output when they finish.

## Hard rules

- **Secrets never leave their files.** `lab/lab-credentials.json` (lab passwords, client secrets)
  and `keys/PhotoTagCaptcha.snk` (signing private key) are gitignored. Never print their values,
  never commit them, never paste them into chat, docs, logs or commit messages. To hand a password
  to the user: `(Get-Content lab\lab-credentials.json | ConvertFrom-Json).UserPassword | Set-Clipboard`.
- **Never commit `lib/Microsoft.IdentityServer.Web.dll`** (Microsoft's binary, not redistributable).
- **Missing `keys/PhotoTagCaptcha.snk`? Stop.** `build.ps1` will silently generate a *new* key,
  which changes the public key token; the DLL then no longer matches what AD FS has registered.
  Ask the user for the original key instead of building.
- **Never touch production AD FS.** All testing happens in the lab. Production is Windows Server
  2019 AD FS; the user deploys there themselves, following README "Deploy".
- **Don't change the user's machine settings** (certificate stores, trust, system/security
  settings) without explicit consent. Ask before downloading anything.
- **The adapter must not throw into AD FS.** Every interface method catches, logs and degrades
  (fail-open for allowed apps, refuse for guarded ones). `Log` never throws.
- **Stub changes must match the real assembly.** Run `build.ps1` with the real DLL in `lib\`
  (`lab\Deploy-LabAdapter.ps1` fetches it) so `Compare-AdfsStub.ps1` checks it.
- **Keep `AssemblyVersion` at 1.0.0.0** unless a breaking re-registration is intended. AD FS stores
  the full type name; bump `FileVersion` for normal updates.
- **Edit text files with the Edit/Write tools** (UTF-8), keep diagrams in README ASCII. Windows
  PowerShell `Get-Content`/`Set-Content` without `-Encoding` has corrupted files here before (mojibake).
- Commit or push only when the user asks. Remote: `https://github.com/ilaibaldom/adfs-captcha`.

## Known AD FS / PowerShell gotchas (all learned the hard way)

- AD FS 2019 substitutes only `%AuthMethod%` and `%Context%` in adapter HTML. `%PageActionUrl%` is
  **not** substituted; forms have no `action` attribute (posting to it gave MSIS7065).
- `IsAvailableForUser` gets no request and empty context data; only `BeginAuthentication` gets the
  protocol URL. The guard therefore runs in `BeginAuthentication`.
- WID farm: secondaries pull config every 5 minutes. A secondary restarted **before** its sync does
  not load a new provider/config. Management cmdlets on a secondary fail with PS0033. Events
  344/345/543 on a secondary during a primary restart are transient.
- Windows PowerShell 5.1 leaves `$PSScriptRoot` empty inside `param()` defaults; resolve defaults in
  the script body.
- `Set-Content -Encoding UTF8` (5.1) writes a BOM. The config parser handles it; keep that test.
- `powershell -File` cannot pass arrays; use `-Command` when an argument is an array.
- The lab test apps die with the session that started them; lab tests call `Assert-LabTestApps`.
- Harness (net8): pass `(Uri)null` to avoid ambiguous overloads; `EventLog` calls sit in a
  non-inlined method so a missing EventLog API never breaks a caller.

## Sub-agents (`.claude/agents/`)

| Agent | Use it for |
|---|---|
| `adapter-developer` | Changing adapter C# (`src/`), the stub, or the harness; keeps tests green. |
| `deploy-script-reviewer` | Read-only review of `deploy/*.ps1` changes for production-farm safety. |
| `lab-operator` | Running lab scripts and sign-in tests, deploying to the lab, reading lab event logs. |
| `adfs-troubleshooter` | Diagnosing a symptom (sign-in error, photo missing, wrong app gets captcha) from events. |

## Definition of done for a change

1. `.\build.ps1` passes (all harness checks green; stub comparison passes when `lib\` has the real DLL).
2. Behavior changes that affect AD FS are verified in the lab (`lab\Deploy-LabAdapter.ps1`, then
   the relevant `lab\Test-Lab*.ps1`) on **both** nodes.
3. README (and the Event ID table, if events changed) is updated.
4. No secret, key or Microsoft binary is staged (`git status`, `git diff --cached`).
