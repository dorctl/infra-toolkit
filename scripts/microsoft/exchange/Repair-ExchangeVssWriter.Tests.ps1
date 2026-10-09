#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Repair-ExchangeVssWriter.ps1 - verdicts, exit codes and -Fix restarts against a mocked Exchange server.

.DESCRIPTION
    vssadmin.exe, whoami.exe, Get-Service, Restart-Service and Start-Service are replaced by global functions
    backed by an in-memory scenario. vssadmin returns the output of a real server with several writers, in
    English or German. No Windows system is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Repair-ExchangeVssWriter.ps1'
    $script:SavedComputerName = $env:COMPUTERNAME
    $env:COMPUTERNAME = 'EX01'

    # ------------------------------------------------------------------ fake Windows
    function global:whoami.exe {
        if ($global:VssTest.Elevated) { '"Mandatory Label\High Mandatory Level","Label","S-1-16-12288",""' }
        else { '"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192",""' }
        $global:LASTEXITCODE = 0
    }

    function global:vssadmin.exe {
        $t = $global:VssTest
        $t.VssCalls++
        if ($t.VssFail) {
            'vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool'
            '(C) Copyright 2001-2013 Microsoft Corp.'
            ''
            'Error: A Volume Shadow Copy Service component encountered an unexpected error.'
            $global:LASTEXITCODE = 2
            return
        }
        # German output: translated labels and texts, writer names in double quotes
        $labels = @{ Name = 'Writer name'; Id = 'Writer Id'; Instance = 'Writer Instance Id'; State = 'State'; Error = 'Last error'; Quote = "'" }
        $texts = @{}
        if ($t.German) {
            $labels = @{ Name = 'Verfassername'; Id = 'Verfasserkennung'; Instance = 'Verfasserinstanzkennung'; State = 'Status'; Error = 'Letzter Fehler'; Quote = '"' }
            $texts = @{ 'Stable' = 'Stabil'; 'Failed' = 'Fehlgeschlagen'; 'No error' = 'Kein Fehler'; 'Retryable error' = 'Wiederholbarer Fehler'
                'Waiting for completion' = 'Warten auf Abschluss' }
        }
        if ($t.Quote) { $labels.Quote = $t.Quote }
        'vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool'
        '(C) Copyright 2001-2013 Microsoft Corp.'
        ''
        $writers = @($t.Others | Select-Object -First 4)
        if ($t.Writer) { $writers += $t.Writer }
        $writers += @($t.Others | Select-Object -Skip 4)
        foreach ($w in $writers) {
            $stateText = $w.Text
            if ($texts.ContainsKey($stateText)) { $stateText = $texts[$stateText] }
            $errorText = $w.Error
            if ($texts.ContainsKey($errorText)) { $errorText = $texts[$errorText] }
            '{0}: {1}{2}{1}' -f $labels.Name, $labels.Quote, $w.Name
            '   {0}: {{{1}}}' -f $labels.Id, $w.Id
            '   {0}: {{3f1c3b2e-0000-4000-8000-00000000{1:d4}}}' -f $labels.Instance, $w.State
            '   {0}: [{1}] {2}' -f $labels.State, $w.State, $stateText
            '   {0}: {1}' -f $labels.Error, $errorText
            ''
        }
        $global:LASTEXITCODE = 0
    }

    function global:Get-Service {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string[]]$Name)
        foreach ($n in $Name) {
            if (-not $global:VssTest.Services.ContainsKey($n)) {
                Write-Error ("Cannot find any service with service name '{0}'." -f $n)
                continue
            }
            [pscustomobject]@{ Name = $n; Status = $global:VssTest.Services[$n] }
        }
    }

    function global:Set-VssTestServiceStarted {
        param([string]$Name, [string]$Verb)
        $t = $global:VssTest
        $t.Calls += ('{0} {1}' -f $Verb, $Name)
        if ($t.RestartError) { throw $t.RestartError }
        $t.Services[$Name] = $t.StatusAfterStart
        if ($Name -eq 'MSExchangeRepl') { $t.Writer = $t.WriterAfterRestart }
    }

    function global:Restart-Service {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Position = 0)][string[]]$Name, [switch]$Force)
        foreach ($n in $Name) { Set-VssTestServiceStarted -Name $n -Verb 'Restart' }
    }

    function global:Start-Service {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Position = 0)][string[]]$Name)
        foreach ($n in $Name) { Set-VssTestServiceStarted -Name $n -Verb 'Start' }
    }

    # ------------------------------------------------------------------ scenarios
    function script:New-TestWriter {
        param([int]$State = 1, [string]$Text = 'Stable', [string]$LastError = 'No error')
        return @{ Name = 'Microsoft Exchange Writer'; Id = '76fe1ac4-15f7-4bcd-987e-8e1acb462fb7'; State = $State; Text = $Text; Error = $LastError }
    }

    $script:Stable    = New-TestWriter
    $script:Retryable = New-TestWriter -LastError 'Retryable error'
    $script:Failed    = New-TestWriter -State 8 -Text 'Failed' -LastError 'Retryable error'
    $script:Waiting   = New-TestWriter -State 5 -Text 'Waiting for completion' -LastError 'No error'

    # The other writers of a real server: four stable, one failed
    $script:OtherWriters = @(
        @{ Name = 'Task Scheduler Writer'; Id = 'd61d61c8-d73a-4eee-8cdd-f6f9786b7124'; State = 1; Text = 'Stable'; Error = 'No error' }
        @{ Name = 'VSS Metadata Store Writer'; Id = '75dfb225-e2e4-4d39-9ac9-ffaff65ddf06'; State = 1; Text = 'Stable'; Error = 'No error' }
        @{ Name = 'Performance Counters Writer'; Id = '0bada1de-01a9-4625-8278-69e735f39dd2'; State = 1; Text = 'Stable'; Error = 'No error' }
        @{ Name = 'System Writer'; Id = 'e8132975-6f93-4464-a53e-1050253ae220'; State = 7; Text = 'Failed'; Error = 'Retryable error' }
        @{ Name = 'Registry Writer'; Id = 'afbab4a2-367d-4d15-a586-71dbb18f8485'; State = 1; Text = 'Stable'; Error = 'No error' }
    )

    function script:Invoke-Scenario {
        param([hashtable]$Scenario = @{}, [hashtable]$Params = @{})
        $global:VssTest = @{
            Elevated = $true; VssFail = $false; German = $false; Quote = ''; VssCalls = 0; Others = $script:OtherWriters
            Writer = $script:Stable; WriterAfterRestart = $script:Stable
            Services = @{ MSExchangeRepl = 'Running'; MSExchangeIS = 'Running'; MSExchangeMailboxReplication = 'Running' }
            StatusAfterStart = 'Running'; RestartError = ''; Calls = @()
        }
        foreach ($k in $Scenario.Keys) { $global:VssTest[$k] = $Scenario[$k] }

        $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $run = @{ LogPath = $log }
        foreach ($k in $Params.Keys) { $run[$k] = $Params[$k] }
        $text = & $script:Target @run *>&1 | Out-String
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $code; Text = $text; Calls = @($global:VssTest.Calls); VssCalls = $global:VssTest.VssCalls
            Transcripts = @(Get-ChildItem -Path $log -Filter 'transcript-*.txt' -ErrorAction SilentlyContinue)
        }
    }

    $script:FixParams = @{ Fix = $true; Confirm = $false }
}

AfterAll {
    foreach ($f in 'whoami.exe', 'vssadmin.exe', 'Get-Service', 'Set-VssTestServiceStarted', 'Restart-Service', 'Start-Service') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name VssTest -Scope Global -ErrorAction SilentlyContinue
    $env:COMPUTERNAME = $script:SavedComputerName
}

Describe 'Repair-ExchangeVssWriter' {

    Context 'Report only' {

        It 'stable, no error: OK (exit 0)' {
            $r = Invoke-Scenario
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match "Writer name: 'Microsoft Exchange Writer'"
            $r.Text | Should -Match 'State: \[1\] Stable'
            $r.Text | Should -Match 'OVERALL: OK'
            $r.Calls.Count | Should -Be 0
        }

        It 'failed state: action required (exit 1), nothing restarted' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Failed state \[8\] Failed'
            $r.Text | Should -Match 'Run again with -Fix to restart MSExchangeRepl'
            $r.Calls.Count | Should -Be 0
        }

        It 'stable with a retryable error: action required (exit 1)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Retryable }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'last backup left an error: Retryable error'
        }

        It 'another writer in a failed state does not matter' {
            $r = Invoke-Scenario
            $r.Text | Should -Not -Match 'System Writer'
            $r.ExitCode | Should -Be 0
        }

        It 'waiting state: manual check (exit 2)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Waiting }
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'a backup is probably running'
            $r.Text | Should -Match 'OVERALL: MANUAL CHECK REQUIRED'
        }

        It 'writer not listed, MSExchangeRepl running: action required (exit 1)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $null }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'not listed although MSExchangeRepl is running'
            $r.Calls.Count | Should -Be 0
        }

        It 'writer not listed, MSExchangeRepl stopped: action required (exit 1)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $null; Services = @{ MSExchangeRepl = 'Stopped'; MSExchangeIS = 'Running' } }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'not listed and MSExchangeRepl is Stopped'
        }

        It 'German output, stable without error: OK (exit 0)' {
            $r = Invoke-Scenario -Scenario @{ German = $true }
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'Verfassername: "Microsoft Exchange Writer"'
            $r.Text | Should -Match 'Letzter Fehler: Kein Fehler'
            $r.Text | Should -Match 'not in English'
        }

        It 'German output, stable with a retryable error: action required (exit 1)' {
            $r = Invoke-Scenario -Scenario @{ German = $true; Writer = $script:Retryable }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'last error is "Wiederholbarer Fehler" while the other stable writers show "Kein Fehler"'
        }

        It 'German output, failed state: action required (exit 1)' {
            $r = Invoke-Scenario -Scenario @{ German = $true; Writer = $script:Failed }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Failed state \[8\] Fehlgeschlagen'
        }

        It 'German output, fewer than 2 other stable writers: manual check (exit 2)' {
            $r = Invoke-Scenario -Scenario @{ German = $true; Others = @($script:OtherWriters[0], $script:OtherWriters[3]) }
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'fewer than 2 other stable writers'
        }

        It 'writer names in double quotes are read in English output too' {
            $r = Invoke-Scenario -Scenario @{ Quote = '"'; Writer = $script:Failed }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Writer name: "Microsoft Exchange Writer"'
            $r = Invoke-Scenario -Scenario @{ Quote = '"' }
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'Cannot run (exit 3)' {

        It 'not elevated: vssadmin is not run' {
            $r = Invoke-Scenario -Scenario @{ Elevated = $false }
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'Run as administrator'
            $r.VssCalls | Should -Be 0
        }

        It 'vssadmin fails' {
            $r = Invoke-Scenario -Scenario @{ VssFail = $true } -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'vssadmin list writers failed \(exit code 2\)'
            $r.Text | Should -Match 'OVERALL: COULD NOT RUN'
            $r.Calls.Count | Should -Be 0
        }

        It 'writer not listed and no MSExchangeRepl service: not an Exchange Mailbox server' {
            $r = Invoke-Scenario -Scenario @{ Writer = $null; Services = @{} } -Params $FixParams
            $r.ExitCode | Should -Be 3
            $r.Text | Should -Match 'not an Exchange Mailbox server'
            $r.Calls.Count | Should -Be 0
        }
    }

    Context '-Fix' {

        It 'failed writer: restarts MSExchangeRepl only, checks again, OK (exit 0)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed } -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Calls | Should -Be @('Restart MSExchangeRepl')
            $r.VssCalls | Should -Be 2
            $r.Text | Should -Match 'After the restart'
            $r.Text | Should -Match 'OVERALL: OK'
            $r.Transcripts.Count | Should -Be 1
        }

        It '-IncludeInformationStore: restarts MSExchangeIS first, with a warning' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Retryable } -Params @{ Fix = $true; Confirm = $false; IncludeInformationStore = $true }
            $r.ExitCode | Should -Be 0
            $r.Calls | Should -Be @('Restart MSExchangeIS', 'Restart MSExchangeRepl')
            $r.Text | Should -Match 'dismounts every database on this server'
        }

        It 'writer not listed, MSExchangeRepl stopped: starts it' {
            $r = Invoke-Scenario -Scenario @{ Writer = $null; Services = @{ MSExchangeRepl = 'Stopped'; MSExchangeIS = 'Running' } } -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Calls | Should -Be @('Start MSExchangeRepl')
        }

        It 'writer still failed after the restart: exit 1' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed; WriterAfterRestart = $script:Failed } -Params $FixParams
            $r.ExitCode | Should -Be 1
            $r.Calls.Count | Should -Be 1
            $r.Text | Should -Match 'still not stable'
        }

        It 'the restart fails: exit 1 with the error' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed; RestartError = 'Cannot stop service MSExchangeRepl.' } -Params $FixParams
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'FAILED: Cannot stop service MSExchangeRepl'
            $r.VssCalls | Should -Be 1
        }

        It 'the service does not reach Running in time: exit 1' {
            Mock Start-Sleep { }
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed; StatusAfterStart = 'StartPending' } -Params @{ Fix = $true; Confirm = $false; TimeoutSeconds = 10 }
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'MSExchangeRepl is not running after 10 seconds'
            Should -Invoke Start-Sleep -Times 5 -Exactly
        }

        It 'the writer appears a few seconds after the restart' {
            Mock Start-Sleep { $global:VssTest.Writer = $global:VssTest.WriterLater }
            $r = Invoke-Scenario -Scenario @{ Writer = $null; WriterAfterRestart = $null; WriterLater = $script:Stable } -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.VssCalls | Should -Be 3
        }

        It '-WhatIf restarts nothing' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Failed } -Params @{ Fix = $true; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            $r.Calls.Count | Should -Be 0
            $r.Text | Should -Match 'WhatIf: nothing was restarted'
            $r.Transcripts.Count | Should -Be 0
        }

        It 'waiting state: never restarts (exit 2)' {
            $r = Invoke-Scenario -Scenario @{ Writer = $script:Waiting } -Params $FixParams
            $r.ExitCode | Should -Be 2
            $r.Calls.Count | Should -Be 0
            $r.Text | Should -Match 'Nothing is restarted while a backup may be running'
        }

        It 'stable writer: nothing to change' {
            $r = Invoke-Scenario -Params $FixParams
            $r.ExitCode | Should -Be 0
            $r.Calls.Count | Should -Be 0
            $r.Text | Should -Match 'Nothing to change'
        }
    }
}
