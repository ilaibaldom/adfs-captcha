# Troubleshooting

Start with the logs on **every** AD FS node; a load balancer can send each request to a different
node:

```powershell
Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='PhotoTagCaptcha'; StartTime=(Get-Date).AddHours(-1) } | Format-List TimeCreated, Id, LevelDisplayName, Message
Get-WinEvent -FilterHashtable @{ LogName='AD FS/Admin'; Level=2,3; StartTime=(Get-Date).AddHours(-1) } | Format-List TimeCreated, Id, Message
```

The adapter runs only **after** the password step succeeds and only for apps whose policy requires
MFA. Use that to decide which layer a problem is in.

## Symptoms

| Symptom | Likely cause | Check / fix |
|---|---|---|
| "Incorrect user ID or password" (Hebrew: "מזהה משתמש או סיסמה שגויים") | Not the adapter; the password step failed. Usually the wrong value was typed: a field name instead of the value, Hebrew keyboard layout, or extra quotes from copying out of JSON. | DC: `Get-ADUser alice -Properties LockedOut,badPwdCount,LastBadPasswordAttempt`. Lab: `dotnet run --project lab\SignInTest -- --app Control --expect none` proves the account works. Paste the password from the clipboard (RUNBOOK). |
| App signs in without any photo | App's policy doesn't require MFA, the node hasn't loaded the provider, or fail-open happened. | `Get-PhotoTagCaptchaScope.ps1` lists the app? Event 1000 since the last restart on that node? Events 2000/1200 = fail-open (reason in 2000). |
| Photo shows through the primary but not the secondary (or the reverse) | Secondary hasn't synced, or was restarted before its sync. | `Get-AdfsSyncProperties` on the secondary; then `Install-PhotoTagCaptcha.ps1 -GacOnly` there. Policy changes take up to 5 min to reach secondaries. |
| Everyone skips the captcha | Config unreadable (event 2100), photo source down or slow (2000 with reason), or an exception (2001/3001). | Fix the JSON (event 1000 shows the active config) or the photo source; raise `timeoutMs` only if the source is legitimately slow. |
| Another app now shows the photo / "choose a method" lists it | That app also requires MFA and the guard is off (event 2101 at startup). | Set `allowedApplications` to the scoped app's identifier, apply with `Set-PhotoTagCaptchaConfig.ps1`. The other app will then get event 2200 and "This verification isn't available here". |
| "This verification isn't available here" on the app that should have the captcha | Guard refused: the identifier in `allowedApplications` doesn't match what the request carries. | Event 2200 shows the identifier seen (`resource`/`wtrealm`/SAML issuer/`client_id`). Put exactly that in `allowedApplications` (case and trailing `/` are ignored). For SAML POST binding, nothing identifies the app: consider `allowUnidentified` carefully. |
| Approve does nothing / MSIS7065 | Form posted to the wrong URL. | Forms must have no `action` attribute; AD FS 2019 doesn't substitute `%PageActionUrl%`. |
| Approve shows a new photo instead of signing in | Stale or replayed page (event 1102): back button, two tabs, or a page left open across an AD FS restart. | Expected. Approve the new photo. |
| "Choose a method" page instead of going straight to the photo | Other additional providers are enabled (Azure MFA, certificate...). | Expected with several providers. Users pick "Help research: review a photo". |
| Provider doesn't load on a node (no event 1000, AD FS/Admin errors about the type) | DLL not in that node's GAC, different public key token, or stub mismatch. | `Get-ChildItem $env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\PhotoTagCaptcha.Adapter -Recurse`. Rebuild against the real DLL (`lib\`) so `Compare-AdfsStub.ps1` runs. Check `keys\PhotoTagCaptcha.snk` wasn't regenerated. Immediate relief: `Disable-PhotoTagCaptchaForApp.ps1`. |
| PS0033 running a script | Management cmdlet on a WID secondary. | Run registration/config/scope scripts on the primary; secondaries only take `-GacOnly`. |
| AD FS/Admin 344, 345, 543 on a secondary | Its sync coincided with the primary restarting. | Transient; the next sync succeeds. |
| Event source missing / nothing logged | Install didn't create the source (not elevated). | Re-run `Install-PhotoTagCaptcha.ps1 -GacOnly` elevated on that node. |

## Lab-only problems

| Symptom | Fix |
|---|---|
| Hyper-V cmdlets: access denied / no VMs visible | Your Windows session predates Hyper-V Administrators membership: sign out and back in (`lab\Prepare-Host.ps1` adds it). |
| Test app: connection refused on 44301/44302 | The apps stopped with the session that started them: `.\lab\Start-TestApps.ps1` (lab tests do this automatically). |
| Browser certificate warnings | The AD FS certificate is self-signed and intentionally not trusted on the host. Proceed past the warning for `adfs.adfslab.test` only, or trust that certificate yourself if you choose. |
| AD cmdlets fail on the DC (ADWS stopped/disabled) | `.\lab\Build-Lab.ps1 -Phase DC` re-enables and starts ADWS. |
| DNS zone `adfslab.test` missing after a hard reset of the DC | Restore the baseline checkpoint on all three VMs (simplest), or recreate the AD-integrated zone on LAB-DC01 and re-run `-Phase DC` for the records. Always reboot VMs gracefully. |
| Secondary never syncs | Primary `adfssrv` running? `Get-AdfsSyncProperties` on the secondary shows `PrimaryComputerName`, `LastSyncStatus` and `LastSyncTime`. Restart `adfssrv` on the secondary. |

## Event IDs (summary)

1000 loaded (config) - 1001 unloaded - 1100 photo shown - 1101 approved - 1102 stale page -
1200 signed in without captcha - 1900 diagnostics - **2000 photo unavailable, let through** -
2001 error preparing, let through - 2100 bad config - 2101 guard off - **2200 guard refused** -
3000 AD FS error - 3001 error completing, let through. Details: README "Logging".
