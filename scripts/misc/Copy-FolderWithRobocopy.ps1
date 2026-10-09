#Requires -Version 5.1

<#
.SYNOPSIS
    Copies a folder with robocopy after a confirmation, with a timestamped log. -WhatIf lists what would be copied.

.DESCRIPTION
    Copies the source folder into the destination folder with robocopy. Before it starts, it prints the
    source, the destination and the full option list, and asks for confirmation (-Confirm:$false skips
    the question). The robocopy output goes to the screen and to a timestamped log (/UNILOG+ /TEE /NP).
    The log is Unicode, so file names in any language are logged correctly. A run that copies (not
    -WhatIf) also writes a transcript next to the log, for the change management record.

    -WhatIf runs robocopy with /L added: it lists what would be copied, and nothing is copied or deleted.

    The destination may not be the source or a folder inside it: the script stops with exit code 3.

    Default options:
      /E            all subfolders, including empty ones
      /COPY:DAT     file data, attributes and timestamps
      /DCOPY:DAT    folder data, attributes and timestamps
      /R:1 /W:3     one retry after 3 seconds for a file that cannot be copied
                    (robocopy's own default is one million retries, 30 seconds apart)
      /XD $RECYCLE.BIN "System Volume Information"
                    skip these two folders: copied from a drive root they fail or are not wanted
    Hidden and system files are copied. To skip them, add /XA:SH through -Options: it skips every file
    that has either attribute (hidden, system, or both), not only files that have both.
    -Options replaces the whole list. Add other robocopy options there, for example /A (only files with
    the Archive attribute), /V (verbose log), /MT:16 (16 threads) or /Z (restartable mode).
    /MIR and /PURGE delete files in the destination that are not in the source, and /MOV and /MOVE delete
    the source files after copying: the script prints a warning before it asks.
    The script sets the log options itself, so /LOG and /UNILOG in -Options are ignored.

    Robocopy exit codes 0 to 7 mean success: 0 nothing to copy, 1 files copied, 2 extra files in the
    destination, 4 mismatched files, or a sum of these. 8 and above mean that some files or folders
    could not be copied.

.PARAMETER Source
    Folder to copy. A local path or a share (\\SRV01\Data).

.PARAMETER Destination
    Target folder. Robocopy creates it when it does not exist.

.PARAMETER Options
    Robocopy options, one per item. A value that follows an option is its own item ('/XD', 'Temp').
    Default: '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:3', '/XD', '$RECYCLE.BIN', 'System Volume Information'

.PARAMETER CopyAll
    Use /COPYALL instead of /COPY:DAT: also copies NTFS permissions, owner and auditing information.
    Needs an elevated session.

.PARAMETER LogPath
    Folder for the robocopy log (robocopy-<yyyyMMdd-HHmmss>.log) and the transcript
    (transcript-<yyyyMMdd-HHmmss>.txt). Default: InfraToolkit-Output\Copy-FolderWithRobocopy in the folder of the
    script (falls back to %TEMP%\InfraToolkit-Output\Copy-FolderWithRobocopy when that folder cannot be written,
    is in OneDrive, or is inside the source folder, so the log is not copied with the data).

.EXAMPLE
    .\Copy-FolderWithRobocopy.ps1 -Source D:\Data -Destination \\SRV01\Backup\Data
    Show the plan, ask for confirmation, then copy.

.EXAMPLE
    .\Copy-FolderWithRobocopy.ps1 -Source D:\Data -Destination \\SRV01\Backup\Data -WhatIf
    List what would be copied (robocopy /L). Nothing is copied.

.EXAMPLE
    .\Copy-FolderWithRobocopy.ps1 -Source D:\Data -Destination E:\Data -CopyAll -Confirm:$false
    Copy with permissions and owner, without the question (elevated session).

.EXAMPLE
    .\Copy-FolderWithRobocopy.ps1 -Source D:\Data -Destination E:\Data -Options '/E', '/COPY:DAT', '/A', '/V', '/R:1', '/W:3', '/XA:SH'
    Copy only files with the Archive attribute, skip hidden and system files, with a verbose log.

.NOTES
    Mode: Changes the destination folder (copies files into it)
    Network: none (only the source and destination paths)
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = robocopy exit code 0-7 (success), 1 = robocopy exit code 8 or higher (some files failed),
                3 = the script could not run (source missing, destination inside the source, robocopy missing,
                cancelled at the question).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Source,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,

    [ValidateNotNull()]
    [string[]]$Options = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:3', '/XD', '$RECYCLE.BIN', 'System Volume Information'),

    [switch]$CopyAll,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$EXIT_OK      = 0
$EXIT_FAILED  = 1
$EXIT_NOT_RUN = 3

$script:Transcript = $null

$RobocopyBits = @(
    @{ Bit = 1;  Text = 'One or more files were copied.'; ListText = 'One or more files would be copied.' }
    @{ Bit = 2;  Text = 'Extra files or folders exist in the destination (not in the source).' }
    @{ Bit = 4;  Text = 'Mismatched files or folders were found (same name, different type).' }
    @{ Bit = 8;  Text = 'Some files or folders could not be copied. See the log.' }
    @{ Bit = 16; Text = 'Serious error: robocopy did not copy anything. See the log.' }
)

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

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-12}: {1}' -f $Label, $Value)
}

function Get-FullPath {
    # Full path without a trailing separator: robocopy reads "C:\My Data\" as C:\My Data" (the \" escapes the quote)
    param([string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full -match '^[A-Za-z]:[\\/]$') { return $full }
    $trimmed = $full.TrimEnd('\', '/')
    if (-not $trimmed) { return $full }
    return $trimmed
}

function Test-SameOrInside {
    # True when Path is Parent or a folder inside it. Case-insensitive, \ and / are the same separator.
    param([string]$Path, [string]$Parent)
    $p = ($Path -replace '[\\/]+', '\').TrimEnd('\').ToLowerInvariant()
    $q = ($Parent -replace '[\\/]+', '\').TrimEnd('\').ToLowerInvariant()
    return ($p -eq $q -or $p.StartsWith($q + '\', [System.StringComparison]::Ordinal))
}

function Format-OptionList {
    # Options as one line, items with spaces in quotes
    param([string[]]$Items)
    $shown = foreach ($i in $Items) { if ($i -match '\s') { '"{0}"' -f $i } else { $i } }
    return (@($shown) -join ' ')
}

function Get-RobocopyOption {
    # Options to use: log options removed (the script sets them), /COPY:x replaced by /COPYALL with -CopyAll
    param([string[]]$Requested, [bool]$All)
    $result = @()
    $copyAllAdded = $false
    foreach ($o in $Requested) {
        $t = ([string]$o).Trim()
        if (-not $t) { continue }
        if ($t -match '^/(UNI)?LOG\+?:') {
            Write-Warning ('{0} is ignored: the script writes the log itself.' -f $t)
            continue
        }
        if ($t -match '^/(TEE|NP)$') { continue }
        if ($All -and $t -match '^/COPY(ALL|:.*)$') {
            if (-not $copyAllAdded) { $result += '/COPYALL'; $copyAllAdded = $true }
            continue
        }
        $result += $t
    }
    if ($All -and -not $copyAllAdded) { $result += '/COPYALL' }
    return $result
}

function Write-RobocopyResult {
    param([int]$Code, [bool]$ListOnly)
    Write-Host ''
    Write-Host (Format-Row 'Exit code' $Code)
    if ($Code -eq 0) {
        Write-Host ' Nothing to copy: the source and the destination are already the same.' -ForegroundColor Green
    }
    foreach ($b in $RobocopyBits) {
        if (($Code -band $b.Bit) -eq 0) { continue }
        $text = $b.Text
        if ($ListOnly -and $b.ListText) { $text = $b.ListText }
        $color = 'Green'
        if ($b.Bit -ge 8) { $color = 'Red' } elseif ($b.Bit -gt 1) { $color = 'Yellow' }
        Write-Host (' {0}' -f $text) -ForegroundColor $color
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param([System.Management.Automation.PSCmdlet]$Cmdlet)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Host ('ERROR: the source folder {0} does not exist or is not a folder.' -f $Source) -ForegroundColor Red
        return $EXIT_NOT_RUN
    }
    if (-not (Get-Command -Name 'robocopy.exe' -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR: robocopy.exe was not found. It is part of Windows (C:\Windows\System32).' -ForegroundColor Red
        return $EXIT_NOT_RUN
    }

    $src = Get-FullPath $Source
    $dst = Get-FullPath $Destination
    if (Test-SameOrInside -Path $dst -Parent $src) {
        Write-Host ('ERROR: the destination {0} is the source or a folder inside it.' -f $dst) -ForegroundColor Red
        return $EXIT_NOT_RUN
    }
    $opts = @(Get-RobocopyOption -Requested $Options -All $CopyAll.IsPresent)

    $logDir = $LogPath
    if (-not $logDir) {
        $scriptRoot = $PSScriptRoot
        if ($scriptRoot -and (Test-SameOrInside -Path (Get-FullPath $scriptRoot) -Parent $src)) {
            Write-Host 'The script folder is inside the source: the log goes to the TEMP folder, so it is not copied.' -ForegroundColor Yellow
            $scriptRoot = ''
        }
        # The log is written under -WhatIf too (robocopy /L): the folder check runs without -WhatIf / -Confirm
        $logDir = & {
            $WhatIfPreference = $false
            $ConfirmPreference = 'None'
            Get-OutputFolder -ScriptRoot $scriptRoot -ScriptName 'Copy-FolderWithRobocopy'
        }
    }
    $logDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($logDir)
    if (Test-SameOrInside -Path $logDir -Parent $src) {
        Write-Warning ('The log folder {0} is inside the source: robocopy copies the log too. Use -LogPath to change it.' -f $logDir)
    }
    New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        throw ('could not create the log folder {0}' -f $logDir)
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $logDir ('robocopy-{0}.log' -f $stamp)
    $logOpts = @(('/UNILOG+:{0}' -f $logFile), '/TEE', '/NP')
    if (-not $WhatIfPreference) {
        $script:Transcript = Join-Path $logDir ('transcript-{0}.txt' -f $stamp)
        Start-Transcript -LiteralPath $script:Transcript -WhatIf:$false -Confirm:$false | Out-Null
    }

    Write-Host 'Robocopy copy' -ForegroundColor Cyan
    Write-Host (Format-Row 'Source' $src)
    Write-Host (Format-Row 'Destination' $dst)
    Write-Host (Format-Row 'Options' (Format-OptionList ($opts + $logOpts)))
    Write-Host (Format-Row 'Log file' $logFile)
    if (@($opts | Where-Object { $_ -match '^/(MIR|PURGE)$' }).Count -gt 0) {
        Write-Warning ('/MIR and /PURGE DELETE files and folders in {0} that do not exist in {1}.' -f $dst, $src)
    }
    if (@($opts | Where-Object { $_ -match '^/MOVE?$' }).Count -gt 0) {
        Write-Warning ('/MOV and /MOVE DELETE the files from {0} after they are copied.' -f $src)
    }

    $listOnly = $false
    if (-not $Cmdlet.ShouldProcess($dst, ('Copy {0} with robocopy {1}' -f $src, (Format-OptionList $opts)))) {
        if (-not $WhatIfPreference) {
            Write-Host 'Cancelled. Nothing was copied.' -ForegroundColor Yellow
            return $EXIT_NOT_RUN
        }
        $listOnly = $true
        Write-Host 'WhatIf: robocopy runs with /L (list only). Nothing is copied or deleted.' -ForegroundColor Cyan
    }

    $arguments = @($src, $dst) + $opts
    if ($listOnly) { $arguments += '/L' }
    $arguments += $logOpts

    Write-Host ''
    & robocopy.exe @arguments | ForEach-Object { Write-Host $_ }
    $code = [int]$LASTEXITCODE

    Write-RobocopyResult -Code $code -ListOnly $listOnly
    Write-Host (Format-Row 'Log file' $logFile) -ForegroundColor Cyan
    if ($code -ge 8) {
        Write-Host ('FAILED: robocopy exit code {0}. Check the log for the files that were not copied.' -f $code) -ForegroundColor Red
        return $EXIT_FAILED
    }
    if ($listOnly) { Write-Host 'List only: nothing was copied.' -ForegroundColor Green }
    else { Write-Host 'Done.' -ForegroundColor Green }
    return $EXIT_OK
}

$exitCode = $EXIT_NOT_RUN
try {
    $exitCode = [int](@(Invoke-Main -Cmdlet $PSCmdlet)[-1])
} catch {
    Write-Host ('ERROR: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $exitCode = $EXIT_NOT_RUN
} finally {
    if ($script:Transcript) {
        Write-Host (Format-Row 'Transcript' $script:Transcript) -ForegroundColor Cyan
        try { Stop-Transcript | Out-Null } catch { Write-Warning ('Could not stop the transcript: {0}' -f $_.Exception.Message) }
    }
}
exit $exitCode
