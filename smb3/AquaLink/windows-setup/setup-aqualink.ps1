# AquaLink (iBook/PowerMac NAS share) connection setup
# Registry/hosts changes that need admin rights are auto-elevated;
# the actual "net use" drive mapping is run WITHOUT admin rights on purpose
# (a drive mapped from an elevated session is invisible in normal Explorer).

# --- Edit these for your environment ---
$ServerIP = "192.168.11.2"
$ServerName = "aqualink-ibook"
$ShareName = "Pictures"
$ShareUser = "watermark"
$SharePassword = "CHANGE_ME"
$DriveLetter = "Z:"
# ----------------------------------------

$ErrorActionPreference = "Stop"

function Test-RegistryValue {
    param($Path, $Name, $Expected)
    $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($val -eq $Expected)
}

Write-Host "=== AquaLink connection setup ===" -ForegroundColor Cyan

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
