#Requires -Version 5.1

<#
.SYNOPSIS
    Connects to a TLS service (host and port) and exports the certificate it presents to a .cer file.

.DESCRIPTION
    Opens a TCP connection to the host and port (a host name with several addresses: each address in
    turn, IPv4 and IPv6, until one answers), runs a TLS handshake (TLS 1.2, plus TLS 1.3 when this .NET
    version knows it, plus TLS 1.0 and 1.1 with -AllowLegacyTls) and saves the server certificate as a DER encoded .cer file. The certificate
    is accepted whatever its state, so expired, self-signed and untrusted certificates are exported too.
    Use it to collect the certificate of a web server, a management interface or any other TLS service,
    for example to import it into a trust store.

    Printed for the server certificate: subject, issuer, validity (with a warning when it is expired or
    expires within 30 days), thumbprint, the DNS names of the Subject Alternative Name extension, the
    negotiated protocol, whether this machine trusts the chain and whether the name matches.

    With -IncludeChain it also exports the issuing certificates: the chain that .NET builds from the
    certificates the server sent and the local certificate stores.

    If the handshake fails with TLS 1.3 offered (older Windows builds do not support TLS 1.3), the
    script tries once more without TLS 1.3. A handshake that times out is not retried.

    Requirements: uses the .NET TcpClient, SslStream and Dns classes, so it does not run in Constrained
    Language Mode. Revocation (CRL, OCSP) is not checked.

.PARAMETER HostName
    Host name or IP address of the TLS service.

.PARAMETER Port
    TCP port of the TLS service. Default: 443.

.PARAMETER ServerName
    Name sent in the handshake (SNI) and checked against the certificate. Default: HostName.
    Use it when connecting by IP address to a server that selects the certificate by name.

.PARAMETER IncludeChain
    Also export the issuing certificates as <host>_<port>_chain1.cer, _chain2.cer and so on.
    chain1 is the issuer of the server certificate, the last one is the root when it was found.

.PARAMETER AllowLegacyTls
    Also offer TLS 1.0 and TLS 1.1, for old management interfaces (iLO, iDRAC, UPS, switch web pages).
    The operating system of this machine may still refuse them (disabled in SChannel or in the OpenSSL policy).

.PARAMETER TimeoutSeconds
    Time limit for each TCP connection attempt (per address) and for the handshake. Default: 10.

.PARAMETER OutputPath
    Folder for the .cer files. Default: %USERPROFILE%\InfraToolkit-Output\Export-RemoteTlsCertificate\<timestamp>

.EXAMPLE
    .\Export-RemoteTlsCertificate.ps1 -HostName www.contoso.com
    Export the certificate of an HTTPS server on port 443.

.EXAMPLE
    .\Export-RemoteTlsCertificate.ps1 -HostName 192.0.2.10 -Port 8443 -ServerName srv01.contoso.com
    Connect by IP address and ask for the certificate of srv01.contoso.com.

.EXAMPLE
    .\Export-RemoteTlsCertificate.ps1 -HostName ex01.contoso.com -IncludeChain -OutputPath C:\Temp\certs
    Export the server certificate and its issuing certificates into C:\Temp\certs.

.EXAMPLE
    .\Export-RemoteTlsCertificate.ps1 -HostName 192.0.2.20 -AllowLegacyTls
    Old iLO or UPS web interface that only speaks TLS 1.0 or 1.1.

.NOTES
    Mode: Read-only
    Network: the target host and port, and the DNS server to resolve the name. Building the certificate
             chain may also contact other hosts: the AIA URL in the certificate (to download a missing
             issuing certificate) and, on Windows, Windows Update (root certificates). Revocation (CRL,
             OCSP) is not checked. In an isolated network this can add a delay that -TimeoutSeconds
             does not cover.
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = exported, 3 = could not connect, the handshake failed or the script could not run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$HostName,

    [ValidateRange(1, 65535)]
    [int]$Port = 443,

    [string]$ServerName,

    [switch]$IncludeChain,

    [switch]$AllowLegacyTls,

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 10,

    [string]$OutputPath = (Join-Path $env:USERPROFILE ('InfraToolkit-Output\{0}\{1}' -f
        ($MyInvocation.MyCommand.Name -replace '\.ps1$', ''), (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$EXIT_OK           = 0
$EXIT_NOT_RUN      = 3
$ExpiryWarningDays = 30
$SanOid            = '2.5.29.17'
$X509Type          = 'System.Security.Cryptography.X509Certificates.X509Certificate2'

if (-not $ServerName) { $ServerName = $HostName }

# ------------------------------------------------------------------ helpers
function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-24}: {1}' -f $Label, $Value)
}

function Get-ExceptionText {
    # Messages of the exception and its inner exceptions, without the PowerShell method call wrapper
    param([System.Exception]$Exception)
    $text = ''
    $e = $Exception
    while ($e) {
        $m = ([string]$e.Message).Trim()
        if ($e -isnot [System.Management.Automation.MethodInvocationException] -and $m -and
            -not $text.Contains($m.TrimEnd('.'))) {
            $text = ('{0} {1}' -f $text, $m).Trim()
        }
        $e = $e.InnerException
    }
    return $text
}

function Format-EndPoint {
    param($EndPoint)
    if (-not $EndPoint) { return '' }
    $address = $EndPoint.Address
    if ($address.IsIPv4MappedToIPv6) { $address = $address.MapToIPv4() }
    if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ('[{0}]:{1}' -f $address, $EndPoint.Port)
    }
    return ('{0}:{1}' -f $address, $EndPoint.Port)
}

function Get-TargetAddress {
    # The IP address as given, or the addresses of the host name (IPv6 only when this system supports it)
    $name = $HostName -replace '^\[(.+)\]$', '$1'
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$ip)) { return , @($ip) }
    $all = @([System.Net.Dns]::GetHostAddresses($name))
    $usable = @($all | Where-Object {
        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -or
        ($_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and [System.Net.Sockets.Socket]::OSSupportsIPv6)
    })
    if ($usable.Count -eq 0) { throw ('{0} has no IPv4 or IPv6 address that this system can use' -f $name) }
    return , $usable
}

function Connect-TcpTarget {
    # Tries each address in turn with a TcpClient of its address family (Windows PowerShell 5.1 creates
    # an IPv4 only client by default). Returns the first connected client, or throws with every failure.
    param([object[]]$Addresses, [int]$TimeoutMs)
    $failures = @()
    foreach ($address in $Addresses) {
        $candidate = New-Object System.Net.Sockets.TcpClient -ArgumentList $address.AddressFamily
        try {
            $connect = $candidate.BeginConnect($address, $Port, $null, $null)
            if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                throw ('no answer within {0} seconds' -f $TimeoutSeconds)
            }
            $candidate.EndConnect($connect)
            return $candidate
        } catch {
            $failures += ('{0}: {1}' -f $address, (Get-ExceptionText $_.Exception))
            $candidate.Close()
        }
    }
    if ($failures.Count -eq 1) { throw ($failures[0] -replace '^[^ ]+: ', '') }
    throw ($failures -join '; ')
}

function Test-IsTimeout {
    param([System.Exception]$Exception)
    $e = $Exception
    while ($e) {
        if ($e -is [System.TimeoutException]) { return $true }
        if ($e -is [System.Net.Sockets.SocketException] -and
            $e.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Get-SafeFileName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Get-ProtocolText {
    param([string]$Protocol)
    switch ($Protocol) {
        'Tls'   { return 'TLS 1.0' }
        'Tls11' { return 'TLS 1.1' }
        'Tls12' { return 'TLS 1.2' }
        'Tls13' { return 'TLS 1.3' }
        default { return $Protocol }
    }
}

function Get-SanText {
    # Format($false) gives "DNS Name=a, DNS Name=b" on Windows and "DNS:a, DNS:b" with OpenSSL
    param($Certificate)
    $ext = @($Certificate.Extensions | Where-Object { $_.Oid.Value -eq $SanOid })
    if ($ext.Count -eq 0) { return $null }
    return $ext[0].Format($false)
}

function Get-SanDnsName {
    param([string]$SanText)
    $names = @()
    foreach ($part in ($SanText -split '[,\r\n]+')) {
        if ($part -match '^\s*DNS[^:=]*[:=]\s*(\S+)\s*$') { $names += $Matches[1] }
    }
    return $names
}

function Invoke-TlsHandshake {
    # One connection and handshake. Returns the result, never throws.
    param([System.Security.Authentication.SslProtocols]$Protocols)

    $state = @{ PolicyErrors = $null; ChainStatus = @(); Chain = @() }
    $result = @{
        Ok = $false; Stage = 'connect'; Error = $null; Certificate = $null; Protocol = ''
        Remote = ''; PolicyErrors = $null; ChainStatus = @(); Chain = @()
    }
    $timeoutMs = $TimeoutSeconds * 1000
    $client = $null
    $ssl = $null
    try {
        $result.Stage = 'resolve'
        $addresses = Get-TargetAddress
        $result.Stage = 'connect'
        $client = Connect-TcpTarget -Addresses $addresses -TimeoutMs $timeoutMs
        $result.Remote = Format-EndPoint $client.Client.RemoteEndPoint

        $result.Stage = 'handshake'
        $stream = $client.GetStream()
        $stream.ReadTimeout = $timeoutMs
        $stream.WriteTimeout = $timeoutMs

        # Accept any certificate, record what the validation found
        $callback = {
            param($senderObject, $certificate, $chain, $policyErrors)
            $state.PolicyErrors = $policyErrors
            if ($chain) {
                $state.ChainStatus = @($chain.ChainStatus | ForEach-Object { [string]$_.Status })
                $copies = @()
                foreach ($element in $chain.ChainElements) { $copies += New-Object $X509Type -ArgumentList $element.Certificate }
                $state.Chain = $copies
            }
            return $true
        }
        $ssl = New-Object System.Net.Security.SslStream -ArgumentList $stream, $false, $callback
        $ssl.AuthenticateAsClient($ServerName, $null, $Protocols, $false)

        if (-not $ssl.RemoteCertificate) { throw 'the server did not send a certificate' }
        $result.Certificate  = New-Object $X509Type -ArgumentList $ssl.RemoteCertificate
        $result.Protocol     = [string]$ssl.SslProtocol
        $result.PolicyErrors = $state.PolicyErrors
        $result.ChainStatus  = $state.ChainStatus
        $result.Chain        = $state.Chain
        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($client) { $client.Close() }
    }
    return [pscustomobject]$result
}

function Get-IssuerChain {
    # Issuing certificates: from the handshake validation, or a local chain build when it gave none
    param($Handshake)
    $chain = @($Handshake.Chain)
    if ($chain.Count -eq 0) {
        $builder = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $builder.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $null = $builder.Build($Handshake.Certificate)
        foreach ($element in $builder.ChainElements) { $chain += New-Object $X509Type -ArgumentList $element.Certificate }
    }
    if ($chain.Count -le 1) { return @() }
    return @($chain[1..($chain.Count - 1)])
}

function Save-Certificate {
    param($Certificate, [string]$Path)
    $bytes = $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    $target = '{0}:{1}' -f $HostName, $Port

    # Protocols to offer. A second attempt without TLS 1.3 follows when the first one fails.
    $sslProtocols = 'System.Security.Authentication.SslProtocols' -as [type]
    $base = [System.Security.Authentication.SslProtocols]::Tls12
    if ($AllowLegacyTls) {
        $base = $base -bor [System.Security.Authentication.SslProtocols]::Tls -bor [System.Security.Authentication.SslProtocols]::Tls11
    }
    $attempts = @()
    if ([enum]::GetNames($sslProtocols) -contains 'Tls13') {
        $attempts += ($base -bor [System.Security.Authentication.SslProtocols]::Tls13)
    }
    $attempts += $base
    $offered = @(([string]$attempts[0]) -split ',\s*' | ForEach-Object { Get-ProtocolText $_ }) -join ', '

    $ip = $null
    if ([System.Net.IPAddress]::TryParse($ServerName, [ref]$ip)) {
        Write-Host ('Connecting to {0} (no SNI name, {1} is an IP address) ...' -f $target, $ServerName) -ForegroundColor Cyan
    } else {
        Write-Host ('Connecting to {0} (SNI name {1}) ...' -f $target, $ServerName) -ForegroundColor Cyan
    }
    Write-Host ('  Protocols offered: {0}' -f $offered)

    # A timeout is not retried, so the time limit holds
    $hs = Invoke-TlsHandshake -Protocols $attempts[0]
    if (-not $hs.Ok -and $hs.Stage -eq 'handshake' -and $attempts.Count -gt 1 -and -not (Test-IsTimeout $hs.Error)) {
        Write-Host ('  Handshake failed ({0}). Trying again without TLS 1.3.' -f (Get-ExceptionText $hs.Error)) -ForegroundColor Yellow
        $hs = Invoke-TlsHandshake -Protocols $attempts[1]
    }

    if (-not $hs.Ok) {
        $reason = Get-ExceptionText $hs.Error
        if ($hs.Stage -eq 'resolve') {
            Write-Host ('ERROR: could not resolve the host name {0}: {1}' -f $HostName, $reason) -ForegroundColor Red
        } elseif ($hs.Stage -eq 'connect') {
            Write-Host ('ERROR: could not connect to {0}: {1}' -f $target, $reason) -ForegroundColor Red
            Write-Host '       Check the host name, the port, and any firewall on the way.' -ForegroundColor Red
        } else {
            Write-Host ('ERROR: connected to {0}, but the TLS handshake failed: {1}' -f $target, $reason) -ForegroundColor Red
            Write-Host ('       The port may not be a TLS service, it may need STARTTLS, or the server does not accept {0}.' -f $offered) -ForegroundColor Red
            if (-not $AllowLegacyTls) { Write-Host '       For an old device that only speaks TLS 1.0 or 1.1, try -AllowLegacyTls.' -ForegroundColor Red }
        }
        return $EXIT_NOT_RUN
    }

    $cert = $hs.Certificate
    $now = Get-Date
    $sanText = Get-SanText $cert
    $dnsNames = @()
    if ($sanText) { $dnsNames = @(Get-SanDnsName $sanText) }

    Write-Host ''
    Write-Host (Format-Row 'Connected to' $hs.Remote)
    Write-Host (Format-Row 'Protocol' (Get-ProtocolText $hs.Protocol))
    Write-Host (Format-Row 'Subject' $cert.Subject)
    Write-Host (Format-Row 'Issuer' $cert.Issuer)
    Write-Host (Format-Row 'Valid from' $cert.NotBefore.ToString('yyyy-MM-dd HH:mm'))
    Write-Host (Format-Row 'Valid until' $cert.NotAfter.ToString('yyyy-MM-dd HH:mm'))
    Write-Host (Format-Row 'Thumbprint' $cert.Thumbprint)
    if ($dnsNames.Count -gt 0) {
        Write-Host (Format-Row 'DNS names (SAN)' ($dnsNames -join ', '))
    } elseif ($sanText) {
        Write-Host (Format-Row 'Alternative names (SAN)' $sanText)
    } else {
        Write-Host (Format-Row 'DNS names (SAN)' 'none (no Subject Alternative Name extension)') -ForegroundColor Yellow
    }

    $daysLeft = [int][math]::Floor(($cert.NotAfter - $now).TotalDays)
    if ($cert.NotAfter -lt $now) {
        Write-Host ('WARNING: the certificate EXPIRED on {0}.' -f $cert.NotAfter.ToString('yyyy-MM-dd')) -ForegroundColor Red
    } elseif ($cert.NotBefore -gt $now) {
        Write-Host ('WARNING: the certificate is not valid before {0}.' -f $cert.NotBefore.ToString('yyyy-MM-dd')) -ForegroundColor Red
    } elseif ($daysLeft -lt $ExpiryWarningDays) {
        Write-Host ('WARNING: the certificate expires in {0} days ({1}).' -f $daysLeft, $cert.NotAfter.ToString('yyyy-MM-dd')) -ForegroundColor Yellow
    }

    $errors = [string]$hs.PolicyErrors
    if ($errors -match 'RemoteCertificateChainErrors') {
        $status = @($hs.ChainStatus | Where-Object { $_ -and $_ -ne 'NoError' } | Select-Object -Unique)
        $detail = 'No'
        if ($status.Count -gt 0) { $detail = 'No ({0})' -f ($status -join ', ') }
        Write-Host (Format-Row 'Trusted on this machine' $detail) -ForegroundColor Yellow
    } elseif ($null -eq $hs.PolicyErrors) {
        Write-Host (Format-Row 'Trusted on this machine' 'unknown (no validation result)') -ForegroundColor Yellow
    } else {
        Write-Host (Format-Row 'Trusted on this machine' 'Yes') -ForegroundColor Green
    }
    if ($errors -match 'RemoteCertificateNameMismatch') {
        Write-Host (Format-Row 'Name matches' ('No, {0} is not in the certificate' -f $ServerName)) -ForegroundColor Yellow
    } elseif ($null -ne $hs.PolicyErrors) {
        Write-Host (Format-Row 'Name matches' ('Yes ({0})' -f $ServerName)) -ForegroundColor Green
    }

    # Export
    $outDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $base = '{0}_{1}' -f (Get-SafeFileName $HostName), $Port
    $leafFile = Join-Path $outDir ('{0}.cer' -f $base)
    Save-Certificate -Certificate $cert -Path $leafFile
    Write-Host ''
    Write-Host (Format-Row 'Certificate saved' $leafFile) -ForegroundColor Green

    if ($IncludeChain) {
        $issuers = @(Get-IssuerChain $hs)
        if ($issuers.Count -eq 0) {
            Write-Host (Format-Row 'Issuing certificates' 'none found (self-signed, or the issuers are unknown here)') -ForegroundColor Yellow
        }
        for ($i = 0; $i -lt $issuers.Count; $i++) {
            $chainFile = Join-Path $outDir ('{0}_chain{1}.cer' -f $base, ($i + 1))
            Save-Certificate -Certificate $issuers[$i] -Path $chainFile
            Write-Host (Format-Row ('Chain {0} saved' -f ($i + 1)) ('{0}  ({1})' -f $chainFile, $issuers[$i].Subject)) -ForegroundColor Green
        }
    }
    return $EXIT_OK
}

$exitCode = $EXIT_NOT_RUN
try {
    $exitCode = [int](@(Invoke-Main)[-1])
} catch {
    Write-Host ('ERROR: {0}' -f (Get-ExceptionText $_.Exception)) -ForegroundColor Red
    $exitCode = $EXIT_NOT_RUN
}
exit $exitCode
