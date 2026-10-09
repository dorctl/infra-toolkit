#Requires -Version 5.1

<#
.SYNOPSIS
    Reports the DNS servers of every active network adapter and adds a DNS server where it is missing (-Fix).

.DESCRIPTION
    For every network adapter that is up (physical and virtual, like vEthernet or VPN adapters), the
    script reads the IPv4 DNS server list (Get-DnsClientServerAddress) and checks whether -DnsServer
    is in it, and at which position.

    The source of the list comes from the TCP/IP settings of the adapter:
    HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\<InterfaceGuid>, value NameServer.
      Static  NameServer is set: the DNS servers were configured on the adapter.
      DHCP    NameServer is empty: the DNS servers come from DHCP (or the adapter has none).
    Adapters with DNS from DHCP are reported as SKIPPED-DHCP and are not changed: add the server to
    the DHCP scope options instead. With -IncludeDhcpAdapters they are changed too, but setting a
    list on such an adapter turns the DHCP list into a static list, which no longer follows DHCP.

    Adapters that are up without IPv4 (the physical adapter behind an external Hyper-V switch, team
    members, storage adapters with IPv4 unbound) have no DNS settings. They are reported as NO-IPV4,
    are not changed and do not count for the exit code.

    Without -Fix the script only reports. With -Fix it sets the DNS server list of each adapter where
    the server is missing: the current list with -DnsServer inserted at -Position (or appended), in
    the same order otherwise. A server that is already in the list is never added again or moved.
    -WhatIf shows the changes without making them. Every run with -Fix writes a transcript.

    Requirements: Windows 8 / Windows Server 2012 or later (NetAdapter, NetTCPIP and DnsClient modules).
    Reading needs no administrator rights. -Fix needs an elevated session.

.PARAMETER DnsServer
    IPv4 address of the DNS server to add, for example 192.0.2.53.

.PARAMETER Position
    Place of the server in the list, 1 = first. Default 0: append at the end.
    A position after the end of the list also appends.

.PARAMETER InterfaceAlias
    Only these adapters (names as in Get-NetAdapter, wildcards allowed). Default: every adapter that is up.

.PARAMETER IncludeDhcpAdapters
    Also change adapters that get their DNS servers from DHCP. Their list becomes static.

.PARAMETER Fix
    Set the new DNS server lists. Without it the script is read-only.

.PARAMETER OutputPath
    Folder for the CSV report and the transcript.
    Default: InfraToolkit-Output\Add-DnsServerToActiveAdapters\<timestamp> in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Add-DnsServerToActiveAdapters\<timestamp> when that folder cannot be
    written or is in OneDrive).

.EXAMPLE
    .\Add-DnsServerToActiveAdapters.ps1 -DnsServer 192.0.2.53
    Report where 192.0.2.53 is missing.

.EXAMPLE
    .\Add-DnsServerToActiveAdapters.ps1 -DnsServer 192.0.2.53 -Fix -WhatIf
    Show the new lists without changing them.

.EXAMPLE
    .\Add-DnsServerToActiveAdapters.ps1 -DnsServer 192.0.2.53 -Position 2 -InterfaceAlias 'Ethernet*' -Fix
    Insert 192.0.2.53 as the second DNS server on the Ethernet adapters. Asks before each adapter;
    add -Confirm:$false to skip.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = the server is on every adapter in scope (or was added), 1 = missing on an adapter,
                2 = some changes failed, 3 = the script could not run.
    Adapters skipped as DHCP or without IPv4 are out of scope and do not change the exit code.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$DnsServer,

    [int]$Position = 0,

    [string[]]$InterfaceAlias,

    [switch]$IncludeDhcpAdapters,

    [switch]$Fix,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$InterfacesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_FAILED  = 2
$EXIT_NOT_RUN = 3

$script:ExitCode = $EXIT_NOT_RUN

# ------------------------------------------------------------------ helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Get-OutputFolder {
    # Default output folder: InfraToolkit-Output\<script name> next to the script file.
    # Falls back to %TEMP%\InfraToolkit-Output\<script name> when the script was not run from a file,
    # when its folder is inside OneDrive (outputs must not be synced), or when that folder cannot be written.
    # Its write test always runs, also under -WhatIf and -Confirm.
    param([string]$ScriptRoot, [string]$ScriptName)

    $candidates = @()
    if ($ScriptRoot) {
        $root = $ScriptRoot.TrimEnd('\', '/').ToLowerInvariant()
        $synced = $false
        foreach ($s in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
            if (-not $s) { continue }
            $sync = $s.TrimEnd('\', '/').ToLowerInvariant()
            if ($root -eq $sync -or $root.StartsWith($sync + '\') -or $root.StartsWith($sync + '/')) { $synced = $true }
        }
        if ($synced) {
            Write-Warning ('The script folder is inside OneDrive. Output goes to the TEMP folder instead: {0}' -f $ScriptRoot)
        } else {
            $candidates += Join-Path (Join-Path $ScriptRoot 'InfraToolkit-Output') $ScriptName
        }
    }
    $temp = $env:TEMP
    if (-not $temp) { $temp = $env:TMPDIR }
    if (-not $temp) { $temp = '/tmp' }
    $candidates += Join-Path (Join-Path $temp 'InfraToolkit-Output') $ScriptName

    foreach ($c in $candidates) {
        try {
            New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false | Out-Null
            $probe = Join-Path $c ('.write-test-{0}' -f (Get-Random))
            Set-Content -LiteralPath $probe -Value '' -ErrorAction Stop -WhatIf:$false -Confirm:$false
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
            return $c
        } catch {
            Write-Verbose ('Cannot write to {0}: {1}' -f $c, $_.Exception.Message)
        }
    }
    throw ('No writable output folder. Tried: {0}. Give a folder with the output path parameter of the script.' -f ($candidates -join '; '))
}

function ConvertTo-Ipv4Text {
    # Dotted decimal IPv4 address -> text, '' when the text is not one. [ipaddress] alone accepts "1" and
    # "192.0.2", and reads an octet with a leading zero as octal (192.0.2.053 = 192.0.2.43): both are refused.
    param([string]$Text)
    $t = ([string]$Text).Trim()
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if ($t -notmatch ('^{0}(\.{0}){{3}}$' -f $octet)) { return '' }
    $ip = $t -as [ipaddress]
    if (-not $ip -or [string]$ip.AddressFamily -ne 'InterNetwork') { return '' }
    return $ip.IPAddressToString
}

function Join-ServerList {
    param($Servers)
    $s = @($Servers)
    if ($s.Count -eq 0) { return '(none)' }
    return ($s -join ', ')
}

function Test-Elevated {
    # High (S-1-16-12288) or System (S-1-16-16384) integrity level = elevated
    $ErrorActionPreference = 'Continue'
    $groups = @(& whoami.exe /groups /fo csv /nh 2>$null)
    return (@($groups -match 'S-1-16-(12288|16384)').Count -gt 0)
}

# ------------------------------------------------------------------ adapters
function Get-AdapterIndex {
    param($Adapter)
    if ($null -ne $Adapter.InterfaceIndex) { return [int]$Adapter.InterfaceIndex }
    return [int]$Adapter.ifIndex
}

function Get-AdapterName {
    param($Adapter)
    if ($Adapter.Name) { return [string]$Adapter.Name }
    return [string]$Adapter.InterfaceAlias
}

function Get-ActiveAdapter {
    $adapters = @(Get-NetAdapter | Where-Object { [string]$_.Status -eq 'Up' })
    if ($InterfaceAlias) {
        $adapters = @($adapters | Where-Object {
            $name = Get-AdapterName $_
            @($InterfaceAlias | Where-Object { $name -like $_ }).Count -gt 0
        })
    }
    return @($adapters | Sort-Object { Get-AdapterIndex $_ })
}

function Test-Ipv4Interface {
    # False for an adapter that is up without IPv4 (Hyper-V switch uplink, team member, IPv4 unbound)
    param([int]$Index)
    return (@(Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $Index -ErrorAction SilentlyContinue).Count -gt 0)
}

function Get-DnsServerList {
    # Found = $false when the interface has no IPv4 DNS client settings (ObjectNotFound)
    param([int]$Index)
    try {
        $entries = @(Get-DnsClientServerAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction Stop)
    } catch {
        if ([string]$_.CategoryInfo.Category -eq 'ObjectNotFound') { return [pscustomobject]@{ Found = $false; Servers = @() } }
        throw
    }
    $servers = @($entries | ForEach-Object { @($_.ServerAddresses) } | Where-Object { $_ } | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Found = $true; Servers = $servers }
}

function Get-DnsSource {
    # NameServer set on the interface = static DNS servers, empty = DNS servers from DHCP (or none)
    param([string]$InterfaceGuid)
    $item = Get-ItemProperty -LiteralPath ('{0}\{1}' -f $InterfacesKey, $InterfaceGuid) -Name NameServer -ErrorAction SilentlyContinue
    if ($item -and ([string]$item.NameServer).Trim()) { return 'Static' }
    return 'DHCP'
}

function Get-NewServerList {
    param([string[]]$Current, [string]$Server, [int]$At)
    $list = @($Current | Where-Object { $_ })
    if ($At -le 0 -or $At -gt $list.Count) { return @($list + $Server) }
    $head = @()
    if ($At -gt 1) { $head = @($list[0..($At - 2)]) }
    $tail = @($list[($At - 1)..($list.Count - 1)])
    return @($head + $Server + $tail)
}

function Get-AdapterState {
    param($Adapter, [string]$Server)
    $index = Get-AdapterIndex $Adapter
    $noIpv4 = [pscustomobject]@{
        Adapter = (Get-AdapterName $Adapter); InterfaceIndex = $index; Source = 'N/A'
        CurrentServers = '(no IPv4)'; Status = 'NO-IPV4'; NewServers = ''; NewList = @()
    }
    if (-not (Test-Ipv4Interface $index)) { return $noIpv4 }
    $dns = Get-DnsServerList $index
    if (-not $dns.Found) { return $noIpv4 }
    $servers = @($dns.Servers)
    $source = Get-DnsSource ([string]$Adapter.InterfaceGuid)
    $pos = 0
    for ($i = 0; $i -lt $servers.Count; $i++) { if ($servers[$i] -eq $Server) { $pos = $i + 1; break } }
    $status = 'MISSING'
    $new = @()
    if ($pos -gt 0) { $status = 'OK (position {0})' -f $pos }
    elseif ($source -eq 'DHCP' -and -not $IncludeDhcpAdapters) { $status = 'SKIPPED-DHCP' }
    else { $new = @(Get-NewServerList -Current $servers -Server $Server -At $Position) }
    return [pscustomobject]@{
        Adapter = (Get-AdapterName $Adapter); InterfaceIndex = $index; Source = $source
        CurrentServers = (Join-ServerList $servers); Status = $status; NewServers = ''
        NewList = $new
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to change)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is changed)' }
    elseif ($Fix) { $modeText = '-Fix' }

    Out-Line 'DNS server on active network adapters' 'White'
    Out-Line (' Computer   : {0}' -f $env:COMPUTERNAME)
    Out-Line (' Mode       : {0}' -f $modeText)

    $server = ConvertTo-Ipv4Text $DnsServer
    if (-not $server) {
        Out-Line ('-DnsServer {0} is not an IPv4 address (example: 192.0.2.53).' -f $DnsServer) 'Red'
        return $EXIT_NOT_RUN
    }
    if ($Position -lt 0) {
        Out-Line ('-Position {0}: use 1 for the first place, 2 for the second ..., or 0 to append.' -f $Position) 'Red'
        return $EXIT_NOT_RUN
    }
    $where = 'appended at the end'
    if ($Position -gt 0) { $where = 'inserted at position {0}' -f $Position }
    Out-Line (' DNS server : {0} ({1} where missing)' -f $server, $where)
    if ($InterfaceAlias) { Out-Line (' Adapters   : {0}' -f ($InterfaceAlias -join ', ')) }
    if ($IncludeDhcpAdapters) { Out-Line ' DHCP       : adapters with DNS from DHCP are included (their list becomes static)' }

    foreach ($cmd in 'Get-NetAdapter', 'Get-NetIPInterface', 'Get-DnsClientServerAddress', 'Set-DnsClientServerAddress') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Out-Line ('{0} is not available. This script needs Windows 8 / Windows Server 2012 or later.' -f $cmd) 'Red'
            return $EXIT_NOT_RUN
        }
    }
    if ($Fix -and -not (Test-Elevated)) {
        Out-Line '-Fix needs an elevated PowerShell (Run as administrator). Nothing was changed.' 'Red'
        return $EXIT_NOT_RUN
    }

    $adapters = @(Get-ActiveAdapter)
    if ($adapters.Count -eq 0) {
        $text = 'No network adapter is up.'
        if ($InterfaceAlias) { $text = 'No network adapter that is up matches -InterfaceAlias {0}.' -f ($InterfaceAlias -join ', ') }
        Out-Line $text 'Red'
        return $EXIT_NOT_RUN
    }

    $rows = @(foreach ($a in $adapters) { Get-AdapterState -Adapter $a -Server $server })
    if (@($rows | Where-Object { $_.Status -ne 'NO-IPV4' }).Count -eq 0) {
        Out-Line ('No network adapter that is up has IPv4: {0}.' -f (@($rows | ForEach-Object { $_.Adapter }) -join ', ')) 'Red'
        return $EXIT_NOT_RUN
    }
    foreach ($r in $rows) { if ($r.Status -eq 'MISSING') { $r.NewServers = Join-ServerList $r.NewList } }

    $toFix = @($rows | Where-Object { $_.Status -eq 'MISSING' })
    if ($Fix -and $toFix.Count -gt 0) {
        Out-Line ''
        Out-Line 'Changes' 'White'
        foreach ($r in $toFix) {
            $target = '{0} (interface index {1})' -f $r.Adapter, $r.InterfaceIndex
            if (-not $Cmdlet.ShouldProcess($target, ('Set the DNS servers to {0}' -f $r.NewServers))) { continue }
            try {
                Set-DnsClientServerAddress -InterfaceIndex $r.InterfaceIndex -ServerAddresses $r.NewList -Confirm:$false -ErrorAction Stop
                $now = @((Get-DnsServerList $r.InterfaceIndex).Servers)
                $r.NewServers = Join-ServerList $now
                if ($now -contains $server) {
                    $r.Status = 'ADDED'
                    Out-Line ('  {0}: DNS servers set to {1}' -f $r.Adapter, $r.NewServers)
                } else {
                    $r.Status = 'FAILED'
                    Out-Line ('  FAILED {0}: {1} is not in the list after the change ({2})' -f $r.Adapter, $server, $r.NewServers) 'Red'
                }
            } catch {
                $r.Status = 'FAILED'
                Out-Line ('  FAILED {0}: {1}' -f $r.Adapter, $_.Exception.Message) 'Red'
            }
        }
        if ($WhatIfPreference) { Out-Line 'WhatIf: nothing was changed.' 'Yellow' }
    } elseif ($Fix) {
        Out-Line ''
        Out-Line 'Nothing to change.' 'Green'
    }

    $report = @($rows | Select-Object Adapter, InterfaceIndex, Source, CurrentServers, Status, NewServers)
    Out-Line ''
    Out-Line (($report | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
    $csv = Join-Path $OutputPath 'dns-servers.csv'
    $report | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false

    $missing = @($rows | Where-Object { $_.Status -eq 'MISSING' }).Count
    $failed  = @($rows | Where-Object { $_.Status -eq 'FAILED' }).Count
    $dhcp    = @($rows | Where-Object { $_.Status -eq 'SKIPPED-DHCP' }).Count
    $noIp    = @($rows | Where-Object { $_.Status -eq 'NO-IPV4' }).Count
    $code = $EXIT_OK
    if ($missing -gt 0) { $code = $EXIT_ACTION }
    if ($failed -gt 0) { $code = $EXIT_FAILED }

    Out-Line ''
    switch ($code) {
        0 { Out-Line ('RESULT: {0} IS ON EVERY ADAPTER IN SCOPE' -f $server) 'Green' }
        1 { Out-Line ('RESULT: {0} IS MISSING ON {1} ADAPTER(S)' -f $server, $missing) 'Red' }
        2 { Out-Line ('RESULT: {0} CHANGE(S) FAILED' -f $failed) 'Red' }
    }
    if ($dhcp -gt 0) {
        Out-Line ('{0} adapter(s) get DNS from DHCP and were skipped: add the server to the DHCP scope options, or use -IncludeDhcpAdapters (their list becomes static).' -f $dhcp) 'Yellow'
    }
    if ($noIp -gt 0) {
        Out-Line ('{0} adapter(s) are up without IPv4 (Hyper-V switch uplink, team member ...) and were skipped.' -f $noIp) 'DarkGray'
    }
    if ($code -eq $EXIT_ACTION) {
        if ($Fix -and $WhatIfPreference) { Out-Line 'Run again with -Fix and without -WhatIf to apply the changes.' }
        elseif (-not $Fix) { Out-Line 'Run again with -Fix to add the server.' }
    }
    Out-Line ('Report: {0}' -f $csv) 'Cyan'
    return $code
}

$transcript = $null
try {
    if (-not $OutputPath) {
        # The helper creates and test-writes the folder: run it without -WhatIf and -Confirm, or a
        # -WhatIf run would find no writable folder
        $OutputPath = & {
            param([string]$Root)
            $WhatIfPreference = $false
            $ConfirmPreference = 'None'
            Get-OutputFolder -ScriptRoot $Root -ScriptName 'Add-DnsServerToActiveAdapters'
        } $PSScriptRoot
        $OutputPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null
    if ($Fix -and -not $WhatIfPreference) {
        $transcript = Join-Path $OutputPath 'transcript.txt'
        Start-Transcript -LiteralPath $transcript -WhatIf:$false -Confirm:$false | Out-Null
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Out-Line ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($OutputPath) { Out-Line ('Output folder: {0}' -f $OutputPath) 'Cyan' }
    if ($transcript) {
        Out-Line ('Transcript: {0}' -f $transcript) 'Cyan'
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
