# Runbook: "I need to..."

Short answers with the exact commands. Production commands run in an **elevated Windows
PowerShell on the AD FS server**, from the folder where `dist\` was copied (e.g.
`C:\PhotoTagCaptcha`). "Primary" = the WID primary (for SQL farms, any one node).

## Build and code

| I need to... | Do this |
|---|---|
| Build and test | `.\build.ps1` |
| Build on a fresh clone | Restore `keys\PhotoTagCaptcha.snk` first (not in git). Without it `build.ps1` creates a new key and the DLL won't match the registered provider. |
| Compile against the real AD FS assembly | Copy `C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll` from an AD FS server to `lib\`, run `.\build.ps1` (also verifies the stub). Never commit it. |
| See what the page looks like | `.\build.ps1`, open `out\preview.html` (photo), `out\preview-skip.html` (fail-open), `out\preview-error.html`. |
| Release a new build | Bump `FileVersion` in the adapter csproj, keep `AssemblyVersion` 1.0.0.0, `.\build.ps1`, verify in the lab, give `dist\` to the operator. |
| Change `AssemblyVersion` or the signing key | Breaking: uninstall everywhere first (README "Update / remove"), then install fresh. Avoid. |

## Production farm

| I need to... | Do this |
|---|---|
| Install | README "Deploy", steps 1-5, in order. Secondaries `-GacOnly` first; primary `Install-PhotoTagCaptcha.ps1 -ConfigFile .\phototag-config.json`; each secondary `-GacOnly` again **after** its sync. |
| Turn it on for one app | Primary: `.\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier '<group>'` (or `-RelyingPartyName`). Then `.\Get-PhotoTagCaptchaScope.ps1`. |
| Make sure no other app can use it | Put the app's Web API identifier (or RP identifier / client_id) in `allowedApplications`, apply with `Set-PhotoTagCaptchaConfig.ps1`. Event 2101 at startup means the guard is off. |
| Turn it off for the app (fast rollback) | Primary: `.\Disable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier '<group>'`. Restores the saved policy; secondaries follow within 5 min. No restart. |
| Remove completely | Disable (above) -> primary `.\Uninstall-PhotoTagCaptcha.ps1` -> each secondary, after sync, `.\Uninstall-PhotoTagCaptcha.ps1 -GacOnly`. |
| Change the photo source / timeout / display / guard | Edit the JSON, primary `.\Set-PhotoTagCaptchaConfig.ps1 -ConfigFile .\phototag-config.json`, then on each secondary after sync `.\Install-PhotoTagCaptcha.ps1 -GacOnly`. Check event 1000 on every node shows the new config. |
| Update the DLL (same AssemblyVersion) | Copy new `dist\`; secondaries `.\Install-PhotoTagCaptcha.ps1 -GacOnly`; primary `.\Install-PhotoTagCaptcha.ps1`. One node at a time, drained. |
| Know whether a secondary has synced | `Get-AdfsSyncProperties` -> `LastSyncTime` later than the change on the primary. |
| See who skipped the captcha | `Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='PhotoTagCaptcha'; Id=2000,2001,3001; StartTime=(Get-Date).AddDays(-1)}` on every node. |
| See which apps would show the captcha | Primary: `.\Get-PhotoTagCaptchaScope.ps1`. Exactly one app should be listed. |
| Troubleshoot what AD FS passes the adapter | Set `"diagnostics": true`, apply, reproduce, read event 1900, set it back to false. |

## Lab

| I need to... | Do this |
|---|---|
| Know which server and credentials | AD FS: https://adfs.adfslab.test (LAB-ADFS01 .11 primary, LAB-ADFS02 .12). Users `alice@adfslab.test`, `bob@adfslab.test`; domain admin `ADFSLAB\Administrator`. Passwords are in `lab\lab-credentials.json` (`UserPassword`, `AdminPassword`). |
| Get a password without showing it | `(Get-Content lab\lab-credentials.json \| ConvertFrom-Json).UserPassword \| Set-Clipboard`, then Ctrl+V in the password field. Check the keyboard is not on Hebrew. |
| Sign in by hand | Start apps if needed (`.\lab\Start-TestApps.ps1`), browse https://localhost:44301 (Research, captcha) or https://localhost:44302 (Control, no captcha). |
| Run a scripted sign-in | `dotnet run --project lab\SignInTest -- --app Research --expect captcha [--node 192.168.77.12]`. Expect values: `captcha`, `none`, `skip`, `blocked`. |
| Open a shell on a VM | `. .\lab\LabConfig.ps1; Enter-PSSession -VMName LAB-ADFS01 -Credential (Get-LabCredential)` (or Hyper-V Manager -> Connect). |
| Deploy my build to the lab | `.\lab\Deploy-LabAdapter.ps1` (5-12 min). |
| Prove fail-open / guard / rollback | `.\lab\Test-LabFailOpen.ps1`, `.\lab\Test-LabGuard.ps1`, `.\lab\Test-LabRollback.ps1`. |
| Start over with a clean farm | Restore checkpoint "Baseline - farm built, no adapter" on **all three** VMs (DC included). Removes the adapter and config. |
| Rebuild the lab from scratch | `.\lab\Build-Lab.ps1` (re-runnable; phases `Vms, DC, Adfs01, Adfs02, Apps`). |
| Delete the lab | Elevated: `.\lab\Remove-LabHost.ps1` (VMs, switch, NAT, hosts entry). |
| See VM consoles without logging in | `.\lab\Get-LabScreens.ps1` -> `lab\logs\screens\`. |

## Next feature: the iframe captcha

Follow README "Next: the iframe captcha". In short: extend (don't replace) the AD FS CSP with
`frame-src <captcha origin>`; render the iframe in `PhotoTagPresentation`; have it `postMessage` a
result token into a hidden field; **verify that token server-side in `TryEndAuthentication`**,
bound to `ChallengeId` and the UPN; keep the guard and fail-open behavior. Prove it in the lab
before any production change; CSP changes are farm-wide, so treat them like a deploy.

## When to stop and ask

- `keys\PhotoTagCaptcha.snk` is missing.
- A step would change anything global on AD FS other than the provider list (global policy,
  CSP/response headers, other apps' policies, other providers).
- `Enable-PhotoTagCaptchaForApp.ps1` refuses because the app has a custom policy: the operator must
  create an MFA copy of that policy and pass `-AccessControlPolicyName`.
- Anything would run against a non-lab AD FS server.
