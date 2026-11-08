# How to work on PhotoTagCaptcha

The loop for every change: **edit -> build + smoke tests -> lab deploy -> lab tests on both nodes
-> docs -> commit**. The lab exists so nothing is ever tried first on the production farm.

## 0. One-time setup (new machine / fresh clone)

1. Install the .NET 8 SDK: `winget install Microsoft.DotNet.SDK.8` (or the per-user
   `dotnet-install.ps1`; `build.ps1` also finds `%LOCALAPPDATA%\Microsoft\dotnet`).
2. **Put the signing key back:** copy the original `PhotoTagCaptcha.snk` to `keys\`. It is not in
   git. Do **not** run `build.ps1` without it: the script would generate a new key, the DLL's
   public key token would change, and AD FS (which registered the old token) would not load it.
   Only for a brand-new installation that has never been registered anywhere is a new key fine.
3. Optional but recommended: copy `C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll` from an AD FS
   2019 server (or let `lab\Deploy-LabAdapter.ps1` fetch it from the lab) into `lib\`. Never commit it.
4. For the lab: Windows 11 Pro/Enterprise with Hyper-V, ~12 GB free RAM, ~60 GB disk. Run
   `lab\Prepare-Host.ps1` elevated once, sign out and back in, then `lab\Build-Lab.ps1`.
   See README "Lab".

## 1. Edit

- Adapter code: `src/PhotoTagCaptcha.Adapter/`. Read README "Adapter internals" first and keep the
  invariants in `CLAUDE.md` (never throw into AD FS, guard never fails open, fail-open for the
  allowed app).
- Deploy scripts: `deploy/`. They must run on Windows PowerShell 5.1 on Server 2019.
- With Claude Code, delegate: `adapter-developer` for C#, `deploy-script-reviewer` to review
  script changes, `lab-operator` for lab runs, `adfs-troubleshooter` for "why does X happen".

## 2. Build and smoke-test locally

```powershell
.\build.ps1
```

Must end with all harness checks passing and `Staged to ...\dist`. Add a harness check
(`tools/PreviewHarness/Program.cs`) for every behavior you change, including its failure path.
Open `out\preview.html` (and `preview-skip.html`, `preview-error.html`) to eyeball the HTML.

If `lib\Microsoft.IdentityServer.Web.dll` exists, the build also compiles against it and compares
the stub; a mismatch fails the build. That is intentional: a mismatched stub compiles but fails
when AD FS loads the adapter.

## 3. Deploy to the lab

```powershell
.\lab\Deploy-LabAdapter.ps1                 # real-DLL build + production-order deploy + scope Research
```

It runs the same `deploy\` scripts in the same order as production: secondary `-GacOnly`, primary
install, wait for the secondary's sync, secondary `-GacOnly` again, then scope to ResearchPortal.
Takes 5-12 minutes because of the WID sync.

Config-only change in the lab: on LAB-ADFS01 `C:\PhotoTagCaptcha\Set-PhotoTagCaptchaConfig.ps1
-ConfigFile ...`, wait for LAB-ADFS02's `Get-AdfsSyncProperties`, then
`Install-PhotoTagCaptcha.ps1 -GacOnly` on LAB-ADFS02.

## 4. Test in the lab (both nodes)

| What changed | Run |
|---|---|
| Anything | `dotnet run --project lab\SignInTest -- --app Research --expect captcha` and `--app Control --expect none`, each with and without `--node 192.168.77.12` |
| Photo loading / fail-open | `lab\Test-LabFailOpen.ps1` |
| Guard / app identification | `lab\Test-LabGuard.ps1` (expects guard off at start; leaves it on) |
| Install / uninstall / Enable / Disable scripts | `lab\Test-LabRollback.ps1`, then re-deploy |
| HTML / popup look | Browser: https://localhost:44301 as `alice@adfslab.test` (password via clipboard, see below) |

Check events afterwards on both nodes: Application log, source `PhotoTagCaptcha`; AD FS/Admin
errors should be 0 apart from the transient 344/345/543 on the secondary.

Lab password to the clipboard (never display it):

```powershell
(Get-Content lab\lab-credentials.json | ConvertFrom-Json).UserPassword | Set-Clipboard
```

Leave the lab in the standard state afterwards (guard on for Research, photo file present, popup,
diagnostics off, Control on "Permit everyone"). `Get-PhotoTagCaptchaScope.ps1` on LAB-ADFS01
should list only Research Portal.

## 5. Document

- README: behavior, config table, Event ID table, deploy steps.
- `docs/RUNBOOK.md` / `docs/TROUBLESHOOTING.md` if you learned a new "if X then Y".
- `CLAUDE.md` "Known gotchas" if something bit you.

## 6. Commit

```powershell
git status
git diff --cached --stat     # no lab-credentials.json, no *.snk, no lib\*.dll, no dist\
git commit -m "..."
git push
```

Releases: bump `FileVersion` in `src/PhotoTagCaptcha.Adapter/PhotoTagCaptcha.Adapter.csproj`; keep
`AssemblyVersion` at 1.0.0.0 so the production registration stays valid.

## Handing a build to production

The user deploys to production themselves. Give them `dist\` (DLL + scripts + sample config) and
point them at README "Deploy". Production is AD FS on Windows Server 2019; the same order as the
lab applies, with each secondary drained at the load balancer before its restart.
