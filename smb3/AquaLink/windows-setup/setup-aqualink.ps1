# AquaLink (iBook/PowerMac NAS share) connection setup
# Registry/hosts/certificate changes that need admin rights are
# auto-elevated; the actual "net use" drive mapping is run WITHOUT admin
# rights on purpose (a drive mapped from an elevated session is invisible
# in normal Explorer -- do NOT run this .bat file itself "as Administrator",
# it self-checks for that and will refuse to continue if it detects it).
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
$UseHTTPSInput = Read-Host "Is HTTPS (encryption) turned on in AquaLink's Share Settings? (y/N)"
$UseHTTPS = $UseHTTPSInput -match '^[Yy]'
$ShareName = Read-RequiredHost "Share name on the server (e.g. Pictures)"
$ShareUser = Read-RequiredHost "Username"
$SecurePassword = Read-Host "Password" -AsSecureString
$SharePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword))
$DriveLetter = "Z:"
$AuthScheme = if ($UseHTTPS) { "https" } else { "http" }

Write-Host ""

# 0. If HTTPS is on, fetch AquaLink's self-signed certificate and trust it.
#
# [2026-09-23] AquaLink generates its own self-signed certificate (there's
# no real CA behind it, since this is a LAN-only, self-hosted server). A TLS
# handshake always presents the server's certificate before any encryption
# or trust decision happens, so it can be captured directly over a raw
# SslStream connection with certificate validation disabled for JUST that
# one read -- no server-side support needed, and no plain-HTTP fallback
# required even though the server speaks HTTPS-only once this mode is on.
# Verified locally (macOS pwsh) against the real server before writing this:
# the extracted certificate's SHA1 fingerprint matched the server's own
# tls-cert.pem exactly. Once fetched, it's imported into the Local Machine
# Trusted Root store so `net use`/WebClient will accept it without a
# certificate-warning prompt (which net use has no way to click through).
function Import-AquaLinkCertificateIfNeeded {
    param($ServerIP, $ServerPort)

    $tcpClient = $null
    $sslStream = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient($ServerIP, [int]$ServerPort)
        $callback = { param($sender, $cert, $chain, $errors) return $true }
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, $callback)
        $sslStream.AuthenticateAsClient($ServerIP)
        $remoteCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$sslStream.RemoteCertificate
    } catch {
        Write-Host "Could not fetch the server's certificate: $_" -ForegroundColor Red
        return $false
    } finally {
        if ($sslStream) { $sslStream.Close() }
        if ($tcpClient) { $tcpClient.Close() }
    }

    $alreadyTrusted = Get-ChildItem -Path Cert:\LocalMachine\Root |
        Where-Object { $_.Thumbprint -eq $remoteCert.Thumbprint }
    if ($alreadyTrusted) {
        Write-Host "Certificate: already trusted" -ForegroundColor Green
        return $true
    }

    Write-Host "First-time setup: trusting AquaLink's certificate (an admin approval popup will appear)..." -ForegroundColor Yellow
    $certBytes = $remoteCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certPath = Join-Path $env:TEMP "aqualink-cert.cer"
    [System.IO.File]::WriteAllBytes($certPath, $certBytes)
    $tempScript = Join-Path $env:TEMP "aqualink-cert-import.ps1"
    @"
Import-Certificate -FilePath '$certPath' -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
"@ | Set-Content -Path $tempScript -Encoding UTF8
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    Remove-Item -Path $tempScript -ErrorAction SilentlyContinue
    Remove-Item -Path $certPath -ErrorAction SilentlyContinue
    return $true
}

if ($UseHTTPS) {
    if (-not (Import-AquaLinkCertificateIfNeeded -ServerIP $ServerIP -ServerPort $ServerPort)) {
        Write-Host "Stopping here since the certificate could not be verified." -ForegroundColor Red
        pause
        exit 1
    }
}

# 1. WebClient Basic auth settings (allow Basic auth over plain HTTP)
#
# [2026-09-22] AuthForwardServerList: WebClient refuses to send Basic-auth
# credentials to a server unless a URL pattern for it is on this list. Real-
# world testing initially used a bare "*" here, which is NOT the documented
# wildcard syntax and did not fix the "not authenticated" error (system
# error 1244) at all. Per Microsoft's own docs (KB941050 / "Using the WebDAV
# Redirector"), entries must be URL patterns like "http://server" or
# "*.domain.com" -- explicitly WITHOUT a port number -- and a lone "*" isn't
# one of the documented forms. Fixed to add "http://$ServerName" (no port),
# appended to whatever's already there rather than replacing it, so
# connecting to more than one AquaLink share under different names doesn't
# clobber earlier entries.
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters"
$authForwardList = (Get-ItemProperty -Path $regPath -Name "AuthForwardServerList" -ErrorAction SilentlyContinue).AuthForwardServerList
$authEntry = "${AuthScheme}://$ServerName"
$hasAuthEntry = ($null -ne $authForwardList) -and ($authForwardList -contains $authEntry)
$needReg = -not ((Test-RegistryValue $regPath "BasicAuthLevel" 2) -and (Test-RegistryValue $regPath "UseBasicAuth" 1) -and $hasAuthEntry)

if ($needReg) {
    Write-Host "First-time setup: registry change needed (an admin approval popup will appear)..." -ForegroundColor Yellow
    $newAuthList = @($authForwardList) + $authEntry | Where-Object { $_ } | Select-Object -Unique
    $authListLiteral = ($newAuthList | ForEach-Object { "'$_'" }) -join ","
    $tempScript = Join-Path $env:TEMP "aqualink-webclient-fix.ps1"
    @"
Set-ItemProperty -Path '$regPath' -Name 'BasicAuthLevel' -Type DWord -Value 2
Set-ItemProperty -Path '$regPath' -Name 'UseBasicAuth' -Type DWord -Value 1
Set-ItemProperty -Path '$regPath' -Name 'AuthForwardServerList' -Type MultiString -Value @($authListLiteral)
Restart-Service WebClient -Force
"@ | Set-Content -Path $tempScript -Encoding UTF8
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    Remove-Item -Path $tempScript -ErrorAction SilentlyContinue
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
# (auth-related) failure. For HTTPS, the convention is "@SSL@port" instead
# of just "@port".
$sslSegment = if ($UseHTTPS) { "@SSL" } else { "" }
$netUseResult = net use $DriveLetter "\\$ServerName$sslSegment@$ServerPort\DavWWWRoot\$ShareName" $SharePassword "/USER:$ShareUser" /PERSISTENT:YES

if ($LASTEXITCODE -eq 0) {
    Write-Host "Connected! $DriveLetter should now appear under This PC in File Explorer." -ForegroundColor Green
} else {
    Write-Host "Connection failed. Output: $netUseResult" -ForegroundColor Red
}
