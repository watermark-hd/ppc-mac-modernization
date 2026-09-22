# AquaLink (iBook/PowerMac NAS share) connection setup
# Registry/hosts changes that need admin rights are auto-elevated;
# the actual "net use" drive mapping is run WITHOUT admin rights on purpose
# (a drive mapped from an elevated session is invisible in normal Explorer).
#
# This script prompts for your server's details interactively - nothing to
# edit in the file itself. The prompts are in English to avoid a known
# Windows PowerShell 5.1 bug where non-ASCII characters in a script file
# (without a UTF-8 BOM) cause parse errors; the VALUES you type in response
# (server name, share name, etc.) can be in any language.

$ErrorActionPreference = "Stop"

function Read-RequiredHost {
    param($Prompt)
    $value = Read-Host $Prompt
    while ([string]::IsNullOrWhiteSpace($value)) {
        $value = Read-Host "$Prompt (required)"
    }
    return $value
}

function Test-RegistryValue {
    param($Path, $Name, $Expected)
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($val -eq $Expected)
}

Write-Host "=== AquaLink connection setup ===" -ForegroundColor Cyan
Write-Host "Enter the details of the AquaLink share you want to connect to."
Write-Host ""

$ServerIP = Read-RequiredHost "Server IP address (e.g. 192.168.1.5)"
$ServerName = Read-RequiredHost "A short local name for this server (e.g. aqualink-nas)"
$ServerPortInput = Read-Host "Server port shown in AquaLink's Share Settings (press Enter for the default, 8091)"
$ServerPort = if ([string]::IsNullOrWhiteSpace($ServerPortInput)) { "8091" } else { $ServerPortInput }
$ShareName = Read-RequiredHost "Share name on the server (e.g. Pictures)"
$ShareUser = Read-RequiredHost "Username"
$SecurePassword = Read-Host "Password" -AsSecureString
$SharePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword))
$DriveLetter = "Z:"

Write-Host ""

# 1. WebClient Basic auth settings (allow Basic auth over plain HTTP)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters"
$authForwardList = (Get-ItemProperty -Path $regPath -Name "AuthForwardServerList" -ErrorAction SilentlyContinue).AuthForwardServerList
$hasWildcardForward = ($null -ne $authForwardList) -and ($authForwardList -contains "*")
$needReg = -not ((Test-RegistryValue $regPath "BasicAuthLevel" 2) -and (Test-RegistryValue $regPath "UseBasicAuth" 1) -and $hasWildcardForward)

if ($needReg) {
    Write-Host "First-time setup: registry change needed (an admin approval popup will appear)..." -ForegroundColor Yellow
    # AuthForwardServerList: WebClient refuses to send Basic auth credentials to any
    # server unless it's on this allow-list. AquaLink normally listens on a non-standard
    # port (8091 by default, not 80), and WebClient's default behavior otherwise blocks
    # exactly that case with a generic "not authenticated" error (system error 1244) --
    # this bit it in real-world testing (2026-09-22) before this fix was added.
    $regCmd = "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`" /v BasicAuthLevel /t REG_DWORD /d 2 /f; " +
              "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`" /v UseBasicAuth /t REG_DWORD /d 1 /f; " +
              "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`" /v AuthForwardServerList /t REG_MULTI_SZ /d `"*`" /f; " +
              "net stop webclient; net start webclient"
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"$regCmd`""
} else {
    Write-Host "Registry: already OK" -ForegroundColor Green
}

# 2. Register server name in hosts file (a raw IP address is unreliable for this)
#
# [2026-09-22] Real-world testing found two bugs in the original version of
# this step: (a) it used Select-String on $ServerName directly, which does a
# SUBSTRING match -- entering "aqualink" was treated as "already present"
# just because an unrelated earlier entry like "aqualink-nas" contains it as
# a substring, so the real entry never got added and name resolution simply
# failed; (b) even an exact-name match was accepted as-is without checking
# whether the IP was still correct, so a stale entry from a previous session
# (the Mac's IP can change) silently kept pointing at the wrong address.
# Fixed by comparing the exact hostname token (not a substring) against both
# name AND current IP, and rewriting via a temp elevated script file instead
# of a nested -Command string (much less fragile than trying to escape a
# regex through two layers of quoting).
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsLines = Get-Content -Path $hostsPath -ErrorAction SilentlyContinue
$hostsIsCorrect = $false
foreach ($line in $hostsLines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
    $parts = $trimmed -split '\s+'
    if ($parts.Count -ge 2 -and $parts[0] -eq $ServerIP -and $parts[1] -eq $ServerName) {
        $hostsIsCorrect = $true
        break
    }
}

if (-not $hostsIsCorrect) {
    Write-Host "First-time setup: hosts file entry needed (an admin approval popup will appear)..." -ForegroundColor Yellow
    $tempScript = Join-Path $env:TEMP "aqualink-hosts-fix.ps1"
    @"
`$lines = Get-Content -Path '$hostsPath'
`$kept = foreach (`$line in `$lines) {
    `$t = `$line.Trim()
    if (`$t -eq '' -or `$t.StartsWith('#')) { `$line; continue }
    `$parts = `$t -split '\s+'
    if (`$parts.Count -ge 2 -and `$parts[1] -eq '$ServerName') { continue }
    `$line
}
`$kept += "$ServerIP`t$ServerName"
Set-Content -Path '$hostsPath' -Value `$kept -Encoding ASCII
"@ | Set-Content -Path $tempScript -Encoding UTF8
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    Remove-Item -Path $tempScript -ErrorAction SilentlyContinue
} else {
    Write-Host "hosts entry: already OK" -ForegroundColor Green
}

# 3. Remove any stale mapping, then map the drive WITHOUT admin rights
Write-Host "Connecting network drive..." -ForegroundColor Cyan
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
net use $DriveLetter /delete /y 2>$null | Out-Null
$ErrorActionPreference = $prevEAP
# A plain "\\server\DavWWWRoot\share" UNC path always means port 80 to
# WebClient. To reach AquaLink's non-standard port, the server name needs
# the "@port" suffix (a long-standing WebClient/WebDAV-redirector
# convention) -- otherwise this fails with "network path not found"
# (system error 67), which was hit in real-world testing (2026-09-22)
# right after the AuthForwardServerList fix above got past the previous
# (auth-related) failure.
$netUseResult = net use $DriveLetter "\\$ServerName@$ServerPort\DavWWWRoot\$ShareName" $SharePassword "/USER:$ShareUser" /PERSISTENT:YES

if ($LASTEXITCODE -eq 0) {
    Write-Host "Connected! $DriveLetter should now appear under This PC in File Explorer." -ForegroundColor Green
} else {
    Write-Host "Connection failed. Output: $netUseResult" -ForegroundColor Red
}
