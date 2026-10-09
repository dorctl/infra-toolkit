#Requires -Version 5.1

<#
.SYNOPSIS
    Checks the Microsoft Exchange Writer (VSS) and restarts the Microsoft Exchange Replication service with -Fix.

.DESCRIPTION
    Run on an Exchange Mailbox server (2013, 2016, 2019 or Subscription Edition) when Exchange aware
    backups fail. The Microsoft Exchange Writer runs in the Microsoft Exchange Replication service
    (MSExchangeRepl). The script reads it with vssadmin list writers and decides from the state number,
    which is the same in every language:

        [1] Stable, last error "No error"            OK
        [1] Stable with another last error           ACTION REQUIRED (for example Retryable error)
        [2] to [5] Waiting for ...                   MANUAL CHECK - a backup is probably running
        [6] to [15] Failed at ...                    ACTION REQUIRED
        writer not listed                            ACTION REQUIRED (MSExchangeRepl stopped or the writer hangs)

    The writer names are not translated, the labels and texts are. When vssadmin does not answer in
    English, "no error" is taken as the last error text most other stable writers show; with fewer than
    2 other stable writers to compare with, a stable Exchange writer gives MANUAL CHECK.

    Without -Fix the script only reports. With -Fix, and only when action is required, it restarts
    MSExchangeRepl (or starts it when it is stopped), waits until it runs and checks the writer again.
    Restarting MSExchangeRepl does not dismount databases; passive copies on this server resume
    replication. It never restarts the service while a backup is running (states 2 to 5).
    -IncludeInformationStore also restarts the Microsoft Exchange Information Store (MSExchangeIS) first:
    this dismounts every database on this server until it mounts again. In a DAG, move the active
    copies to another member before you use it.
    -WhatIf shows what would be restarted. Every run with -Fix writes a transcript.

    Requirements: elevated PowerShell (vssadmin needs administrator rights).

.PARAMETER Fix
    Restart the service when action is required. Without it the script is read-only.

.PARAMETER IncludeInformationStore
    With -Fix, also restart MSExchangeIS before MSExchangeRepl. Dismounts the databases on this server.

.PARAMETER TimeoutSeconds
    How long to wait for each service to run and for the writer to appear after the restart. Default: 60.

.PARAMETER LogPath
    Folder for the transcript of a run with -Fix.
    Default: %USERPROFILE%\InfraToolkit-Output\Repair-ExchangeVssWriter

.EXAMPLE
    .\Repair-ExchangeVssWriter.ps1
    Report the state of the Exchange writer.

.EXAMPLE
    .\Repair-ExchangeVssWriter.ps1 -Fix -WhatIf
    Show what would be restarted.

.EXAMPLE
    .\Repair-ExchangeVssWriter.ps1 -Fix
    Restart MSExchangeRepl when the writer needs it, then check again. Asks first; add -Confirm:$false to skip.

.EXAMPLE
    .\Repair-ExchangeVssWriter.ps1 -Fix -IncludeInformationStore
    Also restart the Information Store, in a maintenance window only.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = writer OK (or fixed), 1 = action required, 2 = manual check required (backup running), 3 = the script could not run.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$Fix,

    [switch]$IncludeInformationStore,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 60,

    [string]$LogPath = (Join-Path $env:USERPROFILE ('InfraToolkit-Output\{0}' -f
        ($MyInvocation.MyCommand.Name -replace '\.ps1$', '')))
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_CHECK   = 2
$EXIT_NOT_RUN = 3

$WriterName   = 'Microsoft Exchange Writer'
$ReplService  = 'MSExchangeRepl'
$StoreService = 'MSExchangeIS'

# ------------------------------------------------------------------ helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-16}: {1}' -f $Label, $Value)
}

function Get-VerdictText {
    param([int]$Sev)
    switch ($Sev) {
        0       { return 'OK' }
        1       { return 'ACTION REQUIRED' }
        2       { return 'MANUAL CHECK REQUIRED' }
        default { return 'COULD NOT RUN' }
    }
}

function Get-VerdictColor {
    param([int]$Sev)
    switch ($Sev) {
        0       { return 'Green' }
        2       { return 'Yellow' }
        default { return 'Red' }
    }
}

function Test-Elevated {
    # High (S-1-16-12288) or System (S-1-16-16384) integrity level = elevated
    $ErrorActionPreference = 'Continue'
    $groups = @(& whoami.exe /groups /fo csv /nh 2>$null)
    return (@($groups -match 'S-1-16-(12288|16384)').Count -gt 0)
}

# ------------------------------------------------------------------ VSS writer
function Invoke-VssAdmin {
    # Windows PowerShell 5.1 turns redirected stderr into a terminating error under 'Stop'
    $ErrorActionPreference = 'Continue'
    $output = @(& vssadmin.exe list writers 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Lines = $output; ExitCode = $LASTEXITCODE }
}

function Get-WriterName {
    # Name from "Writer name: 'x'" (English) or a translated label, with single or double quotes. '' otherwise.
    param([string]$Line)
    if ($Line -match ':\s*[''"](.+?)[''"]\s*$') { return $Matches[1] }
    return ''
}

function ConvertTo-WriterInfo {
    # One writer block: name line + following lines -> state number, state text and last error
    param([string]$NameLine, [string[]]$Block)
    $info = [pscustomobject]@{
        Name = (Get-WriterName $NameLine); State = $null; StateText = ''; LastError = ''; English = $false
        Lines = @(@($NameLine) + @($Block))
    }
    $stateIndex = -1
    for ($k = 0; $k -lt $Block.Count; $k++) {
        if ($Block[$k] -match '\[(\d+)\]\s*(.*)$') {
            $info.State = [int]$Matches[1]
            $info.StateText = $Matches[2].Trim()
            $stateIndex = $k
            break
        }
    }
    foreach ($line in $Block) {
        if ($line -match '^\s*Last error\s*:\s*(.*)$') { $info.LastError = $Matches[1].Trim(); $info.English = $true }
    }
    # Other languages: the last error is the line after the state
    if (-not $info.English -and $stateIndex -ge 0 -and $stateIndex + 1 -lt $Block.Count -and $Block[$stateIndex + 1] -match ':\s*(.*)$') {
        $info.LastError = $Matches[1].Trim()
    }
    return $info
}

function Get-WriterList {
    # Every writer in the output of vssadmin list writers. Blocks end at an empty line or the next name line.
    param([string[]]$Lines)
    $writers = @()
    $nameLine = $null
    $block = @()
    foreach ($raw in @($Lines) + @('')) {
        $line = [string]$raw
        $isName = [bool](Get-WriterName $line)
        if ($null -ne $nameLine -and ($isName -or -not $line.Trim())) {
            $writers += ConvertTo-WriterInfo -NameLine $nameLine -Block $block
            $nameLine = $null
            $block = @()
        }
        if ($isName) { $nameLine = $line }
        elseif ($null -ne $nameLine) { $block += $line }
    }
    return $writers
}

function Get-WriterVerdict {
    param($Info, $Writers)
    $s = $Info.State
    if ($null -eq $s) {
        return [pscustomobject]@{ Severity = $EXIT_CHECK; Reason = 'The state of the writer could not be read' }
    }
    if ($s -eq 1) {
        if ($Info.English) {
            if ($Info.LastError -eq 'No error') {
                return [pscustomobject]@{ Severity = $EXIT_OK; Reason = 'Stable, no error' }
            }
            return [pscustomobject]@{ Severity = $EXIT_ACTION; Reason = ('Stable, but the last backup left an error: {0}' -f $Info.LastError) }
        }
        # Not in English: "no error" is the last error text most other stable writers show
        $others = @($Writers | Where-Object { $_.Name -ne $WriterName -and $_.State -eq 1 -and $_.LastError })
        if ($others.Count -lt 2) {
            return [pscustomobject]@{ Severity = $EXIT_CHECK; Reason = ('Stable, last error "{0}". vssadmin output is not in English and fewer than 2 other stable writers to compare with: check the text' -f $Info.LastError) }
        }
        $noError = [string](@($others | Group-Object -Property LastError | Sort-Object -Property Count -Descending)[0].Name)
        if ($Info.LastError -eq $noError) {
            return [pscustomobject]@{ Severity = $EXIT_OK; Reason = ('Stable, last error "{0}" as on the other stable writers (vssadmin output is not in English)' -f $Info.LastError) }
        }
        return [pscustomobject]@{ Severity = $EXIT_ACTION; Reason = ('Stable, but the last error is "{0}" while the other stable writers show "{1}" (vssadmin output is not in English)' -f $Info.LastError, $noError) }
    }
    if ($s -ge 2 -and $s -le 5) {
        return [pscustomobject]@{ Severity = $EXIT_CHECK; Reason = 'Waiting: a backup is probably running. Check again when it ends' }
    }
    if ($s -ge 6 -and $s -le 15) {
        return [pscustomobject]@{ Severity = $EXIT_ACTION; Reason = ('Failed state [{0}] {1}' -f $s, $Info.StateText) }
    }
    return [pscustomobject]@{ Severity = $EXIT_CHECK; Reason = ('Unknown state [{0}] {1}' -f $s, $Info.StateText) }
}

function Get-ServiceStatus {
    # Status text of a service, '' when it does not exist
    param([string]$Name)
    $svc = @(Get-Service -Name $Name -ErrorAction SilentlyContinue)
    if ($svc.Count -eq 0) { return '' }
    return [string]$svc[0].Status
}

function Read-ExchangeWriter {
    # Runs vssadmin and assesses the Exchange writer. Severity 3 when vssadmin cannot be used.
    $vss = Invoke-VssAdmin
    $writers = @(Get-WriterList $vss.Lines)
    if ($vss.ExitCode -ne 0 -or $writers.Count -eq 0) {
        foreach ($l in @($vss.Lines | Where-Object { ([string]$_).Trim() })) { Out-Line ('   vssadmin: {0}' -f $l) 'DarkGray' }
        return [pscustomobject]@{
            Info = $null; Severity = $EXIT_NOT_RUN; ReplStatus = ''
            Reason = ('vssadmin list writers failed (exit code {0})' -f $vss.ExitCode)
        }
    }
    $info = @($writers | Where-Object { $_.Name -eq $WriterName })[0]
    if ($info) {
        $v = Get-WriterVerdict -Info $info -Writers $writers
        return [pscustomobject]@{ Info = $info; Severity = $v.Severity; Reason = $v.Reason; ReplStatus = '' }
    }
    $status = Get-ServiceStatus $ReplService
    if (-not $status) {
        return [pscustomobject]@{
            Info = $null; Severity = $EXIT_NOT_RUN; ReplStatus = ''
            Reason = ('The {0} service does not exist: this is not an Exchange Mailbox server' -f $ReplService)
        }
    }
    $reason = 'The writer is not listed and {0} is {1}' -f $ReplService, $status
    if ($status -eq 'Running') { $reason = 'The writer is not listed although {0} is running' -f $ReplService }
    return [pscustomobject]@{ Info = $null; Severity = $EXIT_ACTION; Reason = $reason; ReplStatus = $status }
}

function Write-WriterReport {
    param($Check)
    if ($Check.Info) {
        foreach ($l in $Check.Info.Lines) { Out-Line ('   {0}' -f $l.Trim()) }
    } elseif ($Check.ReplStatus) {
        Out-Line (Format-Row $ReplService $Check.ReplStatus)
    }
    Out-Line (Format-Row 'Status' (Get-VerdictText $Check.Severity)) (Get-VerdictColor $Check.Severity)
    Out-Line ('   - {0}' -f $Check.Reason) (Get-VerdictColor $Check.Severity)
}

# ------------------------------------------------------------------ changes (-Fix)
function Wait-ServiceRunning {
    param([string]$Name, [int]$Seconds)
    $tries = [int][math]::Ceiling($Seconds / 2)
    for ($i = 0; $i -le $tries; $i++) {
        if ((Get-ServiceStatus $Name) -eq 'Running') { return $true }
        if ($i -lt $tries) { Start-Sleep -Seconds 2 }
    }
    return $false
}

function Restart-ExchangeService {
    # Restarts a running service or starts a stopped one, then waits until it runs
    param([string]$Name)
    $status = Get-ServiceStatus $Name
    if (-not $status) { throw ('The {0} service does not exist' -f $Name) }
    if ($status -eq 'Running') {
        Out-Line ('  Restarting {0} ...' -f $Name)
        Restart-Service -Name $Name -Confirm:$false -WhatIf:$false
    } else {
        Out-Line ('  Starting {0} (was {1}) ...' -f $Name, $status)
        Start-Service -Name $Name -Confirm:$false -WhatIf:$false
    }
    if (-not (Wait-ServiceRunning -Name $Name -Seconds $TimeoutSeconds)) {
        throw ('{0} is not running after {1} seconds' -f $Name, $TimeoutSeconds)
    }
    Out-Line ('  {0} is running' -f $Name) 'Green'
}

function Wait-ExchangeWriter {
    # After the restart the writer registers again within a few seconds
    $tries = [int][math]::Ceiling($TimeoutSeconds / 5)
    for ($i = 0; $i -le $tries; $i++) {
        $check = Read-ExchangeWriter
        if ($check.Info -or $check.Severity -eq $EXIT_NOT_RUN) { return $check }
        if ($i -lt $tries) { Start-Sleep -Seconds 5 }
    }
    return $check
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to restart)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is restarted)' }
    elseif ($Fix) { $modeText = '-Fix' }

    Out-Line 'Microsoft Exchange Writer (VSS)' 'White'
    Out-Line (Format-Row 'Computer' $env:COMPUTERNAME)
    Out-Line (Format-Row 'Mode' $modeText)

    if (-not (Test-Elevated)) {
        Out-Line 'Run this script from an elevated PowerShell (Run as administrator).' 'Red'
        return $EXIT_NOT_RUN
    }

    Out-Line ''
    Out-Line 'Reading the VSS writers (vssadmin list writers) ...' 'DarkGray'
    $check = Read-ExchangeWriter
    if ($check.Severity -eq $EXIT_NOT_RUN) {
        Out-Line ('Cannot check the writer: {0}.' -f $check.Reason) 'Red'
        return $EXIT_NOT_RUN
    }
    Write-WriterReport $check

    if ($check.Severity -ne $EXIT_ACTION) {
        if ($Fix -and $check.Severity -eq $EXIT_CHECK) { Out-Line 'Nothing is restarted while a backup may be running.' 'Yellow' }
        elseif ($Fix) { Out-Line 'Nothing to change.' 'Green' }
        return [int]$check.Severity
    }
    if (-not $Fix) {
        Out-Line ''
        Out-Line ('Run again with -Fix to restart {0} (add -WhatIf to preview).' -f $ReplService) 'Yellow'
        return $EXIT_ACTION
    }

    $services = @()
    if ($IncludeInformationStore) { $services += $StoreService }
    $services += $ReplService
    $verb = 'Restart'
    if ($check.ReplStatus -and $check.ReplStatus -ne 'Running') { $verb = 'Start' }
    $action = '{0} {1}' -f $verb, ($services -join ' and ')
    if ($IncludeInformationStore) {
        $action += ' (dismounts every database on this server until it mounts again)'
        Write-Warning ('Restarting {0} dismounts every database on this server. Users lose access until the databases mount again.' -f $StoreService)
    }

    Out-Line ''
    if (-not $Cmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
        if ($WhatIfPreference) { Out-Line 'WhatIf: nothing was restarted.' 'Yellow' }
        return $EXIT_ACTION
    }
    Out-Line 'Changes' 'White'
    try {
        foreach ($name in $services) { Restart-ExchangeService -Name $name }
    } catch {
        Out-Line ('  FAILED: {0}' -f $_.Exception.Message) 'Red'
        return $EXIT_ACTION
    }

    Out-Line ''
    Out-Line 'After the restart' 'White'
    $after = Wait-ExchangeWriter
    if ($after.Severity -eq $EXIT_NOT_RUN) {
        Out-Line ('Cannot check the writer: {0}.' -f $after.Reason) 'Red'
        return $EXIT_ACTION
    }
    Write-WriterReport $after
    if ($after.Severity -eq $EXIT_OK) { return $EXIT_OK }
    Out-Line 'The writer is still not stable. Check the Application event log (sources MSExchangeRepl and VSS).' 'Yellow'
    return $EXIT_ACTION
}

$script:ExitCode = $EXIT_NOT_RUN
$transcript = $null
try {
    if ($Fix -and -not $WhatIfPreference) {
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
    Out-Line ''
    Out-Line ('OVERALL: {0}' -f (Get-VerdictText $script:ExitCode)) (Get-VerdictColor $script:ExitCode)
    if ($transcript) {
        Out-Line (Format-Row 'Transcript' $transcript) 'Cyan'
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
