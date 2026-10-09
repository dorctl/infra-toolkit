#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Repair-PhantomKeyboardLayout.ps1 - detection, exit codes and -Fix against a mocked user profile.

.DESCRIPTION
    Get-WinUserLanguageList, Set-WinUserLanguageList and the HKCU Preload read are replaced by global
    functions backed by an in-memory scenario. Like Windows, the mocked Set rebuilds Preload from the
    language list (unless the scenario keeps it, as when a sign-out is needed). No Windows system is
    needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Repair-PhantomKeyboardLayout.ps1'
    $script:PreloadPath = 'HKCU:\Keyboard Layout\Preload'

    # A user language as Get-WinUserLanguageList returns it. Default input method: the keyboard of the language.
    function global:New-KbdLanguage {
        param([string]$Tag, [string[]]$Tips)
        if (-not $Tips) {
            $id = '{0:X4}' -f ([cultureinfo]::CreateSpecificCulture($Tag)).LCID
            $Tips = @('{0}:0000{0}' -f $id)
        }
        return [pscustomobject]@{ LanguageTag = $Tag; InputMethodTips = @($Tips) }
    }

    function script:Register-KbdMock {
        # One List object, like the cmdlet (so that $list.Add() works in the script)
        function global:Get-WinUserLanguageList {
            [CmdletBinding()] param()
            if ($global:KbdScenario.GetThrows) { throw $global:KbdScenario.GetThrows }
            $l = New-Object 'System.Collections.Generic.List[object]'
            foreach ($x in $global:KbdScenario.List) {
                $tag = $x.LanguageTag
                # RenameOnRead: after the first Set, he-IL is reported as "he" (same language, other tag form)
                if ($global:KbdScenario.RenameOnRead -and $global:KbdScenario.SetCalls.Count -gt 0 -and $tag -eq 'he-IL') { $tag = 'he' }
                $l.Add([pscustomobject]@{ LanguageTag = $tag; InputMethodTips = @($x.InputMethodTips) })
            }
            Write-Output -NoEnumerate -InputObject $l
        }

        # Strings (added with $list.Add) become language objects. Preload follows the new list unless Sticky.
        function global:Set-WinUserLanguageList {
            [CmdletBinding()]
            param([Parameter(Mandatory, Position = 0)] $LanguageList, [switch]$Force)
            $s = $global:KbdScenario
            $new = @(foreach ($x in $LanguageList) { if ($x -is [string]) { New-KbdLanguage $x } else { $x } })
            $s.SetCalls += , @($new | ForEach-Object { $_.LanguageTag })
            if (-not $Force) { throw 'Set-WinUserLanguageList without -Force asks for confirmation' }
            if ($s.FailSet -and $s.SetCalls.Count -eq $s.FailSet) { throw 'Simulated failure of Set-WinUserLanguageList' }
            if ($s.ReplaceOnAdd -and $s.SetCalls.Count -eq 1) { $new = @($new | Where-Object { $_.LanguageTag -eq $s.ReplaceOnAdd }) }
            $s.List = $new
            if (-not $s.Sticky) {
                $p = [ordered]@{}
                foreach ($l in $new) {
                    $k = 0
                    foreach ($tip in @($l.InputMethodTips)) {
                        if ($tip -notmatch '^([0-9A-Fa-f]{4}):') { continue }
                        $prefix = '0000'
                        if ($k -gt 0) { $prefix = 'd{0:x3}' -f $k }
                        $p[[string]($p.Count + 1)] = ($prefix + $Matches[1]).ToLowerInvariant()
                        $k++
                    }
                }
                $s.Preload = $p
            }
        }

        function global:Get-ItemProperty {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string[]]$Name)
            $p = @(@($LiteralPath) + @($Path) | Where-Object { $_ })[0]
            if ($p -like 'HKCU:*') {
                $global:KbdScenario.Reads += $p
                if ($p -ne 'HKCU:\Keyboard Layout\Preload' -or $null -eq $global:KbdScenario.Preload) { return }
                $o = [ordered]@{}
                foreach ($k in $global:KbdScenario.Preload.Keys) { $o[$k] = $global:KbdScenario.Preload[$k] }
                $o['PSPath'] = 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Keyboard Layout\Preload'
                $o['PSParentPath'] = 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Keyboard Layout'
                $o['PSChildName'] = 'Preload'
                return [pscustomobject]$o
            }
            Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
        }
    }
    Register-KbdMock

    function script:Invoke-Scenario {
        param(
            [object[]]$Languages = @('he-IL', 'en-US'),
            [string[]]$Preload = @('0000040d', '00000409'),
            [switch]$NoPreload,
            [hashtable]$Params = @{},
            [hashtable]$Scenario = @{},
            [string]$ScriptDir
        )
        $list = @(foreach ($l in $Languages) { if ($l -is [string]) { New-KbdLanguage $l } else { $l } })
        $pre = [ordered]@{}
        for ($i = 0; $i -lt $Preload.Count; $i++) { $pre[[string]($i + 1)] = $Preload[$i] }
        if ($NoPreload) { $pre = $null }
        $global:KbdScenario = @{
            List = $list; Preload = $pre; SetCalls = @(); Reads = @()
            Sticky = $false; FailSet = 0; ReplaceOnAdd = ''; RenameOnRead = $false; GetThrows = ''
        }
        foreach ($k in $Scenario.Keys) { $global:KbdScenario[$k] = $Scenario[$k] }
        $originalTags = @($list | ForEach-Object { $_.LanguageTag })

        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($ScriptDir) {
            # A copy of the script, run without -LogPath: the default folder is next to the copy
            $copy = Join-Path $ScriptDir (Split-Path -Leaf $script:Target)
            Copy-Item -LiteralPath $script:Target -Destination $copy -Force
            $output = & $copy @Params *>&1
        } else {
            $output = & $script:Target @Params -LogPath $out *>&1
        }
        $code = $LASTEXITCODE
        $text = (@($output | ForEach-Object { [string]$_ }) -join "`n")
        # With the default folder, the script prints where it wrote
        if ($ScriptDir) {
            $out = Join-Path $ScriptDir 'no-output-folder-printed'
            if ($text -match 'Output folder: ([^\r\n]+)') { $out = $Matches[1].Trim() }
        }

        $csv = Join-Path $out 'keyboard-layouts.csv'
        $rows = @()
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        return [pscustomobject]@{
            ExitCode = $code; Rows = $rows; Out = $out
            Text     = $text
            SetCalls = @($global:KbdScenario.SetCalls)
            Tags     = @($global:KbdScenario.List | ForEach-Object { $_.LanguageTag })
            Original = $originalTags
            Preload  = @($global:KbdScenario.Preload.Values)
        }
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'New-KbdLanguage', 'Get-WinUserLanguageList', 'Set-WinUserLanguageList', 'Get-ItemProperty') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name KbdScenario -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Repair-PhantomKeyboardLayout' {

    Context 'Report only' {

        It 'every layout belongs to a listed language: exit 0' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'RESULT: NO PHANTOM LANGUAGE IN THE KEYBOARD LIST \(HKCU Preload\)'
            $r.Rows.Count | Should -Be 2
            @($r.Rows | Where-Object Status -ne 'OK').Count | Should -Be 0
            ($r.Rows[0].PSObject.Properties.Name -join ',') | Should -Be 'Slot,KLID,Language,Name,Status'
            $r.SetCalls.Count | Should -Be 0
            $global:KbdScenario.Reads | Should -Contain $script:PreloadPath
        }

        It 'en-GB layout without en-GB in the list (he-IL, en-US): phantom, exit 1, nothing changed' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809'
            $r.ExitCode | Should -Be 1
            $r.Text     | Should -Match 'RESULT: PHANTOM LANGUAGE IN THE KEYBOARD LIST \(HKCU Preload\)'
            $row = @($r.Rows | Where-Object Slot -eq '3')[0]
            $row.KLID     | Should -Be '00000809'
            $row.Language | Should -Be 'en-GB'
            $row.Name     | Should -Match 'United Kingdom'
            $row.Status   | Should -Be 'PHANTOM'
            $r.Text       | Should -Match 'en-GB \(phantom layout 00000809\)'
            $r.Text       | Should -Match 'Run again with -Fix'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'substituted layout d0010809 is language 0809: phantom' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', 'd0010809'
            $r.ExitCode | Should -Be 1
            (@($r.Rows | Where-Object KLID -eq 'd0010809')[0]).Language | Should -Be 'en-GB'
        }

        It 'substituted layout of a listed language (d0010409 with en-US): not a phantom' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', 'D0010409'
            $r.ExitCode | Should -Be 0
            (@($r.Rows | Where-Object Slot -eq '3')[0]).KLID | Should -Be 'd0010409'
        }

        It 'neutral tag he (no input methods listed) matches layout 0000040d' {
            $he = [pscustomobject]@{ LanguageTag = 'he'; InputMethodTips = @() }
            $r = Invoke-Scenario -Languages @($he, 'en-US')
            $r.ExitCode | Should -Be 0
        }

        It 'a language counts through its input methods (tag without a culture)' {
            $custom = [pscustomobject]@{ LanguageTag = 'zz'; InputMethodTips = @('0809:00000809') }
            $r = Invoke-Scenario -Languages @('en-US', $custom) -Preload '00000409', '00000809'
            $r.ExitCode | Should -Be 0
        }

        It '-LanguageTag without -Fix: listed as planned, exit 0 when no phantom' {
            $r = Invoke-Scenario -Params @{ LanguageTag = 'en-GB' }
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'en-GB \(-LanguageTag\)'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'no Preload key: nothing to report, exit 0' {
            $r = Invoke-Scenario -NoPreload
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'no keyboard layouts in Preload'
        }

        It 'layout of a language Windows does not know: phantom that -Fix cannot cycle' {
            $r = Invoke-Scenario -Preload '0000040d', '00009999' -Params $FixParams
            $r.ExitCode | Should -Be 1
            $r.Text     | Should -Match 'language 9999 is unknown'
            $r.SetCalls.Count | Should -Be 0
        }
    }

    Context 'Cannot run (exit 3)' {

        It 'language list cmdlets missing' {
            Remove-Item -LiteralPath 'Function:\Set-WinUserLanguageList'
            try {
                $r = Invoke-Scenario
            } finally {
                Register-KbdMock
            }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'Set-WinUserLanguageList is not available'
        }

        It 'invalid -LanguageTag' {
            $r = Invoke-Scenario -Params @{ LanguageTag = 'English UK'; Fix = $true; Confirm = $false }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'is not a language tag'
            $r.SetCalls.Count | Should -Be 0
        }

        It 'unexpected error' {
            $r = Invoke-Scenario -Scenario @{ GetThrows = 'Simulated failure' }
            $r.ExitCode | Should -Be 3
            $r.Text     | Should -Match 'ERROR: Simulated failure'
        }
    }

    Context '-Fix' {

        It 'en-GB phantom: Set twice (add, then the original list), layout removed, exit 0' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 2
            ($r.SetCalls[0] -join ',') | Should -Be 'he-IL,en-US,en-GB'
            ($r.SetCalls[1] -join ',') | Should -Be 'he-IL,en-US'
            ($r.Tags -join ',') | Should -Be ($r.Original -join ',')
            $r.Preload | Should -Not -Contain '00000809'
            (@($r.Rows | Where-Object KLID -eq '00000809')[0]).Status | Should -Be 'REMOVED'
            $r.Text | Should -Match 'sign out and sign in'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeTrue
        }

        It 'two phantom languages: one cycle each, ends with the original list' {
            $r = Invoke-Scenario -Preload '0000040d', '00000809', '00000407', '00000409' -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 4
            ($r.SetCalls[0] -join ',') | Should -Be 'he-IL,en-US,en-GB'
            ($r.SetCalls[2] -join ',') | Should -Be 'he-IL,en-US,de-DE'
            ($r.Tags -join ',') | Should -Be 'he-IL,en-US'
        }

        It 'layout still present after the cycle: STILL PRESENT, exit 1, sign out advice' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params $FixParams -Scenario @{ Sticky = $true }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 2
            (@($r.Rows | Where-Object KLID -eq '00000809')[0]).Status | Should -Be 'STILL PRESENT'
            $r.Text | Should -Match 'sign out and sign in'
        }

        It '-LanguageTag forces the cycle when nothing is detected' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; LanguageTag = 'en-GB' }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 2
            ($r.SetCalls[0] -join ',') | Should -Be 'he-IL,en-US,en-GB'
            ($r.Tags -join ',') | Should -Be 'he-IL,en-US'
        }

        It '-LanguageTag of a listed language is skipped (same tag or same language ID)' {
            $he = [pscustomobject]@{ LanguageTag = 'he'; InputMethodTips = @('040D:0000040D') }
            $r = Invoke-Scenario -Languages @($he, 'en-US') -Params @{ Fix = $true; Confirm = $false; LanguageTag = 'EN-us', 'he-IL' }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 0
            $r.Text | Should -Match 'EN-us \(-LanguageTag\): skipped, in the language list'
            $r.Text | Should -Match 'he-IL \(-LanguageTag\): skipped, in the language list'
            $r.Text | Should -Match 'Nothing to change'
        }

        It 'a phantom detected and also given with -LanguageTag is cycled once' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params @{ Fix = $true; Confirm = $false; LanguageTag = 'en-GB' }
            $r.ExitCode | Should -Be 0
            $r.SetCalls.Count | Should -Be 2
        }

        It 'keeps a listed language whose tag Windows reports in another form' {
            # The second read reports he-IL as "he": it is still kept (same language ID)
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params $FixParams -Scenario @{ RenameOnRead = $true }
            $r.ExitCode | Should -Be 0
            $r.Text     | Should -Match 'RESULT: NO PHANTOM LANGUAGE IN THE KEYBOARD LIST'
            $r.Text     | Should -Not -Match 'not the same as before the run'
            $r.SetCalls.Count | Should -Be 2
            $r.SetCalls[1] | Should -Contain 'en-US'
            @($r.SetCalls[1] | Where-Object { $_ -like 'he*' }).Count | Should -Be 1
            $r.SetCalls[1] | Should -Not -Contain 'en-GB'
        }

        It 'never leaves the list empty' {
            # A broken first Set leaves only the added language: the script must not set an empty list
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params $FixParams -Scenario @{ ReplaceOnAdd = 'en-GB' }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 1
            $r.Text | Should -Match 'would be empty'
            $r.Text | Should -Match 'not the same as before the run'
            $r.Text | Should -Match 'RESULT: USER LANGUAGE LIST CHANGED'
        }

        It 'the second Set fails: the list is reported as changed, exit 1' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params $FixParams -Scenario @{ FailSet = 2 }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'FAILED en-GB: Simulated failure'
            $r.Text | Should -Match 'not the same as before the run'
            $r.Text | Should -Match 'RESULT: USER LANGUAGE LIST CHANGED'
        }

        It '-WhatIf: no Set calls, exit 1, no transcript' {
            $r = Invoke-Scenario -Preload '0000040d', '00000409', '00000809' -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.SetCalls.Count | Should -Be 0
            $r.Text | Should -Match 'WhatIf: nothing was changed'
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
            (@($r.Rows | Where-Object KLID -eq '00000809')[0]).Status | Should -Be 'PHANTOM'
        }

        It 'no phantom: nothing to change, exit 0' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'Nothing to change'
            $r.SetCalls.Count | Should -Be 0
        }
    }

    Context 'Default output folder' {

        It 'without the path parameter: InfraToolkit-Output\Repair-PhantomKeyboardLayout plus a timestamp folder, next to the script, also with -WhatIf' {
            $dir = Join-Path $TestDrive ('Scripts-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
            Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $dir | Out-Null
            $base = Join-Path (Join-Path $dir 'InfraToolkit-Output') 'Repair-PhantomKeyboardLayout'

            $r = Invoke-Scenario -ScriptDir $dir
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 2
            Split-Path -Parent $r.Out | Should -Be $base
            Split-Path -Leaf $r.Out   | Should -Match '^\d{8}-\d{6}$'

            # -WhatIf must not stop the script from finding its folder, and writes only the report
            $r = Invoke-Scenario -ScriptDir $dir -Preload '0000040d', '00000409', '00000809' -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.Rows.Count | Should -Be 3
            $r.SetCalls.Count | Should -Be 0
            Split-Path -Parent $r.Out | Should -Be $base
            Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $r.Out 'transcript.txt') | Should -BeFalse
        }
    }
}
