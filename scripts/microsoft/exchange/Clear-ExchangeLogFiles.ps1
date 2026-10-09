#Requires -Version 5.1

<#
.SYNOPSIS
    Reports Exchange and IIS log files older than a retention period, and deletes them with -Fix.

.DESCRIPTION
    Run on an Exchange server (2013, 2016, 2019 or Subscription Edition) to free disk space taken by
    diagnostic logs. Default folders:

        IIS logs                       %SystemDrive%\inetpub\logs\LogFiles
        Exchange logging               %ExchangeInstallPath%\Logging
        Search diagnostics (ETL)       %ExchangeInstallPath%\Bin\Search\Ceres\Diagnostics\ETLTraces
        Search diagnostics (logs)      %ExchangeInstallPath%\Bin\Search\Ceres\Diagnostics\Logs

    Use -Path for other folders, or on a server without Exchange.

    A file is selected when its extension is in -Extension (default .log, .blg and .etl) and its last
    write time is older than -RetentionDays. Sub folders are included. Only files are deleted, never
    folders.

    Databases are protected, whatever -Path says: a file named like a transaction log (E00.log,
    E0000000001.log, E00tmp.log, E00res00001.log) is never selected, and a folder that holds .edb or .chk
    files, the Exchange installation folder itself and its Mailbox folder are refused: REFUSED in the
    report, nothing deleted in them, exit code 3. Transaction logs are removed by a backup.

    Without -Fix the script only reports, per folder: the number of files, their size and the date of
    the oldest one. A folder that does not exist is reported, not treated as an error.
    With -Fix it asks once per folder (-Confirm:$false skips the prompts) and deletes the files one by
    one. A file that cannot be deleted (in use) is skipped and listed. The deleted files, the failures
    and a transcript are written to the log folder. -WhatIf shows what would be deleted.
    The execution policy is not changed.

.PARAMETER RetentionDays
    Keep files written in the last N days. Default: 7.

.PARAMETER Path
    Folders to clean. Default: the IIS and Exchange log folders listed above.

.PARAMETER Extension
    File extensions to delete. Default: .log, .blg, .etl

.PARAMETER Fix
    Delete the files. Without it the script is read-only.

.PARAMETER OutputPath
    Folder for the report (results.csv).
    Default: InfraToolkit-Output\Clear-ExchangeLogFiles\<timestamp> in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Clear-ExchangeLogFiles\<timestamp> when that folder cannot be
    written or is in OneDrive).

.PARAMETER LogPath
    Folder for the transcript and the lists of deleted and failed files of a run with -Fix.
    Default: InfraToolkit-Output\Clear-ExchangeLogFiles in the folder of the script
    (falls back to %TEMP%\InfraToolkit-Output\Clear-ExchangeLogFiles when that folder cannot be written
    or is in OneDrive).

.EXAMPLE
    .\Clear-ExchangeLogFiles.ps1
    Report the files older than 7 days in the default folders.

.EXAMPLE
    .\Clear-ExchangeLogFiles.ps1 -RetentionDays 14 -Fix -WhatIf
    Show what would be deleted with a 14 day retention.

.EXAMPLE
    .\Clear-ExchangeLogFiles.ps1 -RetentionDays 14 -Fix -Confirm:$false
    Delete without prompts, for example from a scheduled task.

.EXAMPLE
    .\Clear-ExchangeLogFiles.ps1 -Path D:\IISLogs, D:\ExchangeLogs -Extension .log -Fix
    Clean other folders.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = nothing to delete (or everything deleted), 1 = files to delete, 2 = some files could not be deleted, 3 = the script could not run or a folder was refused.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 7,

    [string[]]$Path,

    [ValidateNotNullOrEmpty()]
    [string[]]$Extension = @('.log', '.blg', '.etl'),

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

$ExchangeLogFolders = @('Logging', 'Bin\Search\Ceres\Diagnostics\ETLTraces', 'Bin\Search\Ceres\Diagnostics\Logs')

# Never deleted: transaction logs (E00.log, E0000000001.log, E00tmp.log, E00res00001.log).
# Folders with database or checkpoint files are refused.
$TransactionLogPattern = '^E[0-9A-F]{2}([0-9A-F]{8}|tmp|res\d+)?\.log$'
$DatabaseExtensions    = @('.edb', '.chk')

$script:Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Folders = @()

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
    return (Get-OutputFolder -ScriptRoot $PSScriptRoot -ScriptName 'Clear-ExchangeLogFiles')
}

function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-16}: {1}' -f $Label, $Value)
}

function ConvertTo-MB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1MB, 2)
}

function Get-DefaultFolder {
    $folders = @('{0}\inetpub\logs\LogFiles' -f $env:SystemDrive)
    foreach ($sub in $ExchangeLogFolders) { $folders += (Join-Path $env:ExchangeInstallPath $sub) }
    return $folders
}

function Get-ExtensionList {
    # ".log", "log" and "*.log" all mean .log
    param([string[]]$Value)
    $list = @()
    foreach ($e in $Value) {
        $x = ([string]$e).Trim().TrimStart('*').ToLowerInvariant()
        if (-not $x) { continue }
        if (-not $x.StartsWith('.')) { $x = '.' + $x }
        $list += $x
    }
    return @($list | Select-Object -Unique)
}

function Get-NormalPath {
    # Full path with backslashes and without a trailing separator, for comparisons
    param([string]$Folder)
    $p = $Folder
    if (Test-Path -LiteralPath $Folder) { $p = (Resolve-Path -LiteralPath $Folder).ProviderPath }
    return (($p -replace '/', '\').TrimEnd('\'))
}

function Test-RootFolder {
    # A drive, a share or the file system root is never cleaned as a whole
    param([string]$Folder)
    $p = Get-NormalPath $Folder
    return ($p -eq '' -or $p -match '^[A-Za-z]:$' -or $p -match '^\\\\[^\\]+\\[^\\]+$')
}

function Get-ProtectedFolder {
    # The Exchange installation folder and its Mailbox folder (default database location)
    $list = @{}
    if ($env:ExchangeInstallPath) {
        $list[(Get-NormalPath $env:ExchangeInstallPath)] = 'REFUSED: Exchange installation folder'
        $list[(Get-NormalPath (Join-Path $env:ExchangeInstallPath 'Mailbox'))] = 'REFUSED: database or transaction log folder (Exchange Mailbox folder)'
    }
    return $list
}

function Get-FolderScan {
    param([string]$Folder, [datetime]$Cutoff, [string[]]$Extensions, [hashtable]$Seen, [hashtable]$Protected)
    $scan = [pscustomobject]@{
        Folder = $Folder; Exists = $false; Files = @(); Bytes = 0; Oldest = $null; ReadErrors = 0
        Deleted = 0; Failed = 0; Refused = ''
    }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $scan }
    $scan.Exists = $true
    $normal = Get-NormalPath $Folder
    if ($Protected.ContainsKey($normal)) { $scan.Refused = $Protected[$normal]; return $scan }

    $readErrors = @()
    $all = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable readErrors)
    $scan.ReadErrors = @($readErrors).Count
    $database = $null
    $files = @(foreach ($f in $all) {
        $ext = $f.Extension.ToLowerInvariant()
        if ($DatabaseExtensions -contains $ext) { if (-not $database) { $database = $f.FullName }; continue }
        if ($Extensions -notcontains $ext) { continue }
        if ($f.Name -match $TransactionLogPattern) { continue }
        if ($f.LastWriteTime -ge $Cutoff) { continue }
        if ($Seen.ContainsKey($f.FullName)) { continue }    # folders given twice or nested
        $f
    })
    if ($database) {
        $scan.Refused = 'REFUSED: database or transaction log folder ({0})' -f $database
        return $scan
    }
    foreach ($f in $files) {
        $Seen[$f.FullName] = $true
        $scan.Bytes += $f.Length
        if ($null -eq $scan.Oldest -or $f.LastWriteTime -lt $scan.Oldest) { $scan.Oldest = $f.LastWriteTime }
    }
    $scan.Files = $files
    return $scan
}

function ConvertTo-ReportRow {
    param($Scan)
    $oldest = ''
    if ($Scan.Oldest) { $oldest = $Scan.Oldest.ToString('yyyy-MM-dd HH:mm') }
    $note = ''
    if (-not $Scan.Exists) { $note = 'folder does not exist' }
    elseif ($Scan.Refused) { $note = $Scan.Refused }
    elseif ($Scan.ReadErrors -gt 0) { $note = '{0} items could not be read' -f $Scan.ReadErrors }
    return [pscustomobject]@{
        Folder = $Scan.Folder; Exists = $Scan.Exists; FilesToDelete = $Scan.Files.Count; SizeMB = (ConvertTo-MB $Scan.Bytes)
        Oldest = $oldest; Deleted = $Scan.Deleted; Failed = $Scan.Failed; Note = $note
    }
}

function Remove-OldFile {
    # Deletes the files of one folder, returns one result per file
    param($Scan)
    foreach ($f in $Scan.Files) {
        $result = [pscustomobject]@{
            Path = $f.FullName; LastWriteTime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); Bytes = $f.Length
            Result = 'Deleted'; Error = ''
        }
        try {
            Remove-Item -LiteralPath $f.FullName -ErrorAction Stop -Confirm:$false -WhatIf:$false
        } catch {
            $result.Result = 'Failed'
            $result.Error = $_.Exception.Message
        }
        $result
    }
}

function Save-FileList {
    param($Items, [string]$Name, [string[]]$Columns)
    if (@($Items).Count -eq 0) { return }
    $file = Join-Path $LogPath ('{0}-{1}.csv' -f $Name, $script:Stamp)
    $Items | Select-Object $Columns | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
    Out-Line (Format-Row $Name $file) 'Cyan'
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to delete)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is deleted)' }
    elseif ($Fix) { $modeText = '-Fix' }

    $folders = $Path
    if (-not $folders) {
        if (-not $env:ExchangeInstallPath) {
            Out-Line 'ExchangeInstallPath is not set: this is not an Exchange server. Use -Path to choose the folders.' 'Red'
            return $EXIT_NOT_RUN
        }
        $folders = Get-DefaultFolder
    }
    foreach ($f in $folders) {
        if (Test-RootFolder $f) {
            Out-Line ('{0} is the root of a drive or share. Choose the log folder itself.' -f $f) 'Red'
            return $EXIT_NOT_RUN
        }
    }
    $extensions = @(Get-ExtensionList $Extension)
    if ($extensions.Count -eq 0) {
        Out-Line 'No file extension to look for. Check -Extension.' 'Red'
        return $EXIT_NOT_RUN
    }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)

    Out-Line 'Exchange and IIS log cleanup' 'White'
    Out-Line (Format-Row 'Computer' $env:COMPUTERNAME)
    Out-Line (Format-Row 'Retention' ('{0} days (files written before {1})' -f $RetentionDays, $cutoff.ToString('yyyy-MM-dd HH:mm')))
    Out-Line (Format-Row 'Extensions' ($extensions -join ', '))
    Out-Line (Format-Row 'Mode' $modeText)
    Out-Line ''
    Out-Line 'Reading the folders ...' 'DarkGray'

    $seen = @{}
    $protected = Get-ProtectedFolder
    $scans = @(foreach ($f in $folders) {
        Get-FolderScan -Folder $f -Cutoff $cutoff -Extensions $extensions -Seen $seen -Protected $protected
    })
    $script:Folders = $scans

    $results = @()
    if ($Fix) {
        foreach ($s in @($scans | Where-Object { $_.Files.Count -gt 0 })) {
            $action = 'Delete {0} files ({1} MB) older than {2} days' -f $s.Files.Count, (ConvertTo-MB $s.Bytes), $RetentionDays
            if (-not $Cmdlet.ShouldProcess($s.Folder, $action)) { continue }
            $r = @(Remove-OldFile $s)
            $s.Deleted = @($r | Where-Object { $_.Result -eq 'Deleted' }).Count
            $s.Failed = @($r | Where-Object { $_.Result -eq 'Failed' }).Count
            $results += $r
            $color = 'Green'
            if ($s.Failed -gt 0) { $color = 'Yellow' }
            Out-Line ('  {0}: {1} deleted, {2} failed' -f $s.Folder, $s.Deleted, $s.Failed) $color
        }
    }

    $rows = @($scans | ForEach-Object { ConvertTo-ReportRow $_ })
    $columns = @('Folder', 'Exists', 'FilesToDelete', 'SizeMB', 'Oldest')
    if ($Fix -and -not $WhatIfPreference) { $columns += @('Deleted', 'Failed') }
    $columns += 'Note'
    Out-Line ''
    Out-Line (($rows | Format-Table $columns -AutoSize | Out-String -Width 4096).TrimEnd())

    $totalFiles = 0
    $totalBytes = 0
    $deleted = 0
    $failed = 0
    foreach ($s in $scans) { $totalFiles += $s.Files.Count; $totalBytes += $s.Bytes; $deleted += $s.Deleted; $failed += $s.Failed }
    $pending = $totalFiles - $deleted - $failed

    Out-Line ''
    Out-Line ('Total: {0} files, {1} MB older than {2} days in {3} folders' -f
        $totalFiles, (ConvertTo-MB $totalBytes), $RetentionDays, $scans.Count) 'White'
    if ($Fix -and -not $WhatIfPreference) {
        Out-Line ('Deleted: {0} files, failed: {1}, not deleted: {2}' -f $deleted, $failed, $pending) 'White'
    }
    foreach ($s in @($scans | Where-Object { $_.ReadErrors -gt 0 })) {
        Out-Line ('{0}: {1} items could not be read (access denied?). Their files are not counted.' -f $s.Folder, $s.ReadErrors) 'Yellow'
    }

    if ($results.Count -gt 0) {
        if (-not $script:LogPath) {
            $script:LogPath = Get-DefaultOutputFolder
        }
        New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false -Confirm:$false | Out-Null
        Save-FileList @($results | Where-Object { $_.Result -eq 'Deleted' }) 'deleted-files' @('Path', 'LastWriteTime', 'Bytes')
        Save-FileList @($results | Where-Object { $_.Result -eq 'Failed' }) 'failed-files' @('Path', 'LastWriteTime', 'Bytes', 'Error')
    }

    $refused = @($scans | Where-Object { $_.Refused })
    if ($refused.Count -gt 0) {
        foreach ($s in $refused) { Out-Line ('{0}: {1}' -f $s.Folder, $s.Refused) 'Red' }
        Out-Line 'Nothing was deleted in the refused folders. Exchange databases and transaction logs are never cleaned by this script.' 'Red'
        return $EXIT_NOT_RUN
    }
    if ($failed -gt 0) {
        Out-Line 'Some files could not be deleted, usually because they are in use. Run the script again later.' 'Yellow'
        return $EXIT_CHECK
    }
    if ($pending -gt 0) {
        if ($Fix -and $WhatIfPreference) { Out-Line 'WhatIf: nothing was deleted.' 'Yellow' }
        elseif (-not $Fix) { Out-Line 'Run again with -Fix to delete them (add -WhatIf to preview).' 'Yellow' }
        return $EXIT_ACTION
    }
    if ($totalFiles -eq 0) { Out-Line 'Nothing to delete.' 'Green' }
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
        $transcript = Join-Path $LogPath ('transcript-{0}.txt' -f $script:Stamp)
        Start-Transcript -LiteralPath $transcript -WhatIf:$false -Confirm:$false | Out-Null
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Out-Line ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($script:Folders.Count -gt 0) {
        try {
            if (-not $OutputPath) {
                $OutputPath = Get-DefaultOutputFolder
                $OutputPath = Join-Path $OutputPath $script:Stamp
            }
            New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null
            $csv = Join-Path $OutputPath 'results.csv'
            $script:Folders | ForEach-Object { ConvertTo-ReportRow $_ } |
                Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
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
