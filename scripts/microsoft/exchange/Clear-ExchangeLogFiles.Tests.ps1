#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Clear-ExchangeLogFiles.ps1 - report, -Fix deletes and exit codes against log folders in TestDrive.

.DESCRIPTION
    SystemDrive and ExchangeInstallPath point to folders in TestDrive that hold real files with old and new
    LastWriteTime values. A file in use is simulated with a Pester mock of Remove-Item. No Exchange server is
    needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Clear-ExchangeLogFiles.ps1'

    $script:SavedEnv = @{}
    foreach ($n in 'SystemDrive', 'ExchangeInstallPath') { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }

    function script:New-TestFile {
        param([string]$Path, [int]$AgeDays, [int]$Bytes = 1024)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        [IO.File]::WriteAllBytes($Path, [byte[]]::new($Bytes))
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
        return $Path
    }

    # An Exchange server: IIS logs, Exchange logging, search ETL traces and a database in the Mailbox folder.
    # The search Logs folder does not exist.
    function script:New-TestServer {
        param([string]$Root)
        $sys = Join-Path $Root 'sys'
        $ex = Join-Path $Root 'Exchange Server/V15'
        $env:SystemDrive = $sys
        $env:ExchangeInstallPath = $ex + '/'
        $f = [ordered]@{
            IisOld   = New-TestFile (Join-Path $sys 'inetpub/logs/LogFiles/W3SVC1/u_ex260801.log') 60 (2 * 1MB)
            IisNew   = New-TestFile (Join-Path $sys 'inetpub/logs/LogFiles/W3SVC1/u_ex261008.log') 1
            ProxyOld = New-TestFile (Join-Path $ex 'Logging/HttpProxy/Owa/HttpProxy_2026082001-1.LOG') 50 (1MB)
            BlgOld   = New-TestFile (Join-Path $ex 'Logging/Diagnostics/PerformanceLogsToBeProcessed/ExchangeDiagnosticsPerformanceLog_08201200.blg') 50 (512KB)
            TxtOld   = New-TestFile (Join-Path $ex 'Logging/Diagnostics/readme.txt') 90
            LogNew   = New-TestFile (Join-Path $ex 'Logging/HttpProxy/Owa/HttpProxy_2026100801-1.LOG') 0
            EtlOld   = New-TestFile (Join-Path $ex 'Bin/Search/Ceres/Diagnostics/ETLTraces/trace_08.etl') 10 (512KB)
            EtlEdge  = New-TestFile (Join-Path $ex 'Bin/Search/Ceres/Diagnostics/ETLTraces/trace_10.etl') 5
            DbEdb    = New-TestFile (Join-Path $ex 'Mailbox/DB01/DB01.edb') 60
            DbLog    = New-TestFile (Join-Path $ex 'Mailbox/DB01/E0000000001.log') 60
        }
        $null = New-TestFile (Join-Path $ex 'Mailbox/DB01/E00.chk') 0
        $null = New-TestFile (Join-Path $ex 'Mailbox/DB01/E00.log') 0
        return $f
    }

    function script:New-TestRoot {
        return (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }

    function script:Invoke-Scenario {
        param([hashtable]$Params = @{}, [switch]$NoExchange, [string]$Root = (New-TestRoot), [string]$Script = $script:Target, [switch]$DefaultOutput)
        $root = $Root
        $files = New-TestServer $root
        if ($NoExchange) { $env:ExchangeInstallPath = $null }

        $run = @{ OutputPath = (Join-Path $root 'out'); LogPath = (Join-Path $root 'log') }
        if ($DefaultOutput) { $run = @{} }
        foreach ($k in $Params.Keys) { $run[$k] = $Params[$k] }
        $text = & $Script @run *>&1 | Out-String
        $code = $LASTEXITCODE

        $log = Join-Path $root 'log'
        $csv = Join-Path $root 'out/results.csv'
        $rows = @()
        if (Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        $deleted = @(Get-ChildItem -Path $log -Filter 'deleted-files-*.csv' -ErrorAction SilentlyContinue | ForEach-Object { Import-Csv -LiteralPath $_.FullName })
        $failed = @(Get-ChildItem -Path $log -Filter 'failed-files-*.csv' -ErrorAction SilentlyContinue | ForEach-Object { Import-Csv -LiteralPath $_.FullName })
        return [pscustomobject]@{
            ExitCode = $code; Text = $text; Rows = $rows; Files = $files; Root = $root
            Deleted = $deleted; Failed = $failed
            Transcripts = @(Get-ChildItem -Path $log -Filter 'transcript-*.txt' -ErrorAction SilentlyContinue)
        }
    }

    function script:Get-Remaining {
        param($Result)
        $left = @()
        foreach ($k in $Result.Files.Keys) { if (Test-Path -LiteralPath $Result.Files[$k]) { $left += $k } }
        return ($left | Sort-Object)
    }

    # A copy of the script in its own TestDrive folder, to test the default output folder next to the script
    function script:Copy-TestScript {
        $dir = Join-Path $TestDrive ('copy-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        Copy-Item -LiteralPath $script:Target -Destination $dir
        return (Join-Path $dir (Split-Path -Leaf $script:Target))
    }

    $script:AllFiles = @('BlgOld', 'DbEdb', 'DbLog', 'EtlEdge', 'EtlOld', 'IisNew', 'IisOld', 'LogNew', 'ProxyOld', 'TxtOld')
    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($n in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
}

Describe 'Clear-ExchangeLogFiles' {

    Context 'Report only' {

        It 'old files found: exit 1, per folder report, nothing deleted' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 1
            Get-Remaining $r | Should -Be $script:AllFiles
            $r.Rows.Count | Should -Be 4

            $iis = $r.Rows[0]
            $iis.Folder        | Should -BeLike '*inetpub*logs*LogFiles'
            $iis.Exists        | Should -Be 'True'
            $iis.FilesToDelete | Should -Be 1
            $iis.SizeMB        | Should -Be 2
            $iis.Oldest        | Should -Be (Get-Date).AddDays(-60).ToString('yyyy-MM-dd HH:mm')

            $logging = $r.Rows[1]
            $logging.Folder        | Should -BeLike '*Logging'
            $logging.FilesToDelete | Should -Be 2
            $logging.SizeMB        | Should -Be 1.5

            $r.Rows[2].Folder        | Should -BeLike '*ETLTraces'
            $r.Rows[2].FilesToDelete | Should -Be 1

            $r.Rows[3].Folder | Should -BeLike '*Diagnostics*Logs'
            $r.Rows[3].Exists | Should -Be 'False'
            $r.Rows[3].Note   | Should -Be 'folder does not exist'

            $r.Text | Should -Match 'Total: 4 files, 4 MB older than 7 days in 4 folders'
            $r.Text | Should -Match 'Run again with -Fix'
            $r.Transcripts.Count | Should -Be 0
            $r.Deleted.Count | Should -Be 0
        }

        It 'retention longer than every file: exit 0, nothing to delete' {
            $r = Invoke-Scenario -Params @{ RetentionDays = 365 }
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'Nothing to delete'
            @($r.Rows | Where-Object { $_.FilesToDelete -ne '0' }).Count | Should -Be 0
        }

        It 'retention decides: 7 days keeps the 5 day old trace, 3 days selects it' {
            $r = Invoke-Scenario -Params @{ RetentionDays = 3 }
            ($r.Rows | Where-Object Folder -like '*ETLTraces').FilesToDelete | Should -Be 2
            $r = Invoke-Scenario -Params @{ RetentionDays = 7 }
            ($r.Rows | Where-Object Folder -like '*ETLTraces').FilesToDelete | Should -Be 1
        }

        It 'RetentionDays 0 is rejected' {
            { & $script:Target -RetentionDays 0 -OutputPath (Join-Path $TestDrive 'o') -LogPath (Join-Path $TestDrive 'l') } | Should -Throw
        }
    }

    Context '-Fix' {

        It 'deletes only old files with the listed extensions, keeps folders, writes the lists and a transcript' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            Get-Remaining $r | Should -Be @('DbEdb', 'DbLog', 'EtlEdge', 'IisNew', 'LogNew', 'TxtOld')
            Test-Path -LiteralPath (Split-Path -Parent $r.Files.ProxyOld) | Should -BeTrue
            Test-Path -LiteralPath (Split-Path -Parent $r.Files.BlgOld) | Should -BeTrue

            $r.Deleted.Count | Should -Be 4
            ($r.Deleted.Path | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) |
                Should -Be @('ExchangeDiagnosticsPerformanceLog_08201200.blg', 'HttpProxy_2026082001-1.LOG', 'trace_08.etl', 'u_ex260801.log')
            $r.Failed.Count | Should -Be 0
            $r.Transcripts.Count | Should -Be 1
            ($r.Rows | Where-Object Folder -like '*Logging').Deleted | Should -Be 2
            $r.Text | Should -Match 'Deleted: 4 files, failed: 0'
        }

        It '-WhatIf deletes nothing' {
            $r = Invoke-Scenario -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            Get-Remaining $r | Should -Be $script:AllFiles
            $r.Text | Should -Match 'WhatIf: nothing was deleted'
            $r.Transcripts.Count | Should -Be 0
            $r.Deleted.Count | Should -Be 0
        }

        It 'a file in use: the other files are deleted, the failure is listed, exit 2' {
            # Pester 6 does not fall back to the real command when no -ParameterFilter matches,
            # so one default mock handles both cases (the real cmdlet through its CmdletInfo, no recursion).
            Mock Remove-Item {
                if ($LiteralPath -like '*HttpProxy_2026082001-1.LOG') {
                    throw 'The process cannot access the file because it is being used by another process.'
                }
                & (Get-Command -Name Remove-Item -CommandType Cmdlet) @PesterBoundParameters
            }
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 2
            Get-Remaining $r | Should -Be @('DbEdb', 'DbLog', 'EtlEdge', 'IisNew', 'LogNew', 'ProxyOld', 'TxtOld')
            $r.Deleted.Count | Should -Be 3
            $r.Failed.Count | Should -Be 1
            $r.Failed[0].Path  | Should -BeLike '*HttpProxy_2026082001-1.LOG'
            $r.Failed[0].Error | Should -Match 'being used by another process'
            ($r.Rows | Where-Object Folder -like '*Logging').Failed | Should -Be 1
            $r.Text | Should -Match 'could not be deleted'
        }

        It 'nothing to delete: exit 0 and no lists' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; RetentionDays = 365 }
            $r.ExitCode | Should -Be 0
            Get-Remaining $r | Should -Be $script:AllFiles
            $r.Deleted.Count | Should -Be 0
        }
    }

    Context '-Path and -Extension' {

        It 'only the given folder and extensions are cleaned' {
            $root = New-TestRoot
            $logging = Join-Path $root 'Exchange Server/V15/Logging'
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @($logging); Extension = @('txt', '*.BLG') }
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -Be 1
            $r.Deleted.Count | Should -Be 2
            ($r.Deleted.Path | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) |
                Should -Be @('ExchangeDiagnosticsPerformanceLog_08201200.blg', 'readme.txt')
            Get-Remaining $r | Should -Be @('DbEdb', 'DbLog', 'EtlEdge', 'EtlOld', 'IisNew', 'IisOld', 'LogNew', 'ProxyOld')
        }

        It 'a folder that does not exist is reported, not an error' {
            $root = New-TestRoot
            $r = Invoke-Scenario -Root $root -Params @{ Path = @((Join-Path $root 'missing'), (Join-Path $root 'sys/inetpub/logs/LogFiles')) }
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Exists | Should -Be 'False'
            $r.Rows[0].Note   | Should -Be 'folder does not exist'
            $r.Rows[1].FilesToDelete | Should -Be 1
        }

        It 'a folder given twice or nested is counted once' {
            $root = New-TestRoot
            $iis = Join-Path $root 'sys/inetpub/logs/LogFiles'
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @($iis, (Join-Path $iis 'W3SVC1'), $iis) }
            $r.ExitCode | Should -Be 0
            @($r.Rows | ForEach-Object { [int]$_.FilesToDelete }) | Should -Be @(1, 0, 0)
            $r.Deleted.Count | Should -Be 1
            $r.Failed.Count | Should -Be 0
        }

        It 'no ExchangeInstallPath and no -Path: exit 3, nothing deleted' {
            $r = Invoke-Scenario -NoExchange -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'not an Exchange server. Use -Path'
            Get-Remaining $r | Should -Be $script:AllFiles
            $r.Rows.Count | Should -Be 0
        }

        It 'no ExchangeInstallPath with -Path: runs' {
            $root = New-TestRoot
            $r = Invoke-Scenario -NoExchange -Root $root -Params @{ Path = @(Join-Path $root 'sys/inetpub/logs/LogFiles') }
            $r.ExitCode | Should -Be 1
            $r.Rows.Count | Should -Be 1
            $r.Rows[0].FilesToDelete | Should -Be 1
        }

        It 'the root of the file system is refused: exit 3, nothing deleted' {
            $r = Invoke-Scenario -Params @{ Fix = $true; Confirm = $false; Path = @('/') }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'root of a drive or share'
            Get-Remaining $r | Should -Be $script:AllFiles
        }
    }

    Context 'Exchange databases are protected' {

        It 'transaction logs are never selected, whatever the folder' {
            $root = New-TestRoot
            $logs = Join-Path $root 'LogVolume/DB02'
            $names = 'E00.log', 'E0000000002.log', 'E01000000A1.LOG', 'E00tmp.log', 'E00res00001.log', 'e02res00002.Log'
            foreach ($n in $names) { $null = New-TestFile (Join-Path $logs $n) 60 }
            $other = New-TestFile (Join-Path $logs 'Export-E00.log') 60
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @($logs) }
            $r.ExitCode | Should -Be 0
            $r.Rows[0].FilesToDelete | Should -Be 1
            foreach ($n in $names) { Test-Path -LiteralPath (Join-Path $logs $n) | Should -BeTrue }
            Test-Path -LiteralPath $other | Should -BeFalse
        }

        It 'a folder with database files is refused, the other folders are cleaned, exit 3' {
            $root = New-TestRoot
            $db = Join-Path $root 'Exchange Server/V15/Mailbox/DB01'
            $iis = Join-Path $root 'sys/inetpub/logs/LogFiles'
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @($db, $iis) }
            $r.ExitCode | Should -Be 3
            $r.Rows[0].Note | Should -Match 'REFUSED: database or transaction log folder \(.*(DB01\.edb|E00\.chk)\)'
            $r.Rows[0].FilesToDelete | Should -Be 0
            Get-Remaining $r | Should -Be @('BlgOld', 'DbEdb', 'DbLog', 'EtlEdge', 'EtlOld', 'IisNew', 'LogNew', 'ProxyOld', 'TxtOld')
            $r.Text | Should -Match 'Nothing was deleted in the refused folders'
        }

        It 'a folder whose sub folder holds a database is refused' {
            $root = New-TestRoot
            $parent = Join-Path $root 'Data'
            $null = New-TestFile (Join-Path $parent 'DB03/DB03.edb') 60
            $log = New-TestFile (Join-Path $parent 'DB03/Logs/old.log') 60
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @($parent) }
            $r.ExitCode | Should -Be 3
            $r.Rows[0].Note | Should -BeLike 'REFUSED: database or transaction log folder (*DB03.edb)'
            Test-Path -LiteralPath $log | Should -BeTrue
        }

        It 'the Exchange installation folder is refused' {
            $root = New-TestRoot
            $r = Invoke-Scenario -Root $root -Params @{ Fix = $true; Confirm = $false; Path = @(Join-Path $root 'Exchange Server/V15/') }
            $r.ExitCode | Should -Be 3
            $r.Rows[0].Note | Should -Be 'REFUSED: Exchange installation folder'
            Get-Remaining $r | Should -Be $script:AllFiles
        }

        It 'the Mailbox folder of the installation is refused' {
            $root = New-TestRoot
            $r = Invoke-Scenario -Root $root -Params @{ Path = @(Join-Path $root 'Exchange Server/V15/Mailbox') }
            $r.ExitCode | Should -Be 3
            $r.Rows[0].Note | Should -Be 'REFUSED: database or transaction log folder (Exchange Mailbox folder)'
        }
    }

    Context 'Default output folder' {

        It 'without -OutputPath and -LogPath: report, lists and transcript in InfraToolkit-Output next to the script' {
            $copy = Copy-TestScript
            $base = Join-Path (Join-Path (Split-Path -Parent $copy) 'InfraToolkit-Output') 'Clear-ExchangeLogFiles'
            $r = Invoke-Scenario -Script $copy -DefaultOutput -Params $FixParams
            $r.ExitCode | Should -Be 0
            Get-Remaining $r | Should -Be @('DbEdb', 'DbLog', 'EtlEdge', 'IisNew', 'LogNew', 'TxtOld')
            $stamps = @(Get-ChildItem -LiteralPath $base -Directory)
            $stamps.Count   | Should -Be 1
            $stamps[0].Name | Should -Match '^\d{8}-\d{6}$'
            $csv = Join-Path $stamps[0].FullName 'results.csv'
            @(Import-Csv -LiteralPath $csv).Count | Should -Be 4
            @(Get-ChildItem -LiteralPath $base -Filter 'deleted-files-*.csv').Count | Should -Be 1
            $transcripts = @(Get-ChildItem -LiteralPath $base -Filter 'transcript-*.txt')
            $transcripts.Count | Should -Be 1
            $r.Text | Should -Match ([regex]::Escape($csv))
            $r.Text | Should -Match ([regex]::Escape($transcripts[0].FullName))

            # -WhatIf: the report is still saved, nothing deleted, no transcript and no lists
            $copy = Copy-TestScript
            $base = Join-Path (Join-Path (Split-Path -Parent $copy) 'InfraToolkit-Output') 'Clear-ExchangeLogFiles'
            $r = Invoke-Scenario -Script $copy -DefaultOutput -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            Get-Remaining $r | Should -Be $script:AllFiles
            @(Get-ChildItem -LiteralPath $base -Filter 'results.csv' -Recurse).Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $base -File).Count | Should -Be 0
        }
    }
}
