#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Copy-FolderWithRobocopy.ps1 - robocopy arguments, -WhatIf, exit code mapping and errors.

.DESCRIPTION
    robocopy.exe is replaced by a global function that records its arguments and returns the exit code
    of the scenario. Source and log folders are in TestDrive. Nothing is copied, so the tests run in CI
    on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Copy-FolderWithRobocopy.ps1'
    $script:Defaults = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:3', '/XD', '$RECYCLE.BIN', 'System Volume Information')

    function script:Set-RobocopyMock {
        function global:robocopy.exe {
            $global:RoboScenario.Calls += , @($args)
            '-------------------------------------------------------------------------------'
            '   ROBOCOPY     ::     Robust File Copy for Windows'
            $global:LASTEXITCODE = $global:RoboScenario.ExitCode
        }
    }
    Set-RobocopyMock

    function script:Invoke-Scenario {
        param(
            [int]$RobocopyExit = 1,
            [hashtable]$Params = @{},
            [string]$SourceName = 'source',
            [switch]$NoSource,
            [string]$DestinationName = 'destination'
        )
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $src = Join-Path $root $SourceName
        $dst = Join-Path $root $DestinationName
        $logs = Join-Path $root 'logs'
        if (-not $NoSource) {
            $null = New-Item -ItemType Directory -Path $src -Force
            Set-Content -LiteralPath (Join-Path $src 'file1.txt') -Value 'data'
        }
        $global:RoboScenario = @{ ExitCode = $RobocopyExit; Calls = @() }

        $run = @{ Source = $src; Destination = $dst; LogPath = $logs }
        foreach ($k in $Params.Keys) { $run[$k] = $Params[$k] }
        $text = & $script:Target @run *>&1 | Out-String
        $code = $LASTEXITCODE

        $call = $null
        if ($global:RoboScenario.Calls.Count -gt 0) { $call = @($global:RoboScenario.Calls[0]) }
        return [pscustomobject]@{
            ExitCode = $code; Output = $text; Calls = $global:RoboScenario.Calls.Count; Args = $call
            Source = $src; Destination = $dst; Logs = $logs
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath 'Function:\robocopy.exe' -ErrorAction SilentlyContinue
    Remove-Variable -Name RoboScenario -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Copy-FolderWithRobocopy' {

    Context 'Arguments' {

        It 'defaults: source, destination, default options, then the log options' {
            $r = Invoke-Scenario -Params @{ Confirm = $false }
            $r.ExitCode | Should -Be 0
            $r.Calls    | Should -Be 1
            $r.Args[0]  | Should -Be $r.Source
            $r.Args[1]  | Should -Be $r.Destination
            $r.Args[2..9] | Should -Be $script:Defaults
            $r.Args[10] | Should -Match '^/UNILOG\+:.+[\\/]robocopy-\d{8}-\d{6}\.log$'
            $r.Args[10].Substring(9) | Should -BeLike (Join-Path $r.Logs '*')
            $r.Args[11..12] | Should -Be @('/TEE', '/NP')
            $r.Args.Count | Should -Be 13
            $r.Args     | Should -Not -Contain '/L'
            Test-Path -LiteralPath $r.Logs -PathType Container | Should -BeTrue
        }

        It 'defaults copy hidden and system files (no /XA), the printed list quotes items with spaces' {
            $r = Invoke-Scenario -Params @{ Confirm = $false }
            @($r.Args | Where-Object { $_ -match '^/XA' }).Count | Should -Be 0
            $r.Output | Should -Match 'Options\s+: /E /COPY:DAT /DCOPY:DAT /R:1 /W:3 /XD \$RECYCLE\.BIN "System Volume Information" /UNILOG\+:'
        }

        It 'paths with spaces stay one argument each, trailing separators are removed' {
            $root = Join-Path $TestDrive 'spaces'
            $src = Join-Path $root 'My Source Data'
            $null = New-Item -ItemType Directory -Path $src -Force
            $global:RoboScenario = @{ ExitCode = 1; Calls = @() }
            $dst = Join-Path $root 'My Backup'
            & $script:Target -Source ($src + '\') -Destination ($dst + '/') -LogPath (Join-Path $root 'log dir') -Confirm:$false *> $null
            $LASTEXITCODE | Should -Be 0
            $a = @($global:RoboScenario.Calls[0])
            $a[0] | Should -Be $src
            $a[1] | Should -Be $dst
            $a[-3] | Should -BeLike ('/UNILOG+:' + (Join-Path $root 'log dir') + '*')
        }

        It '-CopyAll replaces /COPY:DAT with /COPYALL and keeps /DCOPY:DAT' {
            $r = Invoke-Scenario -Params @{ Confirm = $false; CopyAll = $true }
            $r.ExitCode | Should -Be 0
            $r.Args[2..9] | Should -Be @('/E', '/COPYALL', '/DCOPY:DAT', '/R:1', '/W:3', '/XD', '$RECYCLE.BIN', 'System Volume Information')
        }

        It '-Options replaces the defaults; -CopyAll adds /COPYALL when no /COPY option is given' {
            $r = Invoke-Scenario -Params @{ Confirm = $false; Options = @('/E', '/A', '/V'); CopyAll = $true }
            $r.Args[2..5] | Should -Be @('/E', '/A', '/V', '/COPYALL')
            $r.Args.Count | Should -Be 9
            $r.Output | Should -Not -Match '/COPY:DAT'
        }

        It '/LOG in -Options is ignored with a warning, the script log is used' {
            $r = Invoke-Scenario -Params @{ Confirm = $false; Options = @('/E', '/LOG:x.log', '/TEE') }
            $r.Output | Should -Match '/LOG:x\.log is ignored'
            @($r.Args | Where-Object { $_ -match '^/(UNI)?LOG' }).Count | Should -Be 1
            @($r.Args | Where-Object { $_ -eq '/TEE' }).Count | Should -Be 1
        }

        It '/MIR prints a delete warning' {
            $r = Invoke-Scenario -Params @{ Confirm = $false; Options = @('/MIR', '/R:1', '/W:3') }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '/MIR and /PURGE DELETE files and folders in .*destination that do not exist in'
            $r.Args[2..4] | Should -Be @('/MIR', '/R:1', '/W:3')
        }

        It '/PURGE and /MOVE print delete warnings too, the defaults do not' {
            $r = Invoke-Scenario -Params @{ Confirm = $false; Options = @('/E', '/purge', '/MOVE') }
            $r.Output | Should -Match '/MIR and /PURGE DELETE'
            $r.Output | Should -Match '/MOV and /MOVE DELETE the files from'
            $r = Invoke-Scenario -Params @{ Confirm = $false }
            $r.Output | Should -Not -Match 'DELETE'
        }
    }

    Context '-WhatIf and -Confirm' {

        It '-WhatIf runs robocopy with /L and copies nothing' {
            $r = Invoke-Scenario -Params @{ WhatIf = $true }
            $r.ExitCode | Should -Be 0
            $r.Calls    | Should -Be 1
            $r.Args     | Should -Contain '/L'
            $r.Args[2..9] | Should -Be $script:Defaults
            $r.Output   | Should -Match 'WhatIf: robocopy runs with /L \(list only\)'
            $r.Output   | Should -Match 'One or more files would be copied'
            $r.Output   | Should -Match 'List only: nothing was copied'
            Test-Path -LiteralPath $r.Destination | Should -BeFalse
            Test-Path -LiteralPath $r.Logs -PathType Container | Should -BeTrue
            @(Get-ChildItem -LiteralPath $r.Logs -Filter 'transcript-*.txt').Count | Should -Be 0
        }

        It '-Confirm:$false runs without /L' {
            $r = Invoke-Scenario -Params @{ Confirm = $false }
            $r.Calls  | Should -Be 1
            $r.Args   | Should -Not -Contain '/L'
            $r.Output | Should -Match 'One or more files were copied'
            $r.Output | Should -Match 'Done\.'
        }

        It 'a run that copies writes a transcript next to the robocopy log' {
            $r = Invoke-Scenario -Params @{ Confirm = $false }
            $transcripts = @(Get-ChildItem -LiteralPath $r.Logs -Filter 'transcript-*.txt')
            $transcripts.Count | Should -Be 1
            $stamp = $transcripts[0].Name -replace '^transcript-(\d{8}-\d{6})\.txt$', '$1'
            $r.Args[10] | Should -BeLike "*robocopy-$stamp.log"
            $text = Get-Content -LiteralPath $transcripts[0].FullName -Raw
            $text | Should -Match 'Robocopy copy'
            $text | Should -Match ([regex]::Escape($r.Source))
            $text | Should -Match 'One or more files were copied'
            $r.Output | Should -Match 'Transcript\s+: '
        }
    }

    Context 'Exit codes' {

        It 'robocopy <Robo> -> exit <Expected>' -TestCases @(
            @{ Robo = 0;  Expected = 0; Text = 'Nothing to copy' }
            @{ Robo = 1;  Expected = 0; Text = 'One or more files were copied' }
            @{ Robo = 2;  Expected = 0; Text = 'Extra files or folders exist in the destination' }
            @{ Robo = 3;  Expected = 0; Text = '(?s)files were copied.*Extra files' }
            @{ Robo = 7;  Expected = 0; Text = '(?s)files were copied.*Extra files.*Mismatched' }
            @{ Robo = 8;  Expected = 1; Text = '(?s)could not be copied.*FAILED: robocopy exit code 8' }
            @{ Robo = 9;  Expected = 1; Text = '(?s)files were copied.*could not be copied' }
            @{ Robo = 16; Expected = 1; Text = '(?s)Serious error.*FAILED: robocopy exit code 16' }
        ) {
            param($Robo, $Expected, $Text)
            $r = Invoke-Scenario -RobocopyExit $Robo -Params @{ Confirm = $false }
            $r.ExitCode | Should -Be $Expected
            $r.Output   | Should -Match $Text
            $r.Output   | Should -Match ('Exit code\s+: {0}' -f $Robo)
        }
    }

    Context 'Could not run (exit 3)' {

        It 'source folder missing: exit 3, robocopy not called' {
            $r = Invoke-Scenario -NoSource -Params @{ Confirm = $false }
            $r.ExitCode | Should -Be 3
            $r.Calls    | Should -Be 0
            $r.Output   | Should -Match 'ERROR: the source folder .* does not exist'
        }

        It 'source is a file, not a folder: exit 3' {
            $file = Join-Path $TestDrive 'a-file.txt'
            Set-Content -LiteralPath $file -Value 'x'
            $global:RoboScenario = @{ ExitCode = 1; Calls = @() }
            & $script:Target -Source $file -Destination (Join-Path $TestDrive 'd') -LogPath (Join-Path $TestDrive 'l') -Confirm:$false *> $null
            $LASTEXITCODE | Should -Be 3
            $global:RoboScenario.Calls.Count | Should -Be 0
        }

        It 'destination is the source: exit 3, nothing run, no transcript' {
            $r = Invoke-Scenario -DestinationName 'source' -Params @{ Confirm = $false }
            $r.ExitCode | Should -Be 3
            $r.Calls    | Should -Be 0
            $r.Output   | Should -Match 'ERROR: the destination .* is the source or a folder inside it'
            Test-Path -LiteralPath $r.Logs | Should -BeFalse
        }

        It 'destination inside the source (other case, other separators): exit 3' {
            $root = Join-Path $TestDrive 'nest'
            $src = Join-Path $root 'Data'
            $null = New-Item -ItemType Directory -Path $src -Force
            $global:RoboScenario = @{ ExitCode = 1; Calls = @() }
            $inside = ($src.ToUpperInvariant() -replace '/', '\') + '\\Backup\'
            $out = & $script:Target -Source $src -Destination $inside -LogPath (Join-Path $root 'logs') -Confirm:$false *>&1 | Out-String
            $LASTEXITCODE | Should -Be 3
            $out | Should -Match 'is the source or a folder inside it'
            $global:RoboScenario.Calls.Count | Should -Be 0
        }

        It 'a sibling folder that only starts with the same name is allowed' {
            $r = Invoke-Scenario -SourceName 'Data' -DestinationName 'Data2' -Params @{ Confirm = $false }
            $r.ExitCode | Should -Be 0
            $r.Calls    | Should -Be 1
        }

        It 'robocopy.exe missing: exit 3' {
            if (Get-Command -Name 'robocopy.exe' -CommandType Application -ErrorAction SilentlyContinue) {
                Set-ItResult -Skipped -Because 'the real robocopy.exe exists on this machine'
            }
            Remove-Item -LiteralPath 'Function:\robocopy.exe'
            try {
                $r = Invoke-Scenario -Params @{ Confirm = $false }
            } finally {
                Set-RobocopyMock
            }
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'ERROR: robocopy\.exe was not found'
        }

        It 'log folder cannot be created: exit 3, robocopy not called' {
            $blocker = Join-Path $TestDrive 'log-blocker'
            Set-Content -LiteralPath $blocker -Value 'file, not a folder'
            $r = Invoke-Scenario -Params @{ Confirm = $false; LogPath = (Join-Path $blocker 'logs') }
            $r.ExitCode | Should -Be 3
            $r.Calls    | Should -Be 0
            $r.Output   | Should -Match 'ERROR:'
        }
    }
}
