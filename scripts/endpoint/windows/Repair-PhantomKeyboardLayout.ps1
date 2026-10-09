#Requires -Version 5.1

<#
.SYNOPSIS
    Finds keyboard layouts in the input switcher that are not in the user language list. Removes them with -Fix.

.DESCRIPTION
    A keyboard layout can show in the language bar and in the Win+Space input switcher although its
    language is not in the user language list (Settings > Time & language > Language). Typical causes
    are remote desktop sessions that bring the keyboard of the client, language packs and images
    built with another default language. The layout cannot be removed in Settings because the
    language is not listed there.

    Detection, for the current user only:
      - HKCU:\Keyboard Layout\Preload holds the layouts of the input switcher (values 1, 2, 3 ...,
        each an 8-hex-digit keyboard layout ID such as 0000040d, 00000409 or d0010409).
        The low 4 hex digits are the language (0809 = English (United Kingdom)), also for a
        substituted layout such as d0010809.
      - Get-WinUserLanguageList gives the user languages. Each language tag is mapped to its
        language ID with [cultureinfo] (en-GB -> 0809, a neutral tag such as he -> 040d), and the
        language IDs of its input methods (InputMethodTips) are added.
      - A Preload layout whose language is not in that set is a phantom layout.

    Scope: the check compares languages only. A wrong keyboard under a language that is in the list
    (for example the United Kingdom keyboard under English (United States)) is not detected: remove it
    in Settings under that language. The logon screen layouts (HKEY_USERS\.DEFAULT) are not checked.

    Without -Fix the script only reports. With -Fix, for each phantom language (and each
    -LanguageTag), it adds the language to the user language list and removes it again, the way
    Settings would. Windows then removes the keyboard layouts of that language. The script never
    removes a language that was in the list before the run and never leaves the list empty.
    Then it checks again. -WhatIf shows the changes without making them. Every run with -Fix writes a
    transcript.

    Run it as the affected user, in that user's session, without elevation: it changes only the
    settings of the user who runs it. When a layout still shows after -Fix, sign out and sign in again.

    The check uses only cmdlets and [cultureinfo], which Constrained Language Mode allows.
    Requirements: Windows 8 / Windows Server 2012 or later (International module).

.PARAMETER LanguageTag
    Add and remove these languages with -Fix even when no phantom layout is detected, for example
    en-GB. A language that is in the user language list is skipped.

.PARAMETER Fix
    Add and remove the languages. Without it the script is read-only.

.PARAMETER LogPath
    Folder for the CSV report and the transcript.
    Default: %USERPROFILE%\InfraToolkit-Output\Repair-PhantomKeyboardLayout\<timestamp>

.EXAMPLE
    .\Repair-PhantomKeyboardLayout.ps1
    Report only.

.EXAMPLE
    .\Repair-PhantomKeyboardLayout.ps1 -Fix
    Remove the phantom layouts found. Add -Confirm to be asked before each language.

.EXAMPLE
    .\Repair-PhantomKeyboardLayout.ps1 -Fix -LanguageTag en-GB
    Add and remove English (United Kingdom) even when it is not detected.

.NOTES
    Mode: Read-only (changes with -Fix)
    Network: none
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = no phantom layout (or fixed), 1 = phantom layout found or still present after -Fix,
                or the user language list changed, 3 = the script could not run.
    Changes the settings of the current user only. No elevation needed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$LanguageTag,

    [switch]$Fix,

    [string]$LogPath = (Join-Path $env:USERPROFILE ('InfraToolkit-Output\{0}\{1}' -f
        ($MyInvocation.MyCommand.Name -replace '\.ps1$', ''), (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

$PreloadKey   = 'HKCU:\Keyboard Layout\Preload'
$EXIT_OK      = 0
$EXIT_ACTION  = 1
$EXIT_NOT_RUN = 3

$script:ExitCode = $EXIT_NOT_RUN

# ------------------------------------------------------------------ helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function ConvertFrom-Hex {
    param([string]$Hex)
    [int64]$n = 0
    foreach ($c in $Hex.ToLowerInvariant().ToCharArray()) { $n = $n * 16 + '0123456789abcdef'.IndexOf([string]$c) }
    return $n
}

function Get-TagLanguageId {
    # Language tag -> 4-hex-digit language IDs: the culture, and the specific culture of a neutral tag
    param([string]$Tag)
    $ids = @()
    foreach ($kind in 'culture', 'specific') {
        try {
            if ($kind -eq 'culture') { $c = [cultureinfo]$Tag } else { $c = [cultureinfo]::CreateSpecificCulture($Tag) }
            # 4096 = no LCID (custom culture), 127 = invariant culture. A neutral culture (he = 000d) is never
            # the language of a keyboard layout: its specific culture (he-IL = 040d) is used instead.
            if ($c.IsNeutralCulture) { continue }
            if ($c.LCID -gt 0 -and $c.LCID -ne 4096 -and $c.LCID -ne 127) { $ids += ('{0:x4}' -f $c.LCID) }
        } catch {
            Write-Verbose ('No culture for {0}: {1}' -f $Tag, $_.Exception.Message)
        }
    }
    return @($ids | Select-Object -Unique)
}

function Get-LanguageInfo {
    # 4-hex-digit language ID -> tag and name, empty when Windows does not know the ID
    param([string]$LanguageId)
    try {
        $c = [cultureinfo]::GetCultureInfo([int](ConvertFrom-Hex $LanguageId))
        return [pscustomobject]@{ Tag = $c.Name; Name = $c.DisplayName }
    } catch {
        return [pscustomobject]@{ Tag = ''; Name = '(unknown language)' }
    }
}

function Get-LanguageIdSet {
    # Language IDs of one user language: its tag and the language part of its input methods (0409:00000809 -> 0409)
    param($Language)
    $ids = @(Get-TagLanguageId ([string]$Language.LanguageTag))
    foreach ($tip in @($Language.InputMethodTips)) {
        if ([string]$tip -match '^([0-9a-fA-F]{4}):') { $ids += $Matches[1].ToLowerInvariant() }
    }
    return @($ids | Select-Object -Unique)
}

# ------------------------------------------------------------------ detection
function Get-PreloadEntry {
    $item = Get-ItemProperty -LiteralPath $PreloadKey -ErrorAction SilentlyContinue
    $entries = @()
    if ($item) {
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -notmatch '^\d+$') { continue }
            $klid = ([string]$p.Value).Trim().ToLowerInvariant()
            if ($klid -notmatch '^[0-9a-f]{8}$') {
                Write-Verbose ('Preload value {0} = {1} is not a keyboard layout ID' -f $p.Name, $p.Value)
                continue
            }
            $entries += [pscustomobject]@{ Slot = [int]$p.Name; Klid = $klid; LanguageId = $klid.Substring(4) }
        }
    }
    return @($entries | Sort-Object Slot)
}

function Get-Assessment {
    # Get-WinUserLanguageList returns one List object: keep it whole, enumerate it with foreach
    $list = Get-WinUserLanguageList
    $known = @{}
    $listKeys = @{}
    $tags = @()
    foreach ($l in $list) {
        $tags += [string]$l.LanguageTag
        $ids = @(Get-LanguageIdSet $l)
        foreach ($id in $ids) { $known[$id] = $true; $listKeys[$id] = $true }
        # A language without any language ID is compared by its tag
        if ($ids.Count -eq 0) { $listKeys[('tag:' + ([string]$l.LanguageTag).ToLowerInvariant())] = $true }
    }
    $rows = @()
    foreach ($e in (Get-PreloadEntry)) {
        $info = Get-LanguageInfo $e.LanguageId
        $status = 'OK'
        if (-not $known.ContainsKey($e.LanguageId)) { $status = 'PHANTOM' }
        $rows += [pscustomobject]@{
            Slot = $e.Slot; KLID = $e.Klid; LanguageId = $e.LanguageId
            Language = $info.Tag; Name = $info.Name; Status = $status
        }
    }
    return [pscustomobject]@{ Tags = $tags; KnownIds = $known; ListKey = (@($listKeys.Keys | Sort-Object) -join ','); Rows = $rows }
}

function Write-LayoutTable {
    param($Rows)
    if (@($Rows).Count -eq 0) { Out-Line ' (no keyboard layouts in Preload)'; return }
    Out-Line ((@($Rows) | Format-Table Slot, KLID, Language, Name, Status -AutoSize | Out-String -Width 200).TrimEnd())
}

# ------------------------------------------------------------------ change (-Fix)
function Test-OriginalLanguage {
    # True for a language of the list before the run: same tag, or one of its language IDs
    param($Language, $Before)
    if ($Before.Tags -contains [string]$Language.LanguageTag) { return $true }
    foreach ($id in (Get-LanguageIdSet $Language)) { if ($Before.KnownIds.ContainsKey($id)) { return $true } }
    return $false
}

function Invoke-LanguageCycle {
    # Add the language, then set the list back to the languages from before the run.
    # A target language never shares a language ID with them (phantom, or skipped when listed).
    param([string]$Tag, $Before)
    $list = Get-WinUserLanguageList
    $list.Add($Tag)
    Set-WinUserLanguageList -LanguageList $list -Force
    Out-Line ('  Added {0}' -f $Tag)

    $list = Get-WinUserLanguageList
    $keep = @()
    foreach ($l in $list) { if (Test-OriginalLanguage $l $Before) { $keep += $l } }
    if ($keep.Count -eq 0) { throw ('The language list would be empty, {0} was not removed. Remove it in Settings.' -f $Tag) }
    Set-WinUserLanguageList -LanguageList $keep -Force
    Out-Line ('  Removed {0}' -f $Tag)
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    param($Cmdlet)
    $modeText = 'Report only (use -Fix to change)'
    if ($Fix -and $WhatIfPreference) { $modeText = '-Fix -WhatIf (nothing is changed)' }
    elseif ($Fix) { $modeText = '-Fix' }

    Out-Line 'Phantom keyboard layouts' 'White'
    Out-Line (' User : {0}' -f $env:USERNAME)
    Out-Line (' Mode : {0}' -f $modeText)

    foreach ($cmd in 'Get-WinUserLanguageList', 'Set-WinUserLanguageList') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Out-Line ('{0} is not available. This script needs Windows 8 / Windows Server 2012 or later.' -f $cmd) 'Red'
            return $EXIT_NOT_RUN
        }
    }
    foreach ($t in @($LanguageTag | Where-Object { $null -ne $_ })) {
        if ($t -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') {
            Out-Line ('-LanguageTag {0} is not a language tag (example: en-GB).' -f $t) 'Red'
            return $EXIT_NOT_RUN
        }
    }

    $before = Get-Assessment
    Out-Line (' Language list : {0}' -f ($before.Tags -join ', '))
    Out-Line ''
    Out-Line 'Keyboard layouts in the input switcher (HKCU\Keyboard Layout\Preload)' 'White'
    Write-LayoutTable $before.Rows

    # Languages to add and remove: phantom ones first, then -LanguageTag
    $targets = @()
    $unknown = @()
    foreach ($r in @($before.Rows | Where-Object { $_.Status -eq 'PHANTOM' })) {
        if (-not $r.Language) { $unknown += $r; continue }
        if (@($targets | Where-Object { $_.Tag -eq $r.Language }).Count -eq 0) {
            $targets += [pscustomobject]@{ Tag = $r.Language; Reason = ('phantom layout {0}' -f $r.KLID); Skip = '' }
        }
    }
    foreach ($t in @($LanguageTag | Where-Object { $null -ne $_ })) {
        if (@($targets | Where-Object { $_.Tag -eq $t }).Count -gt 0) { continue }
        $skip = ''
        $inList = ($before.Tags -contains $t)
        foreach ($id in (Get-TagLanguageId $t)) { if ($before.KnownIds.ContainsKey($id)) { $inList = $true } }
        if ($inList) { $skip = 'in the language list, not removed' }
        $targets += [pscustomobject]@{ Tag = $t; Reason = '-LanguageTag'; Skip = $skip }
    }

    $phantomCount = @($before.Rows | Where-Object { $_.Status -eq 'PHANTOM' }).Count
    $rows = $before.Rows
    $listChanged = $false

    if ($targets.Count -gt 0) {
        Out-Line ''
        Out-Line 'Languages to add and remove again' 'White'
        foreach ($t in $targets) {
            if ($t.Skip) { Out-Line ('  {0} ({1}): skipped, {2}' -f $t.Tag, $t.Reason, $t.Skip) 'Yellow' }
            else { Out-Line ('  {0} ({1})' -f $t.Tag, $t.Reason) }
        }
    }
    foreach ($u in $unknown) {
        Out-Line ('  {0}: language {1} is unknown to Windows, cannot be removed this way.' -f $u.KLID, $u.LanguageId) 'Yellow'
    }

    $todo = @($targets | Where-Object { -not $_.Skip })
    if ($Fix -and $todo.Count -gt 0) {
        Out-Line ''
        Out-Line 'Changes' 'White'
        foreach ($t in $todo) {
            if ($Cmdlet.ShouldProcess($t.Tag, 'Add the language to the user language list and remove it again')) {
                try {
                    Invoke-LanguageCycle -Tag $t.Tag -Before $before
                } catch {
                    Out-Line ('  FAILED {0}: {1}' -f $t.Tag, $_.Exception.Message) 'Red'
                }
            }
        }

        if (-not $WhatIfPreference) {
            $after = Get-Assessment
            # The language list must hold the same languages as before the run (compared by language ID,
            # so a tag that Windows reports in another form, he-IL / he, is the same language)
            $listChanged = ($after.ListKey -ne $before.ListKey)
            $final = @()
            foreach ($r in $before.Rows) {
                $row = $r | Select-Object Slot, KLID, LanguageId, Language, Name, Status
                if ($r.Status -eq 'PHANTOM') {
                    $row.Status = 'REMOVED'
                    if (@($after.Rows | Where-Object { $_.Status -eq 'PHANTOM' -and $_.LanguageId -eq $r.LanguageId }).Count -gt 0) { $row.Status = 'STILL PRESENT' }
                }
                $final += $row
            }
            foreach ($a in @($after.Rows | Where-Object { $_.Status -eq 'PHANTOM' })) {
                if (@($before.Rows | Where-Object { $_.LanguageId -eq $a.LanguageId }).Count -eq 0) { $final += $a }
            }
            $rows = $final
            $phantomCount = @($rows | Where-Object { $_.Status -in 'PHANTOM', 'STILL PRESENT' }).Count

            Out-Line ''
            Out-Line 'After the changes' 'White'
            Out-Line (' Language list : {0}' -f ($after.Tags -join ', '))
            Write-LayoutTable $rows
            if ($listChanged) {
                Out-Line ('The language list is not the same as before the run ({0}). Check it in Settings > Time & language.' -f ($before.Tags -join ', ')) 'Red'
            }
        } else {
            Out-Line 'WhatIf: nothing was changed.' 'Yellow'
        }
    } elseif ($Fix) {
        Out-Line ''
        Out-Line 'Nothing to change.' 'Green'
    }

    $csv = Join-Path $LogPath 'keyboard-layouts.csv'
    @($rows | Select-Object Slot, KLID, Language, Name, Status) |
        Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false

    $code = $EXIT_OK
    if ($phantomCount -gt 0 -or $listChanged) { $code = $EXIT_ACTION }
    Out-Line ''
    if ($listChanged) {
        Out-Line 'RESULT: USER LANGUAGE LIST CHANGED (check Settings > Time & language)' 'Red'
    } elseif ($code -eq $EXIT_OK) {
        Out-Line 'RESULT: NO PHANTOM LANGUAGE IN THE KEYBOARD LIST (HKCU Preload)' 'Green'
    } else {
        Out-Line 'RESULT: PHANTOM LANGUAGE IN THE KEYBOARD LIST (HKCU Preload)' 'Red'
    }
    if ($Fix -and -not $WhatIfPreference -and $todo.Count -gt 0) {
        Out-Line 'If a layout still shows in the input switcher, sign out and sign in again.' 'Yellow'
    } elseif ($code -eq $EXIT_ACTION -and -not $Fix) {
        Out-Line 'Run again with -Fix to remove the phantom layouts.'
    } elseif ($code -eq $EXIT_ACTION -and $WhatIfPreference) {
        Out-Line 'Run again with -Fix and without -WhatIf to apply the changes.'
    }
    Out-Line ('Report: {0}' -f $csv) 'Cyan'
    return $code
}

$transcript = $null
try {
    New-Item -ItemType Directory -Path $LogPath -Force -WhatIf:$false -Confirm:$false | Out-Null
    if ($Fix -and -not $WhatIfPreference) {
        $transcript = Join-Path $LogPath 'transcript.txt'
        Start-Transcript -LiteralPath $transcript -WhatIf:$false -Confirm:$false | Out-Null
    }
    $result = @(Invoke-Main -Cmdlet $PSCmdlet)
    $script:ExitCode = [int]$result[-1]
} catch {
    Out-Line ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $script:ExitCode = $EXIT_NOT_RUN
} finally {
    if ($transcript) {
        Out-Line ('Transcript: {0}' -f $transcript) 'Cyan'
        Stop-Transcript | Out-Null
    }
}
exit $script:ExitCode
