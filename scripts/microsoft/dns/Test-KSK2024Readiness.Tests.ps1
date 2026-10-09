#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Test-KSK2024Readiness.ps1 - verdicts and exit codes against mocked DNS servers.

.DESCRIPTION
    The DnsServer cmdlets and Resolve-DnsName are replaced by global functions that return a
    scenario. No real DNS server or network access is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Test-KSK2024Readiness.ps1'

    function script:New-TestAnchor {
        param([int]$Tag, [string]$State, [string]$Type = 'DNSKEY', [switch]$NoKeyTagProperty)
        $data = if ($NoKeyTagProperty) { "[$Tag][DnsSec][RsaSha256][AwEAAxyz]" }
                else { [pscustomobject]@{ KeyTag = $Tag; CryptoAlgorithm = 'RsaSha256' } }
        [pscustomobject]@{ TrustAnchorName = '.'; TrustAnchorType = $Type; TrustAnchorState = $State; TrustAnchorData = $data }
    }

    function script:New-TestTrustPoint {
        param([string]$State = 'Active', [int]$DaysAgo = 0)
        [pscustomobject]@{
            TrustPointName        = '.'
            TrustPointState       = $State
            LastActiveRefreshTime = (Get-Date).AddDays(-$DaysAgo)
            NextActiveRefreshTime = (Get-Date).AddDays(1)
        }
    }

    # DNS behaviour profiles: query name -> OK / SERVFAIL (anything else times out)
    $base = @{ 'valid.alg13.dnstest.dev' = 'OK'; 'cloudflare.com' = 'OK' }
    function script:New-Profile {
        param([string]$Bogus, [string]$IsTa, [string]$NotTa)
        $p = $base.Clone()
        $p['invalid.alg13.dnstest.dev'] = $Bogus
        $p['dnssec-failed.org'] = $Bogus
        $p['root-key-sentinel-is-ta-38696.dnstest.dev'] = $IsTa
        $p['root-key-sentinel-not-ta-38696.dnstest.dev'] = $NotTa
        $p
    }
    $script:NoValidation  = New-Profile 'OK'       'OK'       'OK'
    $script:ValNoSentinel = New-Profile 'SERVFAIL' 'OK'       'OK'
    $script:ValReady      = New-Profile 'SERVFAIL' 'OK'       'SERVFAIL'
    $script:ValNotReady   = New-Profile 'SERVFAIL' 'SERVFAIL' 'OK'
    $script:Unreachable   = @{}

    # "Internal" forwarders use link-local 169.254.x.x addresses: the script treats them as internal,
    # and they do not trip the private-IP rules of the pre-commit hook and gitleaks (RFC 1918 only).

    # Mocked cmdlets. Functions take precedence over cmdlets, so this also works on a real DNS server.
    function global:Get-KskTestConfig {
        param($ComputerName)
        $c = $global:KskScenario.Servers[[string]$ComputerName]
        if ($c.Fail) { throw $c.Fail }
        $c
    }
    function global:Get-DnsServerSetting {
        [CmdletBinding()] param([switch]$All, $ComputerName)
        $c = Get-KskTestConfig $ComputerName
        [pscustomobject]@{ EnableDnsSec = $c.Dnssec; RootTrustAnchorsURL = 'https://data.iana.org/root-anchors/root-anchors.xml' }
    }
    function global:Get-DnsServerTrustPoint {
        [CmdletBinding()] param($ComputerName)
        $c = Get-KskTestConfig $ComputerName
        if ($c.TP) { $c.TP }
    }
    function global:Get-DnsServerTrustAnchor {
        [CmdletBinding()] param($Name, $ComputerName)
        $c = Get-KskTestConfig $ComputerName
        if (-not $c.TA -or @($c.TA).Count -eq 0) { throw 'Failed to enumerate the trust anchors' }
        $c.TA
    }
    function global:Get-DnsServerForwarder {
        [CmdletBinding()] param($ComputerName)
        $c = Get-KskTestConfig $ComputerName
        [pscustomobject]@{ IPAddress = @($c.Fwd | ForEach-Object { [System.Net.IPAddress]::Parse($_) }); UseRootHint = $c.Hint }
    }
    function global:Resolve-DnsName {
        [CmdletBinding()] param($Name, $Type, $Server, [switch]$DnsOnly, [switch]$NoHostsFile, [switch]$DnssecOk)
        $prof = $global:KskScenario.Dns[[string]$Server]
        $result = if ($prof -and $prof.ContainsKey($Name)) { $prof[$Name] } else { 'TIMEOUT' }
        switch ($result) {
            'OK' { return [pscustomobject]@{ Name = $Name; Type = 'A'; IPAddress = '192.0.2.1' } }
            'SERVFAIL' {
                $er = New-Object System.Management.Automation.ErrorRecord(
                    (New-Object System.ComponentModel.Win32Exception 9002),
                    'DNS_ERROR_RCODE_SERVER_FAILURE,Microsoft.DnsClient.Commands.ResolveDnsName', 'ResourceUnavailable', $Name)
                $PSCmdlet.ThrowTerminatingError($er)
            }
            default {
                $er = New-Object System.Management.Automation.ErrorRecord(
                    (New-Object System.ComponentModel.Win32Exception 1460),
                    'ERROR_TIMEOUT,Microsoft.DnsClient.Commands.ResolveDnsName', 'OperationTimeout', $Name)
                $PSCmdlet.ThrowTerminatingError($er)
            }
        }
    }

    function script:Invoke-Scenario {
        param([hashtable]$Servers, [hashtable]$Dns)
        $global:KskScenario = @{ Servers = $Servers; Dns = $Dns }
        $report = Join-Path $TestDrive ('report-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        & $script:Target -ComputerName @($Servers.Keys) -ReportPath $report *> $null
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Report = (Get-Content -LiteralPath $report -Raw) }
    }
}

AfterAll {
    foreach ($f in 'Get-KskTestConfig', 'Get-DnsServerSetting', 'Get-DnsServerTrustPoint',
                   'Get-DnsServerTrustAnchor', 'Get-DnsServerForwarder', 'Resolve-DnsName') {
        Remove-Item -Path "Function:\global:$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name KskScenario -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Test-KSK2024Readiness' {

    Context 'No action required (exit 0)' {

        It 'no root anchor, external forwarder validates without sentinel support' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('198.51.100.53'); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel; '198.51.100.53' = $ValNoSentinel }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'NOT_VALIDATING'
        }

        It 'root hints only, no validation anywhere' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $NoValidation }
            $r.ExitCode | Should -Be 0
        }

        It 'validates locally and key tag 38696 is Valid' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid'), (New-TestAnchor 38696 'Valid')); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel }
            $r.ExitCode | Should -Be 0
            $r.Report   | Should -Match 'Local validation status\s+: READY'
        }

        It 'reads the key tag from the text form when TrustAnchorData has no KeyTag property' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid' -NoKeyTagProperty), (New-TestAnchor 38696 'Valid' -NoKeyTagProperty)); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel }
            $r.ExitCode | Should -Be 0
        }

        It 'root anchors exist but EnableDnsSec is False' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $false; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid')); Fwd = @('198.51.100.53'); Hint = $false } } `
                                 -Dns @{ DC01 = $ValNoSentinel; '198.51.100.53' = $ValNoSentinel }
            $r.ExitCode | Should -Be 0
        }

        It 'internal forwarder confirmed ready by sentinel' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('169.254.0.5'); Hint = $false } } `
                                 -Dns @{ DC01 = $ValReady; '169.254.0.5' = $ValReady }
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'Action required (exit 1)' {

        It 'validates locally, key tag 38696 absent' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid')); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel }
            $r.ExitCode | Should -Be 1
        }

        It 'validates locally, key tag 38696 in <State>' -ForEach @(
            @{ State = 'Add Pending'; Type = 'DNSKEY' }
            @{ State = 'DSPending';   Type = 'DS' }
            @{ State = 'Revoked';     Type = 'DNSKEY' }
        ) {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid'), (New-TestAnchor 38696 $State $Type)); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'NOT_READY'
        }

        It 'external forwarder does not trust KSK-2024 (sentinel)' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('203.0.113.53'); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNotReady; '203.0.113.53' = $ValNotReady }
            $r.ExitCode | Should -Be 1
        }

        It 'the worst server decides the overall status' {
            $r = Invoke-Scenario -Servers @{
                    DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('198.51.100.53'); Hint = $true }
                    DC02 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid')); Fwd = @(); Hint = $true }
                 } -Dns @{ DC01 = $ValNoSentinel; DC02 = $ValNoSentinel; '198.51.100.53' = $ValNoSentinel }
            $r.ExitCode | Should -Be 1
            $r.Report   | Should -Match 'OVERALL: ACTION REQUIRED'
        }
    }

    Context 'Manual check required (exit 2)' {

        It 'internal forwarder validates but has no sentinel support' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('169.254.0.5'); Hint = $false } } `
                                 -Dns @{ DC01 = $ValNoSentinel; '169.254.0.5' = $ValNoSentinel }
            $r.ExitCode | Should -Be 2
        }

        It 'internal forwarder unreachable' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid'), (New-TestAnchor 38696 'Valid')); Fwd = @('169.254.1.1'); Hint = $false } } `
                                 -Dns @{ DC01 = $ValNoSentinel; '169.254.1.1' = $Unreachable }
            $r.ExitCode | Should -Be 2
        }

        It 'DNS configuration cannot be read' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Fail = 'Access is denied.' } } -Dns @{}
            $r.ExitCode | Should -Be 2
        }

        It 'key tag 38696 trusted but Missing in the last refresh' {
            $r = Invoke-Scenario -Servers @{ DC01 = @{ Dnssec = $true; TP = (New-TestTrustPoint); TA = @((New-TestAnchor 20326 'Valid'), (New-TestAnchor 38696 'Missing')); Fwd = @(); Hint = $true } } `
                                 -Dns @{ DC01 = $ValNoSentinel }
            $r.ExitCode | Should -Be 2
        }
    }

    Context 'Report file' {

        It 'without -ReportPath: the report goes to InfraToolkit-Output\Test-KSK2024Readiness next to the script' {
            $folder = Join-Path $TestDrive 'default-report'
            $null = New-Item -ItemType Directory -Path $folder -Force
            Copy-Item -LiteralPath $script:Target -Destination $folder
            $copy = Join-Path $folder 'Test-KSK2024Readiness.ps1'
            $global:KskScenario = @{
                Servers = @{ DC01 = @{ Dnssec = $true; TP = $null; TA = @(); Fwd = @('198.51.100.53'); Hint = $true } }
                Dns     = @{ DC01 = $ValNoSentinel; '198.51.100.53' = $ValNoSentinel }
            }
            $run = @{ ComputerName = @('DC01') }
            $output = & $copy @run *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $reports = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $folder 'InfraToolkit-Output') 'Test-KSK2024Readiness'))
            $reports.Count | Should -Be 1
            $reports[0].Name | Should -Match '^KSK2024-Readiness-.+-\d{8}-\d{4}\.txt$'
            Get-Content -LiteralPath $reports[0].FullName -Raw | Should -Match 'NOT_VALIDATING'
            ($output -replace '\s', '') | Should -Match ([regex]::Escape($reports[0].FullName))
        }
    }
}
