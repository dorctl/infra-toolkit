#Requires -Version 5.1

<#
.SYNOPSIS
    Checks Exchange virtual directory, Autodiscover and Outlook Anywhere URLs for a namespace, sets them with -Fix.

.DESCRIPTION
    Run in the Exchange Management Shell on Exchange Server 2013, 2016, 2019 or Subscription Edition.
    When the Exchange cmdlets are not loaded, the script loads the Exchange snap-in.

    For every Exchange 2013 or later server with the Client Access role (2013) or the Mailbox role
    (2016 and later) it compares these settings with the namespace:

        Autodiscover SCP   AutoDiscoverServiceInternalUri   https://<AutodiscoverHostName>/Autodiscover/Autodiscover.xml
        OWA                InternalUrl and ExternalUrl      https://<HostName>/owa
        ECP                InternalUrl and ExternalUrl      https://<HostName>/ecp
        EWS                InternalUrl and ExternalUrl      https://<HostName>/EWS/Exchange.asmx
        MAPI               InternalUrl and ExternalUrl      https://<HostName>/mapi
        ActiveSync         InternalUrl and ExternalUrl      https://<HostName>/Microsoft-Server-ActiveSync
        OAB                InternalUrl and ExternalUrl      https://<HostName>/OAB
        PowerShell         InternalUrl and ExternalUrl      https://<HostName>/powershell
        Outlook Anywhere   InternalHostname and ExternalHostname = <HostName>, SSL required for both

    Without -AutodiscoverHostName, an SCP on https://<HostName>/Autodiscover/Autodiscover.xml is also
    accepted (one name for everything, for example with a single-name certificate). Any other SCP is set
    to the default Autodiscover name.

    The virtual directories are read from Active Directory (-ADPropertiesOnly): IIS on the servers is
    not queried. URLs are compared without case and without a trailing slash; an empty URL counts as
    different. Exchange 2010 and Edge Transport servers are skipped.

    Without -Fix the script only reports. With -Fix it sets the settings that differ, with one
    confirmation per item and server (-Confirm:$false skips the prompts), and writes a transcript.
    -WhatIf shows the changes without making them. Authentication methods are never changed.

    Clients pick up the new URLs through Autodiscover. The certificate bound to IIS must include
    HostName and AutodiscoverHostName, and DNS must resolve both names.

.PARAMETER HostName
    Namespace for the internal and external URLs, for example mail.contoso.com.

.PARAMETER AutodiscoverHostName
    Name in the Autodiscover SCP. Default: autodiscover. plus HostName without its first label
    (mail.contoso.com gives autodiscover.contoso.com), and an SCP on HostName itself is also accepted.
    When given, only this name is accepted.

.PARAMETER Server
    Exchange servers to check. Default: every Exchange 2013 or later server with the Client Access
    role (2013) or the Mailbox role (2016 and later).

.PARAMETER Fix
    Set the settings that differ. Without it the script is read-only.

.PARAMETER OutputPath
    Folder for the report (results.csv).
    Default: InfraToolkit-Output\Set-ExchangeVirtualDirectoryUrls\<timestamp> in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Set-ExchangeVirtualDirectoryUrls\<timestamp> when that folder
    cannot be written or is in OneDrive).

.PARAMETER LogPath
    Folder for the transcript of a run with -Fix.
    Default: InfraToolkit-Output\Set-ExchangeVirtualDirectoryUrls in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Set-ExchangeVirtualDirectoryUrls when that folder cannot be
    written or is in OneDrive).

.EXAMPLE
    .\Set-ExchangeVirtualDirectoryUrls.ps1 -HostName mail.contoso.com
    Report every server. The Autodiscover name is autodiscover.contoso.com.

.EXAMPLE
    .\Set-ExchangeVirtualDirectoryUrls.ps1 -HostName mail.contoso.com -Server EX01 -Fix -WhatIf
    Show what would change on EX01.

.EXAMPLE
    .\Set-ExchangeVirtualDirectoryUrls.ps1 -HostName mail.contoso.com -AutodiscoverHostName autodiscover.example.com -Fix
    Set the URLs on every server. Asks before each item; add -Confirm:$false to skip the prompts.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = every setting matches (or was set), 1 = settings differ, 2 = some settings could not be read or set, 3 = the script could not run.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\.?$')]
    [string]$HostName,

    [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\.?$')]
    [string]$AutodiscoverHostName,

    [string[]]$Server,

    [switch]$Fix,

    [string]$OutputPath,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_CHECK   = 2
$EXIT_NOT_RUN = 3

$SnapIn = 'Microsoft.Exchange.Management.PowerShell.SnapIn'

# Item, noun of the Get- and Set- cmdlets, path of the URL
$UrlItems = @(
    [pscustomobject]@{ Item = 'OWA';        Noun = 'OwaVirtualDirectory';         Path = '/owa' }
    [pscustomobject]@{ Item = 'ECP';        Noun = 'EcpVirtualDirectory';         Path = '/ecp' }
    [pscustomobject]@{ Item = 'EWS';        Noun = 'WebServicesVirtualDirectory'; Path = '/EWS/Exchange.asmx' }
    [pscustomobject]@{ Item = 'MAPI';       Noun = 'MapiVirtualDirectory';        Path = '/mapi' }
    [pscustomobject]@{ Item = 'ActiveSync'; Noun = 'ActiveSyncVirtualDirectory';  Path = '/Microsoft-Server-ActiveSync' }
    [pscustomobject]@{ Item = 'OAB';        Noun = 'OabVirtualDirectory';         Path = '/OAB' }
    [pscustomobject]@{ Item = 'PowerShell'; Noun = 'PowerShellVirtualDirectory';  Path = '/powershell' }
)

$script:Rows = @()

# ------------------------------------------------------------------ helpers
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

function Get-DefaultOutputFolder {
    # Get-OutputFolder with -WhatIf and -Confirm off: its write test creates and removes a file, which
    # under -WhatIf is never created (the folder would be rejected) and under -Confirm asks each time.
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    return (Get-OutputFolder -ScriptRoot $PSScriptRoot -ScriptName 'Set-ExchangeVirtualDirectoryUrls')
}

function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-22}: {1}' -f $Label, $Value)
}

function Format-Value {
    param($Value)
    if ($null -eq $Value -or -not ([string]$Value).Trim()) { return '(empty)' }
    return ([string]$Value).Trim()
}

function New-Setting {
    # Compare: Url, Host or Bool. Settings in the same Group are always set together.
    # Value is what -Fix sets. Accept lists other values that also count as OK.
    param([string]$Name, [string]$Compare, $Value, [string]$Group, [object[]]$Accept = @())
    return [pscustomobject]@{ Name = $Name; Compare = $Compare; Value = $Value; Group = $Group; Accept = $Accept }
}

function Test-SettingMatch {
    param([string]$Compare, $Current, $Expected)
    if ($null -eq $Current) { return $false }
    $c = ([string]$Current).Trim()
    if (-not $c) { return $false }
    switch ($Compare) {
        'Url'   { return ($c.TrimEnd('/') -eq ([string]$Expected).TrimEnd('/')) }
        'Host'  { return ($c.TrimEnd('.') -eq [string]$Expected) }
        default { return ($c -eq [string]$Expected) }
    }
}

function Find-SettingMatch {
    # The expected value the current value matches (Value first, then Accept), $null when none
    param($Setting, $Current)
    foreach ($v in @(@($Setting.Value) + @($Setting.Accept))) {
        if (Test-SettingMatch $Setting.Compare $Current $v) { return [pscustomobject]@{ Value = $v } }
    }
    return $null
}

function Format-Change {
    # "Set OWA InternalUrl and ExternalUrl to <url>" or "Set <item> A to x, B to y"
    param([string]$Label, $Params)
    $values = @($Params.Values | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($values.Count -eq 1) {
        return ('Set {0} {1} to {2}' -f $Label, (@($Params.Keys) -join ' and '), $values[0])
    }
    $parts = @(foreach ($k in $Params.Keys) { '{0} to {1}' -f $k, $Params[$k] })
    return ('Set {0} {1}' -f $Label, ($parts -join ', '))
}

# ------------------------------------------------------------------ Exchange
function Test-ExchangeShell {
    if (Get-Command -Name Get-ExchangeServer -ErrorAction SilentlyContinue) { return $true }
    Out-Line ('The Exchange cmdlets are not loaded. Loading {0} ...' -f $SnapIn) 'DarkGray'
    try {
        Add-PSSnapin -Name $SnapIn -ErrorAction Stop
    } catch {
        Out-Line ('  {0}' -f $_.Exception.Message) 'DarkGray'
    }
    return [bool](Get-Command -Name Get-ExchangeServer -ErrorAction SilentlyContinue)
}

function Get-ServerCandidate {
    # Every Exchange server, with the reason it is skipped (empty when it is checked)
    $list = @()
    foreach ($s in @(Get-ExchangeServer -ErrorAction Stop)) {
        $version = [string]$s.AdminDisplayVersion
        $major = 0
        $minor = 0
        if ($version -match '(\d+)\.(\d+)') { $major = [int]$Matches[1]; $minor = [int]$Matches[2] }
        $reason = ''
        if ($major -lt 15) {
            $reason = 'older than Exchange 2013'
        } elseif ($major -eq 15 -and $minor -eq 0 -and -not $s.IsClientAccessServer) {
            $reason = 'Exchange 2013 without the Client Access role'
        } elseif (-not ($s.IsClientAccessServer -or $s.IsMailboxServer)) {
            $reason = 'no Client Access or Mailbox role (Edge Transport)'
        }
        $list += [pscustomobject]@{
            Name = [string]$s.Name; Fqdn = [string]$s.Fqdn; Version = $version; Reason = $reason
        }
    }
    return $list
}

function Get-ItemDefinition {
    param([string]$Namespace, [string]$AutodiscoverName, [string]$ScpNoun, [switch]$AcceptNamespaceScp)
    $scpUrl = 'https://{0}/Autodiscover/Autodiscover.xml'
    $scpAccept = @()
    if ($AcceptNamespaceScp) { $scpAccept = @($scpUrl -f $Namespace) }
    $items = @()
    $items += [pscustomobject]@{
        Item = 'Autodiscover SCP'; Noun = $ScpNoun; Scp = $true
        Settings = @(New-Setting -Name 'AutoDiscoverServiceInternalUri' -Compare 'Url' -Value ($scpUrl -f $AutodiscoverName) -Group 'Scp' -Accept $scpAccept)
    }
    foreach ($u in $UrlItems) {
        $url = 'https://{0}{1}' -f $Namespace, $u.Path
        $items += [pscustomobject]@{
            Item = $u.Item; Noun = $u.Noun; Scp = $false
            Settings = @(
                (New-Setting 'InternalUrl' 'Url' $url 'InternalUrl')
                (New-Setting 'ExternalUrl' 'Url' $url 'ExternalUrl')
            )
        }
    }
    # Exchange requires the host name and the SSL setting of one side together
    $items += [pscustomobject]@{
        Item = 'Outlook Anywhere'; Noun = 'OutlookAnywhere'; Scp = $false
        Settings = @(
            (New-Setting 'InternalHostname'          'Host' $Namespace 'Internal')
            (New-Setting 'InternalClientsRequireSsl' 'Bool' $true      'Internal')
            (New-Setting 'ExternalHostname'          'Host' $Namespace 'External')
            (New-Setting 'ExternalClientsRequireSsl' 'Bool' $true      'External')
        )
    }
    return $items
}

function Read-ItemObject {
    param($Definition, [string]$ServerName)
    $params = @{ ErrorAction = 'Stop' }
    if ($Definition.Scp) {
        $params['Identity'] = $ServerName
    } else {
        $params['Server'] = $ServerName
        $params['ADPropertiesOnly'] = $true
    }
    return @(& ('Get-' + $Definition.Noun) @params | Where-Object { $null -ne $_ })
}

function Add-Row {
    param([string]$ServerName, [string]$Item, [string]$Setting, $Current, $Expected, [string]$Status, [string]$Detail = '')
    $row = [pscustomobject]@{
        Server = $ServerName; Item = $Item; Setting = $Setting
        Current = (Format-Value $Current); Expected = (Format-Value $Expected); Status = $Status; Detail = $Detail
    }
    $script:Rows += $row
    return $row
}

function Invoke-ItemCheck {
    # Reads one item on one server, adds the report rows and sets what differs (-Fix)
    param($Cmdlet, $Definition, [string]$ServerName)
    try {
        $objects = @(Read-ItemObject -Definition $Definition -ServerName $ServerName)
    } catch {
        Add-Row $ServerName $Definition.Item '(all)' '-' '-' 'FAILED' ('Could not read: {0}' -f $_.Exception.Message) | Out-Null
        return
    }
    if ($objects.Count -eq 0) {
        Add-Row $ServerName $Definition.Item '(all)' '-' '-' 'FAILED' 'Not found on this server' | Out-Null
        return
    }

    foreach ($obj in $objects) {
        $label = $Definition.Item
        if ($objects.Count -gt 1) { $label = '{0} [{1}]' -f $Definition.Item, $obj.Name }

        $pending = @()
        foreach ($s in $Definition.Settings) {
            $current = $obj.($s.Name)
            $status = 'OK'
            $expected = $s.Value
            $match = Find-SettingMatch -Setting $s -Current $current
            if ($match) { $expected = $match.Value } else { $status = 'CHANGE' }
            $row = Add-Row $ServerName $label $s.Name $current $expected $status
            if ($status -eq 'CHANGE') { $pending += [pscustomobject]@{ Setting = $s; Row = $row } }
        }
        if (-not $Fix -or $pending.Count -eq 0) { continue }

        $groups = @($pending | ForEach-Object { $_.Setting.Group } | Select-Object -Unique)
        $values = [ordered]@{}
        foreach ($s in $Definition.Settings) {
            if ($groups -contains $s.Group) { $values[$s.Name] = $s.Value }
        }
        $identity = [string]$obj.Identity
        if (-not $identity) { $identity = $ServerName }

        if ($Cmdlet.ShouldProcess($ServerName, (Format-Change $label $values))) {
            $params = @{ Identity = $identity; ErrorAction = 'Stop'; Confirm = $false }
            foreach ($k in $values.Keys) { $params[$k] = $values[$k] }
            try {
                & ('Set-' + $Definition.Noun) @params | Out-Null
                foreach ($p in $pending) { $p.Row.Status = 'SET' }
                Out-Line ('  {0}: {1} set' -f $label, (@($values.Keys) -join ', ')) 'Green'
            } catch {
                $message = $_.Exception.Message
                foreach ($p in $pending) { $p.Row.Status = 'FAILED'; $p.Row.Detail = $message }
                Out-Line ('  {0}: FAILED - {1}' -f $label, $message) 'Red'
            }
        }
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to change)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is changed)' }
    elseif ($Fix) { $modeText = '-Fix' }

    $namespace = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
    $adName = $AutodiscoverHostName
    if ($adName) {
        $adName = $adName.Trim().TrimEnd('.').ToLowerInvariant()
    } else {
        if (@($namespace -split '\.').Count -lt 3) {
            Out-Line ('Cannot derive the Autodiscover name from {0}. Use -AutodiscoverHostName.' -f $namespace) 'Red'
            return $EXIT_NOT_RUN
        }
        $adName = 'autodiscover.' + ($namespace -replace '^[^.]+\.', '')
    }

    Out-Line 'Exchange virtual directory URLs' 'White'
    Out-Line (Format-Row 'Namespace' $namespace)
    Out-Line (Format-Row 'Autodiscover name' $adName)
    Out-Line (Format-Row 'Mode' $modeText)

    if (-not (Test-ExchangeShell)) {
        Out-Line 'The Exchange cmdlets are not available. Run the script in the Exchange Management Shell.' 'Red'
        return $EXIT_NOT_RUN
    }

    $candidates = @(Get-ServerCandidate)
    $targets = @()
    if ($Server) {
        foreach ($name in $Server) {
            $match = @($candidates | Where-Object { $_.Name -eq $name -or $_.Fqdn -eq $name })
            if ($match.Count -eq 0) {
                Out-Line ('{0} is not an Exchange server in this organization.' -f $name) 'Red'
                return $EXIT_NOT_RUN
            }
            if ($match[0].Reason) {
                Out-Line ('{0} cannot be checked: {1}.' -f $match[0].Name, $match[0].Reason) 'Red'
                return $EXIT_NOT_RUN
            }
            $targets += $match[0]
        }
    } else {
        $targets = @($candidates | Where-Object { -not $_.Reason })
        foreach ($c in @($candidates | Where-Object { $_.Reason })) {
            Out-Line (Format-Row 'Skipped' ('{0} ({1})' -f $c.Name, $c.Reason)) 'DarkGray'
        }
    }
    if ($targets.Count -eq 0) {
        Out-Line 'No Exchange 2013 or later server with the Client Access or Mailbox role was found.' 'Red'
        return $EXIT_NOT_RUN
    }
    Out-Line (Format-Row 'Servers' ((@($targets | ForEach-Object { $_.Name })) -join ', '))

    # Exchange 2016 and later: Get-ClientAccessService. Exchange 2013: Get-ClientAccessServer.
    $scpNoun = 'ClientAccessServer'
    if (Get-Command -Name Get-ClientAccessService -ErrorAction SilentlyContinue) { $scpNoun = 'ClientAccessService' }
    # An SCP on the namespace itself is accepted unless an Autodiscover name was given
    $itemParams = @{ Namespace = $namespace; AutodiscoverName = $adName; ScpNoun = $scpNoun; AcceptNamespaceScp = (-not $AutodiscoverHostName) }
    $definitions = @(Get-ItemDefinition @itemParams)

    foreach ($t in $targets) {
        Out-Line ''
        Out-Line ('Reading {0} ...' -f $t.Name) 'Cyan'
        foreach ($d in $definitions) { Invoke-ItemCheck -Cmdlet $Cmdlet -Definition $d -ServerName $t.Name }
    }

    $table = $script:Rows | Format-Table Server, Item, Setting, Current, Expected, Status -AutoSize | Out-String -Width 4096
    Out-Line ''
    Out-Line $table.TrimEnd()

    $ok      = @($script:Rows | Where-Object { $_.Status -eq 'OK' }).Count
    $change  = @($script:Rows | Where-Object { $_.Status -eq 'CHANGE' }).Count
    $set     = @($script:Rows | Where-Object { $_.Status -eq 'SET' }).Count
    $failed  = @($script:Rows | Where-Object { $_.Status -eq 'FAILED' })
    Out-Line ''
    Out-Line ('{0} settings on {1} servers: {2} OK, {3} to change, {4} set, {5} failed' -f
        $script:Rows.Count, $targets.Count, $ok, $change, $set, $failed.Count) 'White'
    foreach ($f in $failed) { Out-Line ('   - {0} {1} {2}: {3}' -f $f.Server, $f.Item, $f.Setting, $f.Detail) 'Red' }
    if ($failed.Count -gt 0) { Out-Line 'Check the FAILED items, fix the cause and run the script again.' 'Yellow' }

    if ($change -gt 0) {
        if ($Fix -and $WhatIfPreference) { Out-Line 'WhatIf: nothing was changed.' 'Yellow' }
        elseif (-not $Fix) { Out-Line 'Run again with -Fix to set them (add -WhatIf to preview).' 'Yellow' }
    }
    if ($change -gt 0 -or $set -gt 0) {
        Out-Line 'Notes:' 'White'
        Out-Line ' - Outlook and mobile clients pick up the new URLs through Autodiscover.'
        Out-Line (' - The IIS certificate must include {0} and {1}, and DNS must resolve both names.' -f $namespace, $adName)
    }

    if ($failed.Count -gt 0) { return $EXIT_CHECK }
    if ($change -gt 0) { return $EXIT_ACTION }
    return $EXIT_OK
}

$script:ExitCode = $EXIT_NOT_RUN
$transcript = $null
try {
    if ($Fix -and -not $WhatIfPreference) {
        if (-not $LogPath) {
            $LogPath = Get-DefaultOutputFolder
        }
        New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false -Confirm:$false | Out-Null
        $transcript = Join-Path $LogPath ('transcript-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $transcript -WhatIf:$false -Confirm:$false | Out-Null
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Out-Line ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($script:Rows.Count -gt 0) {
        try {
            if (-not $OutputPath) {
                $OutputPath = Get-DefaultOutputFolder
                $OutputPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd-HHmmss')
            }
            New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null
            $csv = Join-Path $OutputPath 'results.csv'
            $script:Rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
            Out-Line (Format-Row 'Report' $csv) 'Cyan'
        } catch {
            Write-Warning ('Could not save the report: {0}' -f $_.Exception.Message)
        }
    }
    if ($transcript) {
        Out-Line (Format-Row 'Transcript' $transcript) 'Cyan'
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
