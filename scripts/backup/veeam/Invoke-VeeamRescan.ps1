#Requires -Version 5.1

<#
.SYNOPSIS
    Rescans Veeam Backup & Replication managed servers and backup repositories, all of them or the ones named.

.DESCRIPTION
    Runs a rescan (Rescan-VBREntity) of Veeam Backup & Replication managed servers and backup
    repositories, one at a time. When the installed version has the -Wait parameter, each rescan
    finishes before the next one starts and Duration is its real duration. Status of each one:

        RESCANNED  the rescan finished without an error (warnings, if any, are in Detail)
        STARTED    the rescan was started, but this Veeam version has no -Wait parameter, so the
                   script cannot see the result: check the rescan sessions in the Veeam console
        FAILED     the rescan returned an error (in Detail). The script continues with the next one
        NOT FOUND  a name given in -Server or -Repository matches nothing
        WHATIF     -WhatIf: listed, not rescanned
        SKIPPED    -Confirm: answered No

    Without -Server and -Repository it rescans every managed server (Get-VBRServer) and every backup
    repository (Get-VBRBackupRepository). With either parameter it rescans only what was named:
    -Server SRV01 rescans that server and no repository. Names are not case sensitive and may contain
    wildcards (* and ?). A name that matches more than one server or repository rescans all of them.
    Scale-out backup repositories are not rescanned by name: Get-VBRBackupRepository returns standard
    repositories only.

    A rescan refreshes what Veeam knows about the server or repository, and it can change the
    configuration database: a repository rescan imports the backups it finds there that Veeam did not
    know about. The results table and a transcript are saved in -LogPath (not under -WhatIf).

    To be confirmed on the first real run: whether a failed rescan makes Rescan-VBREntity return an
    error (FAILED here), or only ends with a failed rescan session in the console while the script
    reports RESCANNED. Until then, check the rescan sessions in the console after a run.

    Requirements: run on the Veeam backup server, or on a machine with the Veeam Backup & Replication
    console after Connect-VBRServer in the same PowerShell session. When the Veeam cmdlets are not
    loaded yet, the script loads the Veeam.Backup.PowerShell module (version 11 and later) or the
    VeeamPSSnapIn snap-in (version 10 and earlier).

.PARAMETER Server
    Names of managed servers to rescan, as Veeam shows them. Wildcards allowed.
    Without -Server and -Repository: every managed server and every backup repository.

.PARAMETER Repository
    Names of backup repositories to rescan, as Veeam shows them. Wildcards allowed.

.PARAMETER LogPath
    Folder for the transcript and the results (rescan-results.csv).
    Default: InfraToolkit-Output\Invoke-VeeamRescan\<timestamp> in the folder of the script (falls back to
    %TEMP%\InfraToolkit-Output\Invoke-VeeamRescan\<timestamp> when that folder cannot be written or is in OneDrive).

.EXAMPLE
    .\Invoke-VeeamRescan.ps1
    Rescan every managed server and every backup repository.

.EXAMPLE
    .\Invoke-VeeamRescan.ps1 -WhatIf
    List what would be rescanned, without rescanning.

.EXAMPLE
    .\Invoke-VeeamRescan.ps1 -Server SRV01.contoso.com
    Rescan one managed server only.

.EXAMPLE
    .\Invoke-VeeamRescan.ps1 -Server 'PROXY*' -Repository 'Repository 01'
    Rescan every server whose name starts with PROXY, and one repository.

.NOTES
    Mode: Changes: runs a rescan of managed servers and repositories
    Network: none (the Veeam backup server contacts the servers it rescans)
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = everything was rescanned, 1 = a rescan failed or a name was not found,
                2 = rescans were started but their result is not known (no -Wait), check the console,
                3 = the script could not run (Veeam PowerShell not available, unexpected error).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$Server,

    [string[]]$Repository,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_CHECK   = 2
$EXIT_NOT_RUN = 3

$script:ExitCode = $EXIT_NOT_RUN

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

function Import-VeeamPowerShell {
    # Returns how the Veeam cmdlets were loaded, or '' when they are not available
    if (Get-Command -Name 'Get-VBRServer' -ErrorAction SilentlyContinue) { return 'already loaded' }
    try {
        Import-Module -Name 'Veeam.Backup.PowerShell' -DisableNameChecking -ErrorAction Stop
        return 'module Veeam.Backup.PowerShell'
    } catch {
        Write-Verbose ('Import-Module Veeam.Backup.PowerShell: {0}' -f $_.Exception.Message)
    }
    try {
        Add-PSSnapin -Name 'VeeamPSSnapIn' -ErrorAction Stop
        return 'snap-in VeeamPSSnapIn'
    } catch {
        Write-Verbose ('Add-PSSnapin VeeamPSSnapIn: {0}' -f $_.Exception.Message)
    }
    return ''
}

function Test-NameMatch {
    # Exact name first (names may contain [ ]), then the name as a wildcard pattern
    param([string]$Name, [string]$Pattern)
    if ($Name -eq $Pattern) { return $true }
    try { return ($Name -like $Pattern) } catch { return $false }
}

function Select-Entity {
    # Objects to rescan, in the order of the names given. A name that matches nothing is returned
    # without an object, to be reported as NOT FOUND. Each object is returned once.
    param([string]$Type, $Objects, [string[]]$Names)
    $patterns = @($Names)
    if (-not $Names) { $patterns = @('*') }
    $seen = @{}
    $selected = @()
    foreach ($pattern in $patterns) {
        $matched = @($Objects | Where-Object { $_ -and (Test-NameMatch ([string]$_.Name) $pattern) })
        if ($matched.Count -eq 0) {
            if ($Names) { $selected += [pscustomobject]@{ Type = $Type; Name = $pattern; Entity = $null } }
            continue
        }
        foreach ($o in $matched) {
            $key = ([string]$o.Name).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $selected += [pscustomobject]@{ Type = $Type; Name = [string]$o.Name; Entity = $o }
        }
    }
    return $selected
}

function New-ResultRow {
    param([string]$Type, [string]$Name, [string]$Status, [string]$Duration = '', [string]$Detail = '')
    return [pscustomobject]@{ Type = $Type; Name = $Name; Status = $Status; Duration = $Duration; Detail = $Detail }
}

function Invoke-EntityRescan {
    param($Cmdlet, $Item)
    if (-not $Item.Entity) {
        return (New-ResultRow $Item.Type $Item.Name 'NOT FOUND' '' ('No {0} matches this name' -f $Item.Type.ToLowerInvariant()))
    }
    if (-not $Cmdlet.ShouldProcess($Item.Name, 'Rescan')) {
        $status = 'SKIPPED'
        if ($WhatIfPreference) { $status = 'WHATIF' }
        return (New-ResultRow $Item.Type $Item.Name $status)
    }

    Write-Host ('Rescanning {0} {1} ...' -f $Item.Type.ToLowerInvariant(), $Item.Name) -ForegroundColor Cyan
    $start = Get-Date
    $rescanWarnings = @()
    $rescan = @{ Entity = $Item.Entity; WarningVariable = 'rescanWarnings'; ErrorAction = 'Stop' }
    if ($script:RescanHasWait) { $rescan['Wait'] = $true }
    try {
        Rescan-VBREntity @rescan | Out-Null
        # Without -Wait the cmdlet only starts the rescan: its result is not known here
        $status = 'STARTED'
        if ($script:RescanHasWait) { $status = 'RESCANNED' }
        $detail = (@($rescanWarnings | ForEach-Object { [string]$_ }) -join ' | ')
    } catch {
        $status = 'FAILED'
        $detail = $_.Exception.Message
    }
    $duration = '{0:hh\:mm\:ss}' -f ((Get-Date) - $start)
    return (New-ResultRow $Item.Type $Item.Name $status $duration $detail)
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    Write-Host 'Veeam Backup & Replication rescan' -ForegroundColor White

    $loaded = Import-VeeamPowerShell
    if (-not $loaded) {
        Write-Host 'Veeam Backup & Replication PowerShell is not available on this computer.' -ForegroundColor Red
        Write-Host 'Run the script on the Veeam backup server, or on a machine with the Veeam console.' -ForegroundColor Red
        return $EXIT_NOT_RUN
    }
    Write-Host (' Veeam PowerShell : {0}' -f $loaded)

    # -Wait makes each rescan finish before the next one starts (and gives a real duration)
    $rescanCommand = Get-Command -Name 'Rescan-VBREntity' -ErrorAction SilentlyContinue
    $script:RescanHasWait = [bool]($rescanCommand -and $rescanCommand.Parameters.ContainsKey('Wait'))
    if (-not $script:RescanHasWait) {
        Write-Host ' This Veeam version has no Rescan-VBREntity -Wait: rescans are started, check their result in the console.' -ForegroundColor Yellow
    }

    $all = (-not $Server) -and (-not $Repository)
    $items = @()
    if ($all -or $Server)     { $items += @(Select-Entity -Type 'Server' -Objects @(Get-VBRServer) -Names $Server) }
    if ($all -or $Repository) { $items += @(Select-Entity -Type 'Repository' -Objects @(Get-VBRBackupRepository) -Names $Repository) }

    if ($items.Count -eq 0) {
        Write-Host 'Nothing to rescan: no managed servers or backup repositories were found.' -ForegroundColor Yellow
        return $EXIT_OK
    }

    $rows = @(foreach ($i in $items) { Invoke-EntityRescan -Cmdlet $Cmdlet -Item $i })

    Write-Host ''
    Write-Host (($rows | Format-Table -Property Type, Name, Status, Duration, Detail -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
    Write-Host ''

    $bad = @($rows | Where-Object { $_.Status -eq 'FAILED' -or $_.Status -eq 'NOT FOUND' })
    $started = @($rows | Where-Object { $_.Status -eq 'STARTED' })
    $summary = 'Rescanned: {0}, failed: {1}, not found: {2}' -f @($rows | Where-Object { $_.Status -eq 'RESCANNED' }).Count,
        @($rows | Where-Object { $_.Status -eq 'FAILED' }).Count, @($rows | Where-Object { $_.Status -eq 'NOT FOUND' }).Count
    if ($started.Count -gt 0) { $summary += (', started (result not known): {0}' -f $started.Count) }
    if ($WhatIfPreference) { $summary += ' (WhatIf: nothing was rescanned)' }
    $color = 'Green'
    if ($started.Count -gt 0) { $color = 'Yellow' }
    if ($bad.Count -gt 0) { $color = 'Red' }
    Write-Host $summary -ForegroundColor $color

    if (-not $WhatIfPreference) {
        $csv = Join-Path $LogPath 'rescan-results.csv'
        $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
        Write-Host (' Results    : {0}' -f $csv) -ForegroundColor Cyan
    }

    if ($bad.Count -gt 0) { return $EXIT_ACTION }
    if ($started.Count -gt 0) {
        Write-Host 'Check the result of the started rescans in the Veeam console.' -ForegroundColor Yellow
        return $EXIT_CHECK
    }
    return $EXIT_OK
}

$transcript = $null
try {
    if (-not $WhatIfPreference) {
        if (-not $LogPath) {
            # Confirm off: creating the log folder is not one of the changes to confirm
            $LogPath = & {
                $WhatIfPreference = $false
                $ConfirmPreference = 'None'
                Get-OutputFolder -ScriptRoot $PSScriptRoot -ScriptName 'Invoke-VeeamRescan'
            }
            $LogPath = Join-Path $LogPath (Get-Date -Format 'yyyyMMdd-HHmmss')
        }
        New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false -Confirm:$false | Out-Null
        $file = Join-Path $LogPath 'transcript.txt'
        Start-Transcript -LiteralPath $file -WhatIf:$false -Confirm:$false | Out-Null
        $transcript = $file
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($transcript) {
        Write-Host (' Transcript : {0}' -f $transcript) -ForegroundColor Cyan
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
