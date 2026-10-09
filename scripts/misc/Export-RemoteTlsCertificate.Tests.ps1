#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Export-RemoteTlsCertificate.ps1 - real TLS handshakes against a local test server.

.DESCRIPTION
    The tests create their own certificates (self-signed, and a root > intermediate > server chain) and
    serve TLS on 127.0.0.1 from a background runspace, on a port chosen by the system. A second listener
    accepts TCP but never answers, to test the handshake time limit. No outside network access is needed.
    The handshake tests need .NET features of PowerShell 7 (CertificateRequest, SslStreamCertificateContext)
    and are skipped on Windows PowerShell 5.1.

.NOTES
    Mode: Read-only
    Network: 127.0.0.1 only
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Export-RemoteTlsCertificate.ps1'
    $script:IsCore = $PSVersionTable.PSVersion.Major -ge 7
    $script:Server = $null
    $script:Server6 = $null
    $script:Silent = $null

    function script:Import-TestPfx {
        # A certificate with an ephemeral key cannot always serve TLS (Windows, some Linux builds):
        # export it with its private key and load it again.
        param($Certificate)
        $pfx = $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        if ($loader) { return $loader::LoadPkcs12($pfx, $null) }
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }

    function script:New-TestCertificate {
        param(
            [string]$Subject,
            [string[]]$DnsName = @(),
            [int]$NotAfterDays = 365,
            $Issuer,
            [switch]$Authority
        )
        $ns = 'System.Security.Cryptography.X509Certificates'
        $key = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Subject, $key,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if ($Authority) {
            $req.CertificateExtensions.Add((New-Object "$ns.X509BasicConstraintsExtension" -ArgumentList $true, $false, 0, $true))
            $req.CertificateExtensions.Add((New-Object "$ns.X509KeyUsageExtension" -ArgumentList ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign'), $true))
        } else {
            $req.CertificateExtensions.Add((New-Object "$ns.X509BasicConstraintsExtension" -ArgumentList $false, $false, 0, $false))
            $req.CertificateExtensions.Add((New-Object "$ns.X509KeyUsageExtension" -ArgumentList ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment'), $true))
            $eku = New-Object System.Security.Cryptography.OidCollection
            $null = $eku.Add((New-Object System.Security.Cryptography.Oid -ArgumentList '1.3.6.1.5.5.7.3.1'))
            $req.CertificateExtensions.Add((New-Object "$ns.X509EnhancedKeyUsageExtension" -ArgumentList $eku, $false))
            if ($DnsName.Count -gt 0) {
                $san = New-Object "$ns.SubjectAlternativeNameBuilder"
                foreach ($n in $DnsName) { $san.AddDnsName($n) }
                $req.CertificateExtensions.Add($san.Build())
            }
        }
        $req.CertificateExtensions.Add((New-Object "$ns.X509SubjectKeyIdentifierExtension" -ArgumentList $req.PublicKey, $false))
        $notBefore = [DateTimeOffset]::UtcNow.AddDays(-2)
        $notAfter = [DateTimeOffset]::UtcNow.AddDays($NotAfterDays)
        if ($Issuer) {
            $serial = [byte[]]::new(8)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($serial)
            $signed = $req.Create($Issuer, $notBefore, $notAfter, $serial)
            $cert = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($signed, $key)
        } else {
            $cert = $req.CreateSelfSigned($notBefore, $notAfter)
        }
        return (Import-TestPfx $cert)
    }

    function script:New-TestContext {
        param($Certificate, $Extra = @())
        $coll = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        foreach ($c in $Extra) { $null = $coll.Add($c) }
        return [System.Net.Security.SslStreamCertificateContext]::Create($Certificate, $coll)
    }

    # TLS server in a background runspace. Mode 'Tls' serves the current context, 'Close' drops the connection.
    $script:ServerCode = {
        param($Listener, $State)
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while (-not $State.Stop -and [DateTime]::UtcNow -lt $deadline) {
            if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 20; continue }
            $client = $Listener.AcceptTcpClient()
            $ssl = $null
            try {
                $State.Connections++
                if ($State.Mode -eq 'Close') { continue }
                $client.ReceiveTimeout = 10000
                $client.SendTimeout = 10000
                $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
                $options = [System.Net.Security.SslServerAuthenticationOptions]::new()
                $options.ServerCertificateContext = $State.Context
                $task = $ssl.AuthenticateAsServerAsync($options, [System.Threading.CancellationToken]::None)
                if ($task.Wait(15000)) { $null = $State.Sni.Add([string]$ssl.TargetHostName) }
                else { $null = $State.Errors.Add('server handshake timeout') }
            } catch {
                $null = $State.Errors.Add($_.Exception.Message)
            } finally {
                if ($ssl) { $ssl.Dispose() }
                $client.Dispose()
            }
        }
    }

    function script:Start-TestServer {
        param([System.Net.IPAddress]$Address = [System.Net.IPAddress]::Loopback)
        $listener = [System.Net.Sockets.TcpListener]::new($Address, 0)
        $listener.Start()
        $state = [hashtable]::Synchronized(@{
            Stop = $false; Mode = 'Tls'; Context = $null; Connections = 0
            Sni = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            Errors = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        })
        $ps = [powershell]::Create()
        $null = $ps.AddScript($script:ServerCode.ToString()).AddArgument($listener).AddArgument($state)
        $handle = $ps.BeginInvoke()
        return [pscustomobject]@{ Listener = $listener; State = $state; PowerShell = $ps; Handle = $handle; Port = $listener.LocalEndpoint.Port }
    }

    function script:Stop-TestServer {
        param($Server)
        if (-not $Server) { return }
        $Server.State.Stop = $true
        $null = $Server.Handle.AsyncWaitHandle.WaitOne(5000)
        $Server.Listener.Stop()
        if (-not $Server.Handle.IsCompleted) { $Server.PowerShell.Stop() }
        $Server.PowerShell.Dispose()
    }

    function script:Get-FreePort {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $l.Start()
        $p = $l.LocalEndpoint.Port
        $l.Stop()
        return $p
    }

    function script:Use-ServerCertificate {
        param($Context, [string]$Mode = 'Tls')
        $script:Server.State.Context = $Context
        $script:Server.State.Mode = $Mode
        $script:Server.State.Connections = 0
        $script:Server.State.Sni.Clear()
        $script:Server.State.Errors.Clear()
    }

    function script:Invoke-Export {
        param([hashtable]$Params = @{}, [int]$Port = $script:Server.Port, [string]$HostName = '127.0.0.1')
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $started = Get-Date
        $text = & $script:Target -HostName $HostName -Port $Port -OutputPath $out @Params *>&1 | Out-String
        $code = $LASTEXITCODE
        $files = @()
        if (Test-Path -LiteralPath $out) { $files = @(Get-ChildItem -LiteralPath $out -File | Sort-Object Name) }
        return [pscustomobject]@{
            ExitCode = $code; Output = $text; Out = $out; Files = $files
            Names = @($files | ForEach-Object { $_.Name }); Seconds = ((Get-Date) - $started).TotalSeconds
        }
    }

    function script:Get-FileThumbprint {
        # A certificate thumbprint is the SHA-1 hash of its DER encoding, so this also proves the file is plain DER
        param([string]$Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash
    }

    if ($script:IsCore) {
        $script:SelfSigned = New-TestCertificate -Subject 'CN=SRV01.contoso.com' -DnsName 'SRV01.contoso.com', 'www.example.com'
        $script:SelfSignedContext = New-TestContext $script:SelfSigned

        $script:Root = New-TestCertificate -Subject 'CN=Example Test Root CA' -Authority -NotAfterDays 3650
        $script:Intermediate = New-TestCertificate -Subject 'CN=Example Test Issuing CA' -Authority -NotAfterDays 1825 -Issuer $script:Root
        $script:Leaf = New-TestCertificate -Subject 'CN=www.contoso.com' -DnsName 'www.contoso.com' -NotAfterDays 365 -Issuer $script:Intermediate
        $script:ChainContext = New-TestContext $script:Leaf @($script:Intermediate)

        $script:Expiring = New-TestCertificate -Subject 'CN=EX01.contoso.com' -DnsName 'EX01.contoso.com' -NotAfterDays 10
        $script:ExpiringContext = New-TestContext $script:Expiring

        $script:Server = Start-TestServer
        try { $script:Server6 = Start-TestServer -Address ([System.Net.IPAddress]::IPv6Loopback) } catch { $script:Server6 = $null }

        # Accepts TCP (the system completes the connection) but never answers the TLS handshake
        $script:Silent = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $script:Silent.Start()
    }
}

AfterAll {
    if ($script:Server) { Stop-TestServer $script:Server }
    if ($script:Server6) { Stop-TestServer $script:Server6 }
    if ($script:Silent) { $script:Silent.Stop() }
}

Describe 'Export-RemoteTlsCertificate' {

    Context 'Successful export' {

        It 'exports the server certificate as host_port.cer (exit 0)' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Be @("127.0.0.1_$($script:Server.Port).cer")
            Get-FileThumbprint $r.Files[0].FullName | Should -Be $script:SelfSigned.Thumbprint
        }

        It 'prints subject, issuer, thumbprint, SAN DNS names, protocol and trust' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export
            $r.Output | Should -Match 'Subject\s+: CN=SRV01\.contoso\.com'
            $r.Output | Should -Match 'Issuer\s+: CN=SRV01\.contoso\.com'
            $r.Output | Should -Match ('Thumbprint\s+: ' + $script:SelfSigned.Thumbprint)
            $r.Output | Should -Match 'DNS names \(SAN\)\s+: SRV01\.contoso\.com, www\.example\.com'
            $r.Output | Should -Match 'Protocol\s+: TLS 1\.[23]'
            $r.Output | Should -Match 'Trusted on this machine : No \(.*UntrustedRoot'
            $r.Output | Should -Not -Match 'WARNING'
        }

        It 'sends -ServerName as the SNI name and checks it against the certificate' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export -Params @{ ServerName = 'www.example.com' }
            $r.ExitCode | Should -Be 0
            @($script:Server.State.Sni) | Should -Be @('www.example.com')
            $r.Output | Should -Match 'Name matches\s+: Yes \(www\.example\.com\)'

            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export -Params @{ ServerName = 'srv02.example.com' }
            $r.ExitCode | Should -Be 0
            @($script:Server.State.Sni) | Should -Be @('srv02.example.com')
            $r.Output | Should -Match 'Name matches\s+: No, srv02\.example\.com is not in the certificate'
        }

        It 'uses a file name safe form of the host name (IPv6 address)' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            if (-not $script:Server6) { Set-ItResult -Skipped -Because 'IPv6 loopback is not available on this machine' }
            $script:Server6.State.Context = $script:SelfSignedContext
            $r = Invoke-Export -HostName '::1' -Port $script:Server6.Port
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Be @("__1_$($script:Server6.Port).cer")
            Get-FileThumbprint $r.Files[0].FullName | Should -Be $script:SelfSigned.Thumbprint
        }

        It 'host name with several addresses: tries each one until it connects (localhost)' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            # The server listens on IPv4 only. Where localhost also resolves to ::1, that address is refused first.
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export -HostName 'localhost'
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Be @("localhost_$($script:Server.Port).cer")
            $r.Output   | Should -Match 'Connected to\s+: 127\.0\.0\.1:'
            @($script:Server.State.Sni) | Should -Be @('localhost')
        }

        It '-AllowLegacyTls also offers TLS 1.0 and 1.1 and still negotiates the best protocol' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export -Params @{ AllowLegacyTls = $true }
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'Protocols offered: TLS 1\.0, TLS 1\.1, TLS 1\.2'
            $r.Output   | Should -Match 'Protocol\s+: TLS 1\.[23]'
            $r = Invoke-Export
            $r.Output   | Should -Match 'Protocols offered: TLS 1\.2(, TLS 1\.3)?\s'
        }

        It 'warns when the certificate expires within 30 days' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:ExpiringContext
            $r = Invoke-Export
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'WARNING: the certificate expires in (9|10) days'
            Get-FileThumbprint $r.Files[0].FullName | Should -Be $script:Expiring.Thumbprint
        }
    }

    Context '-IncludeChain' {

        It 'self-signed certificate: no chain files, no failure' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext
            $r = Invoke-Export -Params @{ IncludeChain = $true }
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Be @("127.0.0.1_$($script:Server.Port).cer")
            $r.Output   | Should -Match 'Issuing certificates\s+: none found'
        }

        It 'exports the issuing CA the server sent as _chain1.cer' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:ChainContext
            $r = Invoke-Export -Params @{ IncludeChain = $true }
            $base = "127.0.0.1_$($script:Server.Port)"
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Contain "$base.cer"
            $r.Names    | Should -Contain "${base}_chain1.cer"
            Get-FileThumbprint (Join-Path $r.Out "$base.cer") | Should -Be $script:Leaf.Thumbprint
            Get-FileThumbprint (Join-Path $r.Out "${base}_chain1.cer") | Should -Be $script:Intermediate.Thumbprint
            $r.Output | Should -Match 'Chain 1 saved.*CN=Example Test Issuing CA'
        }

        It 'without -IncludeChain only the server certificate is saved' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:ChainContext
            $r = Invoke-Export
            $r.ExitCode | Should -Be 0
            $r.Names    | Should -Be @("127.0.0.1_$($script:Server.Port).cer")
            Get-FileThumbprint $r.Files[0].FullName | Should -Be $script:Leaf.Thumbprint
        }
    }

    Context 'Failures (exit 3)' {

        It 'closed port: exit 3 quickly, nothing saved' {
            $r = Invoke-Export -Port (Get-FreePort) -Params @{ TimeoutSeconds = 2 }
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'ERROR: could not connect to 127\.0\.0\.1:'
            $r.Files.Count | Should -Be 0
            $r.Seconds  | Should -BeLessThan 15
        }

        It 'server accepts TCP but does not answer: exit 3 after the time limit' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            $r = Invoke-Export -Port $script:Silent.LocalEndpoint.Port -Params @{ TimeoutSeconds = 2 }
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'the TLS handshake failed'
            $r.Output   | Should -Not -Match 'Trying again without TLS 1\.3'
            $r.Files.Count | Should -Be 0
            $r.Seconds  | Should -BeLessThan 15
        }

        It 'server closes the connection without TLS: one retry without TLS 1.3, then exit 3' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            Use-ServerCertificate $script:SelfSignedContext -Mode 'Close'
            $r = Invoke-Export -Params @{ TimeoutSeconds = 5 }
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'Trying again without TLS 1\.3'
            $r.Output   | Should -Match 'try -AllowLegacyTls'
            $r.Output   | Should -Match 'the TLS handshake failed'
            $script:Server.State.Connections | Should -Be 2
            $r.Files.Count | Should -Be 0
            $r.Seconds  | Should -BeLessThan 15
        }

        It 'host name that cannot be resolved: exit 3' {
            $r = Invoke-Export -HostName 'nohost.example.invalid' -Port 443 -Params @{ TimeoutSeconds = 2 }
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'ERROR: could not resolve the host name nohost\.example\.invalid'
            $r.Files.Count | Should -Be 0
        }

        It 'rejects an invalid port' {
            { & $script:Target -HostName 'SRV01' -Port 0 -OutputPath (Join-Path $TestDrive 'x') } | Should -Throw
            { & $script:Target -HostName 'SRV01' -Port 65536 -OutputPath (Join-Path $TestDrive 'x') } | Should -Throw
        }
    }
}
