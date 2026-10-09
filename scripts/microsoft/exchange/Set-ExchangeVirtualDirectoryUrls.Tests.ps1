#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Set-ExchangeVirtualDirectoryUrls.ps1 - report, exit codes and -Fix changes against a mocked Exchange organization.

.DESCRIPTION
    The Exchange cmdlets (Get-ExchangeServer, the Get- and Set- virtual directory cmdlets, Outlook Anywhere,
    Client Access) and Add-PSSnapin are replaced by global functions backed by an in-memory scenario.
    No Exchange server is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Set-ExchangeVirtualDirectoryUrls.ps1'

    # Item key -> virtual directory name and URL path, as on a fresh Exchange server
    $global:ExUrlTestVdirs = @{
        OWA        = @('owa (Default Web Site)', '/owa')
        ECP        = @('ecp (Default Web Site)', '/ecp')
        EWS        = @('EWS (Default Web Site)', '/EWS/Exchange.asmx')
        MAPI       = @('mapi (Default Web Site)', '/mapi')
        ActiveSync = @('Microsoft-Server-ActiveSync (Default Web Site)', '/Microsoft-Server-ActiveSync')
        OAB        = @('OAB (Default Web Site)', '/OAB')
        PowerShell = @('PowerShell (Default Web Site)', '/powershell')
    }

    # ------------------------------------------------------------------ fake Exchange
    function global:Get-ExUrlTestObject {
        param([string]$Item, [string]$Cmdlet, $Server, $Identity, [bool]$ADPropertiesOnly)
        $t = $global:ExUrlTest
        if (-not $Server) { $Server = @([string]$Identity -split '\\')[0] }
        $Server = [string]$Server
        $t.GetCalls += [pscustomobject]@{ Cmdlet = $Cmdlet; Item = $Item; Server = $Server; ADPropertiesOnly = $ADPropertiesOnly }
        $key = '{0}|{1}' -f $Server.ToUpperInvariant(), $Item
        if ($t.FailGet -contains $key) { throw ('Active Directory read failed for {0}' -f $key) }
        foreach ($o in @($t.State[$key])) {
            if (-not $o) { continue }
            $out = [ordered]@{ Server = $Server; Name = $o.Name; Identity = ('{0}\{1}' -f $Server, $o.Name) }
            if ($Item -eq 'SCP') { $out.Identity = $Server }
            foreach ($k in $o.Keys) { if ($k -ne 'Name') { $out[$k] = $o[$k] } }
            [pscustomobject]$out
        }
    }

    function global:Set-ExUrlTestObject {
        param([string]$Item, [string]$Cmdlet, $Bound)
        $t = $global:ExUrlTest
        $identity = [string]$Bound['Identity']
        $values = [ordered]@{}
        foreach ($k in $Bound.Keys) {
            if ($k -notin 'Identity', 'Confirm', 'ErrorAction', 'WhatIf') { $values[$k] = $Bound[$k] }
        }
        $t.SetCalls += [pscustomobject]@{ Cmdlet = $Cmdlet; Item = $Item; Identity = $identity; Values = $values }
        $parts = @($identity -split '\\', 2)
        $key = '{0}|{1}' -f $parts[0].ToUpperInvariant(), $Item
        if ($t.FailSet -contains $key) { throw ('Active Directory operation failed on {0}' -f $key) }
        $name = $parts[-1]
        $o = @($t.State[$key] | Where-Object { $_.Name -eq $name })[0]
        if (-not $o) { throw ('The operation could not be performed because object {0} could not be found' -f $identity) }
        foreach ($k in $values.Keys) { $o[$k] = $values[$k] }
    }

    # (Re)defines every Exchange cmdlet. Tests remove some of them to simulate an older or missing shell.
    function global:Install-ExUrlTestStub {
        function global:Get-ExchangeServer {
            [CmdletBinding()] param([Parameter(Position = 0)]$Identity)
            if ($global:ExUrlTest.ServerError) { throw $global:ExUrlTest.ServerError }
            foreach ($s in $global:ExUrlTest.Servers) {
                [pscustomobject]@{
                    Name = $s.Name; Fqdn = ('{0}.contoso.com' -f $s.Name.ToLowerInvariant()); AdminDisplayVersion = $s.Version
                    IsClientAccessServer = $s.Cas; IsMailboxServer = $s.Mbx
                }
            }
        }
        function global:Get-ClientAccessService { [CmdletBinding()] param([Parameter(Position = 0)]$Identity) Get-ExUrlTestObject -Item SCP -Cmdlet $MyInvocation.MyCommand.Name -Identity $Identity }
        function global:Set-ClientAccessService { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Position = 0)]$Identity, $AutoDiscoverServiceInternalUri) Set-ExUrlTestObject -Item SCP -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Get-ClientAccessServer { [CmdletBinding()] param([Parameter(Position = 0)]$Identity) Get-ExUrlTestObject -Item SCP -Cmdlet $MyInvocation.MyCommand.Name -Identity $Identity }
        function global:Set-ClientAccessServer { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Position = 0)]$Identity, $AutoDiscoverServiceInternalUri) Set-ExUrlTestObject -Item SCP -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }

        function global:Get-OwaVirtualDirectory         { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item OWA        -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-EcpVirtualDirectory         { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item ECP        -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-WebServicesVirtualDirectory { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item EWS        -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-MapiVirtualDirectory        { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item MAPI       -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-ActiveSyncVirtualDirectory  { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item ActiveSync -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-OabVirtualDirectory         { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item OAB        -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-PowerShellVirtualDirectory  { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item PowerShell -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }
        function global:Get-OutlookAnywhere             { [CmdletBinding()] param($Server, $Identity, [switch]$ADPropertiesOnly) Get-ExUrlTestObject -Item OA         -Cmdlet $MyInvocation.MyCommand.Name -Server $Server -Identity $Identity -ADPropertiesOnly $ADPropertiesOnly }

        function global:Set-OwaVirtualDirectory         { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item OWA        -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-EcpVirtualDirectory         { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item ECP        -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-WebServicesVirtualDirectory { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item EWS        -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-MapiVirtualDirectory        { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item MAPI       -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-ActiveSyncVirtualDirectory  { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item ActiveSync -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-OabVirtualDirectory         { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item OAB        -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-PowerShellVirtualDirectory  { [CmdletBinding(SupportsShouldProcess)] param($Identity, $InternalUrl, $ExternalUrl) Set-ExUrlTestObject -Item PowerShell -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters }
        function global:Set-OutlookAnywhere {
            [CmdletBinding(SupportsShouldProcess)]
            param($Identity, $InternalHostname, $InternalClientsRequireSsl, $ExternalHostname, $ExternalClientsRequireSsl,
                $DefaultAuthenticationMethod, $InternalClientAuthenticationMethod, $ExternalClientAuthenticationMethod, $IISAuthenticationMethods)
            Set-ExUrlTestObject -Item OA -Cmdlet $MyInvocation.MyCommand.Name -Bound $PSBoundParameters
        }
    }

    # Loads the "snap-in" when the scenario allows it
    function global:Add-PSSnapin {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name)
        $global:ExUrlTest.SnapinCalls += , $Name
        if (-not $global:ExUrlTest.SnapinWorks) { throw ("The Windows PowerShell snap-in '{0}' is not installed on this computer." -f ($Name -join ',')) }
        Install-ExUrlTestStub
    }

    # ------------------------------------------------------------------ scenario helpers
    # Correct: every setting on the namespace. Fresh: as after setup (server FQDN inside, nothing outside).
    function script:Set-TestServerState {
        param([string]$Name, [switch]$Fresh)
        $fqdn = '{0}.contoso.com' -f $Name.ToLowerInvariant()
        $id = $Name.ToUpperInvariant()
        $t = $global:ExUrlTest
        foreach ($item in $global:ExUrlTestVdirs.Keys) {
            $v = $global:ExUrlTestVdirs[$item]
            if ($Fresh) {
                $int = 'https://{0}{1}' -f $fqdn, $v[1]
                if ($item -eq 'PowerShell') { $int = 'http://{0}/powershell' -f $fqdn }
                $t.State["$id|$item"] = @(@{ Name = $v[0]; InternalUrl = $int; ExternalUrl = $null })
            } else {
                $url = 'https://mail.contoso.com{0}' -f $v[1]
                $t.State["$id|$item"] = @(@{ Name = $v[0]; InternalUrl = $url; ExternalUrl = $url })
            }
        }
        if ($Fresh) {
            $t.State["$id|OA"] = @(@{ Name = 'Rpc (Default Web Site)'; InternalHostname = $fqdn; InternalClientsRequireSsl = $false
                ExternalHostname = $null; ExternalClientsRequireSsl = $false })
            $t.State["$id|SCP"] = @(@{ Name = $Name; AutoDiscoverServiceInternalUri = "https://$fqdn/Autodiscover/Autodiscover.xml" })
        } else {
            $t.State["$id|OA"] = @(@{ Name = 'Rpc (Default Web Site)'; InternalHostname = 'mail.contoso.com'; InternalClientsRequireSsl = $true
                ExternalHostname = 'mail.contoso.com'; ExternalClientsRequireSsl = $true })
            $t.State["$id|SCP"] = @(@{ Name = $Name; AutoDiscoverServiceInternalUri = 'https://autodiscover.contoso.com/Autodiscover/Autodiscover.xml' })
        }
    }

    function script:Get-TestValue {
        param([string]$Server, [string]$Item, [string]$Name)
        return @($global:ExUrlTest.State['{0}|{1}' -f $Server, $Item])[0][$Name]
    }

    $script:Exchange2019 = 'Version 15.2 (Build 1544.4)'

    function script:Invoke-Scenario {
        param(
            [string[]]$Servers = @('EX01'),
            [switch]$Fresh,
            [scriptblock]$Setup,
            [hashtable]$Params = @{},
            [string]$Script = $script:Target,
            [switch]$DefaultOutput
        )
        $global:ExUrlTest = @{
            Servers = @(); State = @{}; GetCalls = @(); SetCalls = @(); FailGet = @(); FailSet = @()
            SnapinCalls = @(); SnapinWorks = $false; ServerError = ''
        }
        Install-ExUrlTestStub
        foreach ($s in $Servers) {
            $global:ExUrlTest.Servers += @{ Name = $s; Version = $script:Exchange2019; Cas = $true; Mbx = $true }
            Set-TestServerState $s -Fresh:$Fresh
        }
        if ($Setup) { & $Setup }

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $run = @{ HostName = 'mail.contoso.com'; OutputPath = (Join-Path $root 'out'); LogPath = (Join-Path $root 'log') }
        if ($DefaultOutput) { $run = @{ HostName = 'mail.contoso.com' } }
        foreach ($k in $Params.Keys) { $run[$k] = $Params[$k] }
        $text = & $Script @run *>&1 | Out-String
        $code = $LASTEXITCODE

        $csv = Join-Path $root 'out/results.csv'
        $rows = @()
        if (Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        return [pscustomobject]@{
            ExitCode = $code; Text = $text; Rows = $rows; Root = $root
            Transcripts = @(Get-ChildItem -Path (Join-Path $root 'log') -Filter 'transcript-*.txt' -ErrorAction SilentlyContinue)
            GetCalls = @($global:ExUrlTest.GetCalls); SetCalls = @($global:ExUrlTest.SetCalls)
        }
    }

    # A copy of the script in its own TestDrive folder, to test the default output folder next to the script
    function script:Copy-TestScript {
        $dir = Join-Path $TestDrive ('copy-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        Copy-Item -LiteralPath $script:Target -Destination $dir
        return (Join-Path $dir (Split-Path -Leaf $script:Target))
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'Get-ExUrlTestObject', 'Set-ExUrlTestObject', 'Install-ExUrlTestStub', 'Add-PSSnapin', 'Get-ExchangeServer',
                   'Get-ClientAccessService', 'Set-ClientAccessService', 'Get-ClientAccessServer', 'Set-ClientAccessServer',
                   'Get-OwaVirtualDirectory', 'Get-EcpVirtualDirectory', 'Get-WebServicesVirtualDirectory', 'Get-MapiVirtualDirectory',
                   'Get-ActiveSyncVirtualDirectory', 'Get-OabVirtualDirectory', 'Get-PowerShellVirtualDirectory', 'Get-OutlookAnywhere',
                   'Set-OwaVirtualDirectory', 'Set-EcpVirtualDirectory', 'Set-WebServicesVirtualDirectory', 'Set-MapiVirtualDirectory',
                   'Set-ActiveSyncVirtualDirectory', 'Set-OabVirtualDirectory', 'Set-PowerShellVirtualDirectory', 'Set-OutlookAnywhere') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name ExUrlTest, ExUrlTestVdirs -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ExchangeVirtualDirectoryUrls' {

    Context 'Report only' {

        It 'every setting on the namespace: exit 0, all rows OK, nothing set' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 19
            @($r.Rows | Where-Object Status -ne 'OK').Count | Should -Be 0
            $r.SetCalls.Count | Should -Be 0
            $r.Text | Should -Not -Match 'certificate'
        }

        It 'fresh server: exit 1, every URL to change, nothing set' {
            $r = Invoke-Scenario -Fresh
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Status -eq 'CHANGE').Count | Should -Be 19
            $r.SetCalls.Count | Should -Be 0
            $owa = $r.Rows | Where-Object { $_.Item -eq 'OWA' -and $_.Setting -eq 'ExternalUrl' }
            $owa.Current  | Should -Be '(empty)'
            $owa.Expected | Should -Be 'https://mail.contoso.com/owa'
            $ps = $r.Rows | Where-Object { $_.Item -eq 'PowerShell' -and $_.Setting -eq 'InternalUrl' }
            $ps.Current | Should -Be 'http://ex01.contoso.com/powershell'
            $scp = $r.Rows | Where-Object Item -eq 'Autodiscover SCP'
            $scp.Expected | Should -Be 'https://autodiscover.contoso.com/Autodiscover/Autodiscover.xml'
            $r.Text | Should -Match 'Run again with -Fix'
            $r.Text | Should -Match 'certificate must include mail\.contoso\.com and autodiscover\.contoso\.com'
            $r.Transcripts.Count | Should -Be 0
        }

        It 'case and a trailing slash do not count as a difference' {
            $r = Invoke-Scenario -Setup {
                $o = @($global:ExUrlTest.State['EX01|OWA'])[0]
                $o.InternalUrl = 'https://MAIL.Contoso.com/OWA/'
                $a = @($global:ExUrlTest.State['EX01|OA'])[0]
                $a.ExternalHostname = 'Mail.Contoso.COM'
            }
            $r.ExitCode | Should -Be 0
        }

        It 'one different URL: only that row is CHANGE' {
            $r = Invoke-Scenario -Setup { @($global:ExUrlTest.State['EX01|EWS'])[0].ExternalUrl = 'https://webmail.example.com/EWS/Exchange.asmx' }
            $r.ExitCode | Should -Be 1
            $change = @($r.Rows | Where-Object Status -eq 'CHANGE')
            $change.Count | Should -Be 1
            $change[0].Item    | Should -Be 'EWS'
            $change[0].Setting | Should -Be 'ExternalUrl'
            $change[0].Current | Should -Be 'https://webmail.example.com/EWS/Exchange.asmx'
        }

        It 'Outlook Anywhere without SSL is reported' {
            $r = Invoke-Scenario -Setup { @($global:ExUrlTest.State['EX01|OA'])[0].ExternalClientsRequireSsl = $false }
            $r.ExitCode | Should -Be 1
            $row = $r.Rows | Where-Object { $_.Item -eq 'Outlook Anywhere' -and $_.Setting -eq 'ExternalClientsRequireSsl' }
            $row.Status  | Should -Be 'CHANGE'
            $row.Current | Should -Be 'False'
        }

        It 'reads the virtual directories from Active Directory only (-ADPropertiesOnly)' {
            $r = Invoke-Scenario
            $vdirCalls = @($r.GetCalls | Where-Object Item -ne 'SCP')
            $vdirCalls.Count | Should -Be 8
            @($vdirCalls | Where-Object { -not $_.ADPropertiesOnly }).Count | Should -Be 0
        }

        It 'a virtual directory that cannot be read: FAILED row and exit 2' {
            $r = Invoke-Scenario -Servers 'EX01', 'EX02' -Setup { $global:ExUrlTest.FailGet = @('EX02|MAPI') }
            $r.ExitCode | Should -Be 2
            $row = $r.Rows | Where-Object { $_.Server -eq 'EX02' -and $_.Item -eq 'MAPI' }
            $row.Status | Should -Be 'FAILED'
            $row.Detail | Should -Match 'Could not read'
            # The other items and servers are still checked: 19 rows on EX01, 17 on EX02
            @($r.Rows | Where-Object Status -eq 'OK').Count | Should -Be 36
        }

        It 'a missing virtual directory: FAILED row and exit 2' {
            $r = Invoke-Scenario -Setup { $global:ExUrlTest.State.Remove('EX01|OAB') }
            $r.ExitCode | Should -Be 2
            ($r.Rows | Where-Object Item -eq 'OAB').Detail | Should -Be 'Not found on this server'
        }

        It 'two OWA virtual directories on one server: both are reported by name' {
            $r = Invoke-Scenario -Setup {
                $global:ExUrlTest.State['EX01|OWA'] += @{ Name = 'owa (Second Site)'; InternalUrl = 'https://mail.contoso.com/owa'; ExternalUrl = $null }
            }
            $r.ExitCode | Should -Be 1
            $row = $r.Rows | Where-Object { $_.Item -eq 'OWA [owa (Second Site)]' -and $_.Setting -eq 'ExternalUrl' }
            $row.Status | Should -Be 'CHANGE'
            @($r.Rows | Where-Object Item -eq 'OWA [owa (Default Web Site)]').Count | Should -Be 2
        }
    }

    Context 'Names and servers' {

        It 'derives the Autodiscover name from HostName' {
            $r = Invoke-Scenario -Fresh -Params @{ HostName = 'webmail.mail.example.com' }
            ($r.Rows | Where-Object Item -eq 'Autodiscover SCP').Expected |
                Should -Be 'https://autodiscover.mail.example.com/Autodiscover/Autodiscover.xml'
            ($r.Rows | Where-Object { $_.Item -eq 'OWA' -and $_.Setting -eq 'InternalUrl' }).Expected |
                Should -Be 'https://webmail.mail.example.com/owa'
        }

        It 'uses -AutodiscoverHostName when given' {
            $r = Invoke-Scenario -Params @{ AutodiscoverHostName = 'autodiscover.example.com' }
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Item -eq 'Autodiscover SCP').Expected |
                Should -Be 'https://autodiscover.example.com/Autodiscover/Autodiscover.xml'
        }

        It 'SCP on HostName itself: OK when -AutodiscoverHostName is not given, nothing set' {
            $setup = { @($global:ExUrlTest.State['EX01|SCP'])[0].AutoDiscoverServiceInternalUri = 'https://mail.contoso.com/Autodiscover/Autodiscover.xml' }
            $r = Invoke-Scenario -Setup $setup
            $r.ExitCode | Should -Be 0
            $scp = $r.Rows | Where-Object Item -eq 'Autodiscover SCP'
            $scp.Status   | Should -Be 'OK'
            $scp.Expected | Should -Be 'https://mail.contoso.com/Autodiscover/Autodiscover.xml'
            $r = Invoke-Scenario -Setup $setup -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 0
        }

        It 'SCP on HostName itself with -AutodiscoverHostName: CHANGE, and -Fix sets the given name' {
            $setup = { @($global:ExUrlTest.State['EX01|SCP'])[0].AutoDiscoverServiceInternalUri = 'https://mail.contoso.com/Autodiscover/Autodiscover.xml' }
            $r = Invoke-Scenario -Setup $setup -Params @{ AutodiscoverHostName = 'autodiscover.contoso.com' }
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Item -eq 'Autodiscover SCP').Status | Should -Be 'CHANGE'
            $r = Invoke-Scenario -Setup $setup -Params @{ AutodiscoverHostName = 'autodiscover.contoso.com'; Fix = $true; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Get-TestValue 'EX01' 'SCP' 'AutoDiscoverServiceInternalUri' | Should -Be 'https://autodiscover.contoso.com/Autodiscover/Autodiscover.xml'
        }

        It '-AutodiscoverHostName equal to HostName: only that name is OK' {
            $r = Invoke-Scenario -Params @{ AutodiscoverHostName = 'mail.contoso.com' }
            $r.ExitCode | Should -Be 1
            $scp = $r.Rows | Where-Object Item -eq 'Autodiscover SCP'
            $scp.Status   | Should -Be 'CHANGE'
            $scp.Expected | Should -Be 'https://mail.contoso.com/Autodiscover/Autodiscover.xml'
        }

        It 'any other SCP: set to the default Autodiscover name' {
            $r = Invoke-Scenario -Params $FixParams -Setup {
                @($global:ExUrlTest.State['EX01|SCP'])[0].AutoDiscoverServiceInternalUri = 'https://ex01.contoso.com/Autodiscover/Autodiscover.xml'
            }
            $r.ExitCode | Should -Be 0
            Get-TestValue 'EX01' 'SCP' 'AutoDiscoverServiceInternalUri' | Should -Be 'https://autodiscover.contoso.com/Autodiscover/Autodiscover.xml'
        }

        It 'HostName with two labels and no -AutodiscoverHostName: exit 3' {
            $r = Invoke-Scenario -Params @{ HostName = 'contoso.com' }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'Use -AutodiscoverHostName'
            $r.GetCalls.Count | Should -Be 0
        }

        It 'default servers: skips Exchange 2010, Edge Transport and an Exchange 2013 Mailbox-only server' {
            $r = Invoke-Scenario -Servers 'EX01' -Setup {
                $global:ExUrlTest.Servers += @{ Name = 'EX2010'; Version = 'Version 14.3 (Build 123.4)'; Cas = $true; Mbx = $true }
                $global:ExUrlTest.Servers += @{ Name = 'EDGE01'; Version = $script:Exchange2019; Cas = $false; Mbx = $false }
                $global:ExUrlTest.Servers += @{ Name = 'MBX2013'; Version = 'Version 15.0 (Build 1497.2)'; Cas = $false; Mbx = $true }
                $global:ExUrlTest.Servers += @{ Name = 'CAS2013'; Version = 'Version 15.0 (Build 1497.2)'; Cas = $true; Mbx = $false }
                $global:ExUrlTest.Servers += @{ Name = 'EX2016'; Version = 'Version 15.1 (Build 2507.6)'; Cas = $false; Mbx = $true }
                Set-TestServerState 'CAS2013'
                Set-TestServerState 'EX2016'
            }
            $r.ExitCode | Should -Be 0
            @($r.Rows | Select-Object -ExpandProperty Server -Unique) | Should -Be @('EX01', 'CAS2013', 'EX2016')
            $r.Text | Should -Match 'EX2010 \(older than Exchange 2013\)'
            $r.Text | Should -Match 'EDGE01 \(no Client Access or Mailbox role'
            $r.Text | Should -Match 'MBX2013 \(Exchange 2013 without the Client Access role\)'
        }

        It '-Server limits the check to the given servers (name or FQDN)' {
            $r = Invoke-Scenario -Servers 'EX01', 'EX02', 'EX03' -Params @{ Server = @('ex02.contoso.com') }
            $r.ExitCode | Should -Be 0
            @($r.Rows | Select-Object -ExpandProperty Server -Unique) | Should -Be @('EX02')
        }

        It '-Server that is not an Exchange server: exit 3' {
            $r = Invoke-Scenario -Params @{ Server = @('SRV01') }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'SRV01 is not an Exchange server'
        }

        It '-Server that cannot be checked (Exchange 2010): exit 3' {
            $r = Invoke-Scenario -Setup { $global:ExUrlTest.Servers += @{ Name = 'EX2010'; Version = 'Version 14.3 (Build 123.4)'; Cas = $true; Mbx = $true } } -Params @{ Server = @('EX2010') }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'EX2010 cannot be checked: older than Exchange 2013'
        }
    }

    Context 'Cannot run (exit 3)' {

        It 'no Exchange cmdlets and no snap-in' {
            $r = Invoke-Scenario -Setup { Remove-Item -LiteralPath 'Function:\Get-ExchangeServer' }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'Run the script in the Exchange Management Shell'
            $global:ExUrlTest.SnapinCalls.Count | Should -Be 1
            $global:ExUrlTest.SnapinCalls[0] | Should -Be 'Microsoft.Exchange.Management.PowerShell.SnapIn'
        }

        It 'no Exchange cmdlets: loads the snap-in and runs' {
            $r = Invoke-Scenario -Setup { Remove-Item -LiteralPath 'Function:\Get-ExchangeServer'; $global:ExUrlTest.SnapinWorks = $true }
            $r.ExitCode | Should -Be 0
            $global:ExUrlTest.SnapinCalls.Count | Should -Be 1
            $r.Rows.Count | Should -Be 19
        }

        It 'the snap-in is not loaded when the cmdlets are there' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 0
            $global:ExUrlTest.SnapinCalls.Count | Should -Be 0
        }

        It 'no server with the Client Access or Mailbox role' {
            $r = Invoke-Scenario -Servers @() -Setup {
                $global:ExUrlTest.Servers += @{ Name = 'EDGE01'; Version = $script:Exchange2019; Cas = $false; Mbx = $false }
            }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'No Exchange 2013 or later server'
        }

        It 'unexpected error' {
            $r = Invoke-Scenario -Setup { $global:ExUrlTest.ServerError = 'Active Directory server is not available.' }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'ERROR: Active Directory server is not available'
        }
    }

    Context '-Fix' {

        It 'fresh server: sets every item and writes a transcript' {
            $r = Invoke-Scenario -Fresh -Params $FixParams
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Status -eq 'SET').Count | Should -Be 19
            $r.SetCalls.Count | Should -Be 9
            $r.Transcripts.Count | Should -Be 1

            foreach ($item in $global:ExUrlTestVdirs.Keys) {
                $url = 'https://mail.contoso.com{0}' -f $global:ExUrlTestVdirs[$item][1]
                Get-TestValue 'EX01' $item 'InternalUrl' | Should -Be $url
                Get-TestValue 'EX01' $item 'ExternalUrl' | Should -Be $url
            }
            $owa = $r.SetCalls | Where-Object Item -eq 'OWA'
            $owa.Cmdlet   | Should -Be 'Set-OwaVirtualDirectory'
            $owa.Identity | Should -Be 'EX01\owa (Default Web Site)'
            @($owa.Values.Keys | Sort-Object) | Should -Be @('ExternalUrl', 'InternalUrl')

            Get-TestValue 'EX01' 'SCP' 'AutoDiscoverServiceInternalUri' | Should -Be 'https://autodiscover.contoso.com/Autodiscover/Autodiscover.xml'
            ($r.SetCalls | Where-Object Item -eq 'SCP').Cmdlet | Should -Be 'Set-ClientAccessService'
            Get-TestValue 'EX01' 'OA' 'InternalHostname' | Should -Be 'mail.contoso.com'
            Get-TestValue 'EX01' 'OA' 'ExternalHostname' | Should -Be 'mail.contoso.com'
            Get-TestValue 'EX01' 'OA' 'InternalClientsRequireSsl' | Should -BeTrue
            Get-TestValue 'EX01' 'OA' 'ExternalClientsRequireSsl' | Should -BeTrue
            $r.Text | Should -Match 'pick up the new URLs through Autodiscover'
        }

        It 'Outlook Anywhere: sets the host name and SSL of one side together, never the authentication' {
            $r = Invoke-Scenario -Params $FixParams -Setup { @($global:ExUrlTest.State['EX01|OA'])[0].ExternalClientsRequireSsl = $false }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 1
            $r.SetCalls[0].Cmdlet | Should -Be 'Set-OutlookAnywhere'
            @($r.SetCalls[0].Values.Keys | Sort-Object) | Should -Be @('ExternalClientsRequireSsl', 'ExternalHostname')
            $r.SetCalls[0].Values['ExternalClientsRequireSsl'] | Should -BeTrue
            ($r.Rows | Where-Object Setting -eq 'ExternalClientsRequireSsl').Status | Should -Be 'SET'
            ($r.Rows | Where-Object Setting -eq 'ExternalHostname').Status | Should -Be 'OK'
        }

        It 'sets only the URL that differs' {
            $r = Invoke-Scenario -Params $FixParams -Setup { @($global:ExUrlTest.State['EX01|ECP'])[0].InternalUrl = 'https://ex01.contoso.com/ecp' }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 1
            $r.SetCalls[0].Cmdlet | Should -Be 'Set-EcpVirtualDirectory'
            @($r.SetCalls[0].Values.Keys) | Should -Be @('InternalUrl')
        }

        It 'Exchange 2013 shell: uses Set-ClientAccessServer' {
            $r = Invoke-Scenario -Fresh -Params $FixParams -Setup {
                Remove-Item -LiteralPath 'Function:\Get-ClientAccessService'
                Remove-Item -LiteralPath 'Function:\Set-ClientAccessService'
            }
            $r.ExitCode | Should -Be 0
            ($r.SetCalls | Where-Object Item -eq 'SCP').Cmdlet | Should -Be 'Set-ClientAccessServer'
            ($r.GetCalls | Where-Object Item -eq 'SCP').Cmdlet | Should -Be 'Get-ClientAccessServer'
        }

        It '-WhatIf changes nothing' {
            $r = Invoke-Scenario -Fresh -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 0
            @($r.Rows | Where-Object Status -eq 'CHANGE').Count | Should -Be 19
            $r.Text | Should -Match 'WhatIf: nothing was changed'
            $r.Transcripts.Count | Should -Be 0
            Get-TestValue 'EX01' 'OWA' 'ExternalUrl' | Should -BeNullOrEmpty
        }

        It 'nothing to change: no Set calls' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 0
        }

        It 'a change that fails: FAILED row, the other items are still set, exit 2' {
            $r = Invoke-Scenario -Fresh -Servers 'EX01', 'EX02' -Params $FixParams -Setup { $global:ExUrlTest.FailSet = @('EX01|OAB') }
            $r.ExitCode | Should -Be 2
            $failed = @($r.Rows | Where-Object Status -eq 'FAILED')
            $failed.Count | Should -Be 2
            $failed[0].Item   | Should -Be 'OAB'
            $failed[0].Detail | Should -Match 'Active Directory operation failed'
            @($r.Rows | Where-Object Status -eq 'SET').Count | Should -Be 36
            $r.SetCalls.Count | Should -Be 18
        }
    }

    Context 'Default output folder' {

        It 'without -OutputPath and -LogPath: report and transcript in InfraToolkit-Output next to the script' {
            $copy = Copy-TestScript
            $base = Join-Path (Join-Path (Split-Path -Parent $copy) 'InfraToolkit-Output') 'Set-ExchangeVirtualDirectoryUrls'
            $r = Invoke-Scenario -Fresh -Script $copy -DefaultOutput -Params $FixParams
            $r.ExitCode | Should -Be 0
            $stamps = @(Get-ChildItem -LiteralPath $base -Directory)
            $stamps.Count   | Should -Be 1
            $stamps[0].Name | Should -Match '^\d{8}-\d{6}$'
            $csv = Join-Path $stamps[0].FullName 'results.csv'
            @(Import-Csv -LiteralPath $csv).Count | Should -Be 19
            $transcripts = @(Get-ChildItem -LiteralPath $base -Filter 'transcript-*.txt')
            $transcripts.Count | Should -Be 1
            $r.Text | Should -Match ([regex]::Escape($csv))
            $r.Text | Should -Match ([regex]::Escape($transcripts[0].FullName))

            # -WhatIf: the report is still saved, no transcript
            $copy = Copy-TestScript
            $base = Join-Path (Join-Path (Split-Path -Parent $copy) 'InfraToolkit-Output') 'Set-ExchangeVirtualDirectoryUrls'
            $r = Invoke-Scenario -Fresh -Script $copy -DefaultOutput -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $base -Filter 'results.csv' -Recurse).Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $base -Filter 'transcript-*.txt').Count | Should -Be 0
        }
    }
}
