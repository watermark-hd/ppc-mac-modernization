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
$ShareName = Read-RequiredHost "Share name on the server (e.g. Pictures)"
$ShareUser = Read-RequiredHost "Username"
$SecurePassword = Read-Host "Password" -AsSecureString
$SharePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword))
$DriveLetter = "Z:"

Write-Host ""

# 1. WebClient Basic auth settings (allow Basic auth over plain HTTP)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters"
$needReg = -not ((Test-RegistryValue $regPath "BasicAuthLevel" 2) -and (Test-RegistryValue $regPath "UseBasicAuth" 1))

if ($needReg) {
    Write-Host "First-time setup: registry change needed (an admin approval popup will appear)..." -ForegroundColor Yellow
    $regCmd = "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`" /v BasicAuthLevel /t REG_DWORD /d 2 /f; " +
              "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters`" /v UseBasicAuth /t REG_DWORD /d 1 /f; " +
              "net stop webclient; net start webclient"
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"$regCmd`""
} else {
    Write-Host "Registry: already OK" -ForegroundColor Green
}

# 2. Register server name in hosts file (a raw IP address is unreliable for this)
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsHasEntry = Select-String -Path $hostsPath -Pattern $ServerName -Quiet -ErrorAction SilentlyContinue

if (-not $hostsHasEntry) {
    Write-Host "First-time setup: hosts file entry needed (an admin approval popup will appear)..." -ForegroundColor Yellow
    $hostsLine = "$ServerIP`t$ServerName"
    $addCmd = "Add-Content -Path '$hostsPath' -Value '$hostsLine' -Encoding ASCII"
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"$addCmd`""
} else {
    Write-Host "hosts entry: already OK" -ForegroundColor Green
}

# 3. Remove any stale mapping, then map the drive WITHOUT admin rights
Write-Host "Connecting network drive..." -ForegroundColor Cyan
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
net use $DriveLetter /delete /y 2>$null | Out-Null
$ErrorActionPreference = $prevEAP
$netUseResult = net use $DriveLetter "\\$ServerName\DavWWWRoot\$ShareName" $SharePassword "/USER:$ShareUser" /PERSISTENT:YES

if ($LASTEXITCODE -eq 0) {
    Write-Host "Connected! $DriveLetter should now appear under This PC in File Explorer." -ForegroundColor Green
} else {
    Write-Host "Connection failed. Output: $netUseResult" -ForegroundColor Red
}
