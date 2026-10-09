#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Add-DnsServerToActiveAdapters.ps1 - report, exit codes and -Fix against mocked network adapters.

.DESCRIPTION
    Get-NetAdapter, Get-DnsClientServerAddress, Set-DnsClientServerAddress, whoami.exe and the read of the
    TCP/IP interface key are replaced by global functions backed by an in-memory scenario. No Windows
    system is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Add-DnsServerToActiveAdapters.ps1'

    $script:SavedEnv = @{ COMPUTERNAME = [Environment]::GetEnvironmentVariable('COMPUTERNAME') }
    $env:COMPUTERNAME = 'SRV01'

    function script:Register-DnsMock {
        function global:Get-NetAdapter {
            [CmdletBinding()] param()
            foreach ($a in $global:DnsScenario.Adapters) {
                [pscustomobject]@{
                    Name = $a.Name; InterfaceAlias = $a.Name; InterfaceIndex = $a.Index; ifIndex = $a.Index
                    InterfaceGuid = $a.Guid; Status = $a.Status; InterfaceDescription = 'Example Ethernet Adapter'
                }
            }
        }

        # Like the CIM cmdlets: no object for an interface without IPv4 -> ObjectNotFound error
        function global:Get-NetIPInterface {
            [CmdletBinding()] param([string]$AddressFamily, [int]$InterfaceIndex)
            $global:DnsScenario.IpIfCalls += ('{0}:{1}' -f $AddressFamily, $InterfaceIndex)
            $a = @($global:DnsScenario.Adapters | Where-Object { $_.Index -eq $InterfaceIndex })[0]
            if (-not $a -or ($a.NoIPv4 -and $AddressFamily -eq 'IPv4')) {
                Write-Error -Message "No MSFT_NetIPInterface objects found with property 'InterfaceIndex' equal to '$InterfaceIndex'." -Category ObjectNotFound
                return
            }
            [pscustomobject]@{ InterfaceIndex = $a.Index; InterfaceAlias = $a.Name; AddressFamily = $AddressFamily }
        }

        function global:Get-DnsClientServerAddress {
            [CmdletBinding()] param([int]$InterfaceIndex, [string]$AddressFamily)
            $global:DnsScenario.Families += $AddressFamily
            if ($global:DnsScenario.DnsThrows) { throw $global:DnsScenario.DnsThrows }
            $a = @($global:DnsScenario.Adapters | Where-Object { $_.Index -eq $InterfaceIndex })[0]
            if (-not $a -or $a.NoIPv4 -or $a.DnsNotFound) {
                $er = New-Object System.Management.Automation.ErrorRecord(
                    (New-Object System.Exception "No MSFT_DNSClientServerAddress objects found with property 'InterfaceIndex' equal to '$InterfaceIndex'."),
                    'CmdletizationQuery_NotFound_InterfaceIndex,Get-DnsClientServerAddress', 'ObjectNotFound', $InterfaceIndex)
                $PSCmdlet.ThrowTerminatingError($er)
            }
            [pscustomobject]@{ InterfaceAlias = $a.Name; InterfaceIndex = $a.Index; AddressFamily = 2; ServerAddresses = [string[]]@($a.Servers) }
        }

        function global:Set-DnsClientServerAddress {
            [CmdletBinding(SupportsShouldProcess)] param([int]$InterfaceIndex, [string[]]$ServerAddresses)
            $s = $global:DnsScenario
            $s.SetCalls += [pscustomobject]@{ Index = $InterfaceIndex; Servers = @($ServerAddresses) }
            $a = @($s.Adapters | Where-Object { $_.Index -eq $InterfaceIndex })[0]
            if ($s.FailSet -and $a.Name -like $s.FailSet) { throw 'Access is denied.' }
            if ($s.IgnoreSet -and $a.Name -like $s.IgnoreSet) { return }
            $a.Servers = @($ServerAddresses)
            $a.Static = $true
        }

        # The TCP/IP interface key: NameServer holds the static list, empty for DNS from DHCP
        function global:Get-ItemProperty {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string[]]$Name)
            $p = @(@($LiteralPath) + @($Path) | Where-Object { $_ })[0]
            if ($p -like 'HKLM:*') {
                $global:DnsScenario.Reads += $p
                foreach ($a in $global:DnsScenario.Adapters) {
                    if ($p -ne ('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f $a.Guid)) { continue }
                    if ($a.NoKey) { return }
                    $ns = ''
                    if ($a.Static) { $ns = @($a.Servers) -join ',' }
                    return [pscustomobject]@{ NameServer = $ns; PSPath = $p }
                }
                return
            }
            Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
        }

        function global:whoami.exe {
            if ($global:DnsScenario.Elevated) { '"Mandatory Label\High Mandatory Level","Label","S-1-16-12288",""' }
            else { '"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192",""' }
            $global:LASTEXITCODE = 0
        }
    }
    Register-DnsMock

    function script:New-TestAdapter {
        param([string]$Name, [int]$Index, [string[]]$Servers = @(), [switch]$Dhcp, [string]$Status = 'Up', [switch]$NoKey,
              [switch]$NoIPv4, [switch]$DnsNotFound)
        return @{
            Name = $Name; Index = $Index; Guid = ('{{00000000-0000-0000-0000-{0:d12}}}' -f $Index)
            Status = $Status; Servers = @($Servers); Static = (-not $Dhcp); NoKey = [bool]$NoKey
            NoIPv4 = [bool]$NoIPv4; DnsNotFound = [bool]$DnsNotFound
        }
    }

    # Two static adapters, one DHCP adapter and the uplink of a Hyper-V switch (up, no IPv4); 192.0.2.53 is the server to add
    function script:Get-DefaultAdapter {
        return @(
            (New-TestAdapter 'SLOT 3 Port 1' 2 -NoIPv4)
            (New-TestAdapter 'Ethernet0'  4 @('198.51.100.10', '198.51.100.11'))
            (New-TestAdapter 'Ethernet1'  7 @('198.51.100.10', '192.0.2.53'))
            (New-TestAdapter 'vEthernet (Default Switch)' 12 @('203.0.113.1') -Dhcp)
        )
    }

    function script:Invoke-Scenario {
        param([object[]]$Adapters = (Get-DefaultAdapter), [hashtable]$Params = @{}, [hashtable]$Scenario = @{}, [string]$DnsServer = '192.0.2.53')
        $global:DnsScenario = @{
            Adapters = $Adapters; SetCalls = @(); Families = @(); Reads = @(); IpIfCalls = @()
            Elevated = $true; FailSet = ''; IgnoreSet = ''; DnsThrows = ''
        }
        foreach ($k in $Scenario.Keys) { $global:DnsScenario[$k] = $Scenario[$k] }

        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $output = & $script:Target -DnsServer $DnsServer @Params -OutputPath $out *>&1
        $code = $LASTEXITCODE

        $csv = Join-Path $out 'dns-servers.csv'
        $rows = @()
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        return [pscustomobject]@{
            ExitCode = $code; Rows = $rows; Out = $out
            Text     = (@($output | ForEach-Object { [string]$_ }) -join "`n")
            SetCalls = @($global:DnsScenario.SetCalls)
        }
    }

    function script:Get-Row {
        param($Result, [string]$Adapter)
        return @($Result.Rows | Where-Object { $_.Adapter -eq $Adapter })[0]
    }

    function script:Get-ServerText {
        param([string]$Adapter)
        return (@(@($global:DnsScenario.Adapters | Where-Object { $_.Name -eq $Adapter })[0].Servers) -join ',')
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'Get-NetAdapter', 'Get-NetIPInterface', 'Get-DnsClientServerAddress', 'Set-DnsClientServerAddress', 'Get-ItemProperty', 'whoami.exe') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name DnsScenario -Scope Global -ErrorAction SilentlyContinue
    foreach ($n in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
}

Describe 'Add-DnsServerToActiveAdapters' {

    Context 'Report only' {

        It 'server present on every static adapter: exit 0, position shown' {
            $adapters = @(
                (New-TestAdapter 'Ethernet0' 4 @('192.0.2.53', '198.51.100.11'))
                (New-TestAdapter 'Ethernet1' 7 @('198.51.100.10', '192.0.2.53'))
            )
            $r = Invoke-Scenario -Adapters $adapters
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'RESULT: 192\.0\.2\.53 IS ON EVERY ADAPTER IN SCOPE'
            (Get-Row $r 'Ethernet0').Status | Should -Be 'OK (position 1)'
            (Get-Row $r 'Ethernet1').Status | Should -Be 'OK (position 2)'
            (Get-Row $r 'Ethernet1').Source | Should -Be 'Static'
            ($r.Rows[0].PSObject.Properties.Name -join ',') | Should -Be 'Adapter,InterfaceIndex,Source,CurrentServers,Status,NewServers'
            $r.SetCalls.Count | Should -Be 0
            $global:DnsScenario.Families | Should -Not -Contain 'IPv6'
            $global:DnsScenario.Families | Should -Contain 'IPv4'
        }

        It 'missing on a static adapter: exit 1, new list shown, nothing changed' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 1
            $r.Text     | Should -Match 'RESULT: 192\.0\.2\.53 IS MISSING ON 1 ADAPTER'
            $row = Get-Row $r 'Ethernet0'
            $row.Status         | Should -Be 'MISSING'
            $row.CurrentServers | Should -Be '198.51.100.10, 198.51.100.11'
            $row.NewServers     | Should -Be '198.51.100.10, 198.51.100.11, 192.0.2.53'
            $r.Text | Should -Match 'Run again with -Fix'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'DNS from DHCP: SKIPPED-DHCP, does not change the exit code' {
            $adapters = @(
                (New-TestAdapter 'Ethernet1' 7 @('198.51.100.10', '192.0.2.53'))
                (New-TestAdapter 'Wi-Fi' 9 @('203.0.113.1') -Dhcp)
            )
            $r = Invoke-Scenario -Adapters $adapters
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'Wi-Fi').Status     | Should -Be 'SKIPPED-DHCP'
            (Get-Row $r 'Wi-Fi').Source     | Should -Be 'DHCP'
            (Get-Row $r 'Wi-Fi').NewServers | Should -BeNullOrEmpty
            $r.Text | Should -Match '1 adapter\(s\) get DNS from DHCP'
        }

        It 'DHCP adapter that already has the server: OK' {
            $r = Invoke-Scenario -Adapters @((New-TestAdapter 'Wi-Fi' 9 @('192.0.2.53') -Dhcp))
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'Wi-Fi').Status | Should -Be 'OK (position 1)'
        }

        It 'adapter without an interface key counts as DHCP' {
            $r = Invoke-Scenario -Adapters @((New-TestAdapter 'Ethernet0' 4 @('198.51.100.10') -NoKey))
            (Get-Row $r 'Ethernet0').Source | Should -Be 'DHCP'
            (Get-Row $r 'Ethernet0').Status | Should -Be 'SKIPPED-DHCP'
        }

        It '-IncludeDhcpAdapters: a DHCP adapter without the server is missing (exit 1)' {
            $r = Invoke-Scenario -Params @{ IncludeDhcpAdapters = $true }
            $r.ExitCode | Should -Be 1
            (Get-Row $r 'vEthernet (Default Switch)').Status     | Should -Be 'MISSING'
            (Get-Row $r 'vEthernet (Default Switch)').NewServers | Should -Be '203.0.113.1, 192.0.2.53'
        }

        It '-Position <Position> gives <Expected>' -ForEach @(
            @{ Position = 0; Expected = '198.51.100.10, 198.51.100.11, 192.0.2.53' }
            @{ Position = 1; Expected = '192.0.2.53, 198.51.100.10, 198.51.100.11' }
            @{ Position = 2; Expected = '198.51.100.10, 192.0.2.53, 198.51.100.11' }
            @{ Position = 3; Expected = '198.51.100.10, 198.51.100.11, 192.0.2.53' }
            @{ Position = 9; Expected = '198.51.100.10, 198.51.100.11, 192.0.2.53' }
        ) {
            $r = Invoke-Scenario -Params @{ Position = $Position }
            (Get-Row $r 'Ethernet0').NewServers | Should -Be $Expected
        }

        It 'static adapter with an empty list and -Position 1: the server alone' {
            $a = New-TestAdapter 'Ethernet9' 30
            $r = Invoke-Scenario -Adapters @($a) -Params @{ Position = 1; IncludeDhcpAdapters = $true }
            (Get-Row $r 'Ethernet9').CurrentServers | Should -Be '(none)'
            (Get-Row $r 'Ethernet9').NewServers     | Should -Be '192.0.2.53'
        }

        It '-InterfaceAlias filters the adapters (wildcards)' {
            $r = Invoke-Scenario -Params @{ InterfaceAlias = 'Ethernet*' }
            @($r.Rows | ForEach-Object Adapter) -join ',' | Should -Be 'Ethernet0,Ethernet1'

            $r = Invoke-Scenario -Params @{ InterfaceAlias = 'vEthernet*', 'Ethernet1' }
            @($r.Rows | ForEach-Object Adapter) -join ',' | Should -Be 'Ethernet1,vEthernet (Default Switch)'
            $r.ExitCode | Should -Be 0
        }

        It 'adapter that is up without IPv4 (Hyper-V switch uplink): NO-IPV4, not in scope' {
            $adapters = @(
                (New-TestAdapter 'SLOT 3 Port 1' 2 -NoIPv4)
                (New-TestAdapter 'Ethernet1' 7 @('192.0.2.53'))
            )
            $r = Invoke-Scenario -Adapters $adapters
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'SLOT 3 Port 1').Status         | Should -Be 'NO-IPV4'
            (Get-Row $r 'SLOT 3 Port 1').Source         | Should -Be 'N/A'
            (Get-Row $r 'SLOT 3 Port 1').CurrentServers | Should -Be '(no IPv4)'
            $r.Text | Should -Match '1 adapter\(s\) are up without IPv4'
            $global:DnsScenario.IpIfCalls | Should -Contain 'IPv4:2'
        }

        It 'IPv4 interface without DNS client settings (ObjectNotFound): NO-IPV4, not an error' {
            $adapters = @(
                (New-TestAdapter 'Storage1' 5 -DnsNotFound)
                (New-TestAdapter 'Ethernet1' 7 @('192.0.2.53'))
            )
            $r = Invoke-Scenario -Adapters $adapters
            $r.ExitCode | Should -Be 0
            (Get-Row $r 'Storage1').Status | Should -Be 'NO-IPV4'
        }

        It 'adapters that are not up are ignored' {
            $adapters = @(
                (New-TestAdapter 'Ethernet0' 4 @('198.51.100.10') -Status 'Disconnected')
                (New-TestAdapter 'Ethernet1' 7 @('192.0.2.53'))
            )
            $r = Invoke-Scenario -Adapters $adapters
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 1
        }

    }

    Context 'Cannot run (exit 3)' {

        It 'invalid -DnsServer <Value>' -ForEach @(
            @{ Value = 'dns01.example.com' }
            @{ Value = '192.0.2' }
            @{ Value = '192.0.2.300' }
            @{ Value = '2001:db8::53' }
            @{ Value = '192.0.2.053' }
        ) {
            $r = Invoke-Scenario -DnsServer $Value -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'is not an IPv4 address'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'negative -Position' {
            $r = Invoke-Scenario -Params @{ Position = -1 }
            $r.ExitCode | Should -Be 3
        }

        It 'not elevated with -Fix: nothing changed' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'Run as administrator'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'reading needs no elevation' {
            $r = Invoke-Scenario -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 1
        }

        It 'no adapter is up' {
            $r = Invoke-Scenario -Adapters @((New-TestAdapter 'Ethernet0' 4 @('198.51.100.10') -Status 'Disabled'))
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'No network adapter is up'
        }

        It 'every adapter that is up is without IPv4' {
            $r = Invoke-Scenario -Adapters @((New-TestAdapter 'SLOT 3 Port 1' 2 -NoIPv4), (New-TestAdapter 'SLOT 3 Port 2' 3 -NoIPv4))
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'No network adapter that is up has IPv4: SLOT 3 Port 1, SLOT 3 Port 2'
        }

        It '-InterfaceAlias matches nothing' {
            $r = Invoke-Scenario -Params @{ InterfaceAlias = 'Team*' }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'matches -InterfaceAlias Team\*'
        }

        It 'DnsClient cmdlets missing' {
            Remove-Item -LiteralPath 'Function:\Get-DnsClientServerAddress'
            try {
                $r = Invoke-Scenario
            } finally {
                Register-DnsMock
            }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'Get-DnsClientServerAddress is not available'
        }

        It 'unexpected error' {
            $r = Invoke-Scenario -Scenario @{ DnsThrows = 'Simulated failure' }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'ERROR: Simulated failure'
        }
    }

    Context '-Fix' {

        It 'adds the server to the static adapter that misses it, leaves the others' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 1
            $r.SetCalls[0].Index | Should -Be 4
            ($r.SetCalls[0].Servers -join ',') | Should -Be '198.51.100.10,198.51.100.11,192.0.2.53'
            Get-ServerText 'Ethernet0' | Should -Be '198.51.100.10,198.51.100.11,192.0.2.53'
            Get-ServerText 'vEthernet (Default Switch)' | Should -Be '203.0.113.1'
            (Get-Row $r 'Ethernet0').Status     | Should -Be 'ADDED'
            (Get-Row $r 'Ethernet0').NewServers | Should -Be '198.51.100.10, 198.51.100.11, 192.0.2.53'
            (Get-Row $r 'Ethernet1').Status     | Should -Be 'OK (position 2)'
            (Get-Row $r 'vEthernet (Default Switch)').Status | Should -Be 'SKIPPED-DHCP'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeTrue
        }

        It 'inserts at -Position 1' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; Position = 1 }
            $r.ExitCode | Should -Be 0
            Get-ServerText 'Ethernet0' | Should -Be '192.0.2.53,198.51.100.10,198.51.100.11'
        }

        It '-IncludeDhcpAdapters changes the DHCP adapter too, never an adapter without IPv4' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; IncludeDhcpAdapters = $true }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 2
            @($r.SetCalls | ForEach-Object Index) | Should -Not -Contain 2
            (Get-Row $r 'SLOT 3 Port 1').Status | Should -Be 'NO-IPV4'
            Get-ServerText 'vEthernet (Default Switch)' | Should -Be '203.0.113.1,192.0.2.53'
            (Get-Row $r 'vEthernet (Default Switch)').Status | Should -Be 'ADDED'
        }

        It 'never adds a server twice' {
            $adapters = @((New-TestAdapter 'Ethernet1' 7 @('198.51.100.10', '192.0.2.53')))
            $r = Invoke-Scenario -Adapters $adapters -Params @{ Fix = $true; Confirm = $false; Position = 1 }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 0
            $r.Text | Should -Match 'Nothing to change'
            Get-ServerText 'Ethernet1' | Should -Be '198.51.100.10,192.0.2.53'
        }

        It '-WhatIf: nothing changed, exit 1, no transcript' {
            $r = Invoke-Scenario -Params @{ Fix = $true; WhatIf = $true; IncludeDhcpAdapters = $true }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 0
            $r.Text | Should -Match 'WhatIf: nothing was changed'
            Get-ServerText 'Ethernet0' | Should -Be '198.51.100.10,198.51.100.11'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
            (Get-Row $r 'Ethernet0').Status | Should -Be 'MISSING'
        }

        It 'a change that fails: FAILED, exit 2, the other adapters are still changed' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; IncludeDhcpAdapters = $true } -Scenario @{ FailSet = 'Ethernet0' }
            $r.ExitCode | Should -Be 2
            (Get-Row $r 'Ethernet0').Status | Should -Be 'FAILED'
            (Get-Row $r 'vEthernet (Default Switch)').Status | Should -Be 'ADDED'
            $r.Text | Should -Match 'FAILED Ethernet0: Access is denied'
        }

        It 'a change that does not stick: FAILED, exit 2' {
            $r = Invoke-Scenario -Params $FixParams -Scenario @{ IgnoreSet = 'Ethernet0' }
            $r.ExitCode | Should -Be 2
            (Get-Row $r 'Ethernet0').Status | Should -Be 'FAILED'
            $r.Text | Should -Match 'is not in the list after the change'
        }
    }
}
