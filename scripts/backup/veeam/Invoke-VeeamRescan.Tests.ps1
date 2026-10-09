#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Invoke-VeeamRescan.ps1 - selection by name and wildcard, rescan results, -WhatIf and exit codes.

.DESCRIPTION
    Get-VBRServer, Get-VBRBackupRepository and Rescan-VBREntity are replaced by global functions backed by
    an in-memory scenario. Because Get-VBRServer exists, the script does not load the Veeam module.
    No Veeam server is needed, so the tests run in CI on Linux.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Invoke-VeeamRescan.ps1'

    $script:Servers = @(
        [pscustomobject]@{ Name = 'VBR01.contoso.com'; Type = 'Windows' }
        [pscustomobject]@{ Name = 'PROXY01'; Type = 'Windows' }
        [pscustomobject]@{ Name = 'PROXY02'; Type = 'Linux' }
        [pscustomobject]@{ Name = 'esx01.contoso.com'; Type = 'ESXi' }
    )
    $script:Repositories = @(
        [pscustomobject]@{ Name = 'Default Backup Repository'; Type = 'WinLocal' }
        [pscustomobject]@{ Name = 'Repository 01'; Type = 'WinLocal' }
        [pscustomobject]@{ Name = 'Repository 02'; Type = 'LinuxLocal' }
        [pscustomobject]@{ Name = 'Repository [archive]'; Type = 'Cifs' }
    )

    # Mocked Veeam cmdlets. The script filters by name itself, so the stubs return everything.
    function script:Set-VeeamStub {
        param([switch]$NoWait)
        function global:Get-VBRServer {
            [CmdletBinding()]
            param([string[]]$Name)
            $global:VeeamScenario.Calls += [pscustomobject]@{ Command = 'Get-VBRServer'; Name = $Name }
            if ($global:VeeamScenario.ServerError) { throw $global:VeeamScenario.ServerError }
            $global:VeeamScenario.Servers
        }
        function global:Get-VBRBackupRepository {
            [CmdletBinding()]
            param([string[]]$Name)
            $global:VeeamScenario.Calls += [pscustomobject]@{ Command = 'Get-VBRBackupRepository'; Name = $Name }
            $global:VeeamScenario.Repositories
        }
        if ($NoWait) {
            function global:Rescan-VBREntity {
                [CmdletBinding()]
                param([Parameter(Mandatory = $true)][object[]]$Entity)
                foreach ($e in $Entity) { $global:VeeamScenario.Rescans += [pscustomobject]@{ Name = [string]$e.Name; Wait = $false } }
            }
            return
        }
        function global:Rescan-VBREntity {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][object[]]$Entity, [switch]$Wait)
            foreach ($e in $Entity) {
                $global:VeeamScenario.Rescans += [pscustomobject]@{ Name = [string]$e.Name; Wait = [bool]$Wait }
                if ($global:VeeamScenario.FailOn -contains $e.Name) { throw ('Failed to connect to {0}' -f $e.Name) }
                if ($global:VeeamScenario.WarnOn -contains $e.Name) { Write-Warning ('Some disks of {0} were skipped' -f $e.Name) }
            }
        }
    }

    function script:Invoke-Rescan {
        param([hashtable]$Params = @{}, [hashtable]$Scenario = @{})
        $global:VeeamScenario = @{
            Servers = $script:Servers; Repositories = $script:Repositories
            Calls = @(); Rescans = @(); FailOn = @(); WarnOn = @(); ServerError = ''
        }
        foreach ($k in $Scenario.Keys) { $global:VeeamScenario[$k] = $Scenario[$k] }
        $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $output = & $script:Target @Params -LogPath $log *>&1 | Out-String
        $code = $LASTEXITCODE
        $csv = Join-Path $log 'rescan-results.csv'
        $rows = @()
        if (Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv) }
        return [pscustomobject]@{
            ExitCode = $code; Output = $output; Rows = $rows; Log = $log
            Rescans = @($global:VeeamScenario.Rescans); Calls = @($global:VeeamScenario.Calls)
        }
    }

    function script:Get-Status {
        param($Result, [string]$Name)
        return @($Result.Rows | Where-Object { $_.Name -eq $Name } | ForEach-Object { $_.Status })
    }
}

AfterAll {
    foreach ($f in 'Get-VBRServer', 'Get-VBRBackupRepository', 'Rescan-VBREntity') {
        # "Function:\global:<name>" does not remove anything: the provider path takes no scope prefix
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name VeeamScenario -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-VeeamRescan' {

    BeforeEach { Set-VeeamStub }

    Context 'Selection' {

        It 'no names: every managed server and every repository, with -Wait (exit 0)' {
            $r = Invoke-Rescan
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('VBR01.contoso.com', 'PROXY01', 'PROXY02', 'esx01.contoso.com',
                'Default Backup Repository', 'Repository 01', 'Repository 02', 'Repository [archive]')
            @($r.Rescans | Where-Object { -not $_.Wait }).Count | Should -Be 0
            $r.Rows.Count | Should -Be 8
            @($r.Rows | Where-Object { $_.Status -ne 'RESCANNED' }).Count | Should -Be 0
            ($r.Rows | Where-Object { $_.Name -eq 'PROXY01' }).Type | Should -Be 'Server'
            ($r.Rows | Where-Object { $_.Name -eq 'Repository 01' }).Type | Should -Be 'Repository'
            ($r.Rows | Where-Object { $_.Name -eq 'PROXY01' }).Duration | Should -Match '^\d\d:\d\d:\d\d$'
            $r.Output | Should -Match 'Rescanned: 8, failed: 0, not found: 0'
        }

        It 'the cmdlets are called without -Name: the script filters the names itself' {
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01' }
            @($r.Calls | Where-Object { $_.Name }).Count | Should -Be 0
        }

        It '-Server only: that server and no repository' {
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01' }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('PROXY01')
            $r.Calls.Command | Should -Not -Contain 'Get-VBRBackupRepository'
            Get-Status $r 'PROXY01' | Should -Be 'RESCANNED'
        }

        It '-Repository only: that repository and no server' {
            $r = Invoke-Rescan -Params @{ Repository = 'Repository 01' }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('Repository 01')
            $r.Calls.Command | Should -Not -Contain 'Get-VBRServer'
        }

        It 'both: the servers and repositories named, in the order given, case insensitive' {
            $r = Invoke-Rescan -Params @{ Server = 'proxy02', 'VBR01.CONTOSO.COM'; Repository = 'repository 02' }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('PROXY02', 'VBR01.contoso.com', 'Repository 02')
        }

        It 'wildcards match several, and an entity matched twice is rescanned once' {
            $r = Invoke-Rescan -Params @{ Server = 'PROXY*', 'PROXY01', '*.contoso.com'; Repository = 'Repository 0?' }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('PROXY01', 'PROXY02', 'VBR01.contoso.com', 'esx01.contoso.com', 'Repository 01', 'Repository 02')
        }

        It 'a name with brackets matches exactly' {
            $r = Invoke-Rescan -Params @{ Repository = 'Repository [archive]' }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Name | Should -Be @('Repository [archive]')
        }

        It 'a name that matches nothing: NOT FOUND (exit 1), the others are still rescanned' {
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01', 'SRV99'; Repository = 'Repository 99' }
            $r.ExitCode | Should -Be 1
            $r.Rescans.Name | Should -Be @('PROXY01')
            Get-Status $r 'PROXY01' | Should -Be 'RESCANNED'
            Get-Status $r 'SRV99' | Should -Be 'NOT FOUND'
            Get-Status $r 'Repository 99' | Should -Be 'NOT FOUND'
            ($r.Rows | Where-Object { $_.Name -eq 'SRV99' }).Type | Should -Be 'Server'
            $r.Output | Should -Match 'Rescanned: 1, failed: 0, not found: 2'
        }
    }

    Context 'Rescan results' {

        It 'a failed rescan: FAILED with the error (exit 1), the next ones continue' {
            $r = Invoke-Rescan -Scenario @{ FailOn = @('PROXY01') }
            $r.ExitCode | Should -Be 1
            $r.Rescans.Count | Should -Be 8
            Get-Status $r 'PROXY01' | Should -Be 'FAILED'
            ($r.Rows | Where-Object { $_.Name -eq 'PROXY01' }).Detail | Should -Be 'Failed to connect to PROXY01'
            Get-Status $r 'PROXY02' | Should -Be 'RESCANNED'
            $r.Output | Should -Match 'Rescanned: 7, failed: 1, not found: 0'
        }

        It 'a warning is kept in Detail and the rescan still counts as done (exit 0)' {
            $r = Invoke-Rescan -Params @{ Server = 'esx01.contoso.com' } -Scenario @{ WarnOn = @('esx01.contoso.com') }
            $r.ExitCode | Should -Be 0
            Get-Status $r 'esx01.contoso.com' | Should -Be 'RESCANNED'
            ($r.Rows | Where-Object { $_.Name -eq 'esx01.contoso.com' }).Detail | Should -Be 'Some disks of esx01.contoso.com were skipped'
        }

        It 'a Veeam version without -Wait: STARTED, result not known (exit 2)' {
            Set-VeeamStub -NoWait
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01', 'PROXY02' }
            $r.ExitCode | Should -Be 2
            $r.Rescans.Name | Should -Be @('PROXY01', 'PROXY02')
            Get-Status $r 'PROXY01' | Should -Be 'STARTED'
            $r.Output | Should -Match 'Rescanned: 0, failed: 0, not found: 0, started \(result not known\): 2'
            $r.Output | Should -Match 'Check the result of the started rescans'
        }

        It 'without -Wait, a name not found still gives exit 1' {
            Set-VeeamStub -NoWait
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01', 'SRV99' }
            $r.ExitCode | Should -Be 1
            Get-Status $r 'PROXY01' | Should -Be 'STARTED'
            Get-Status $r 'SRV99' | Should -Be 'NOT FOUND'
        }

        It 'saves the results and a transcript in -LogPath' {
            $r = Invoke-Rescan -Params @{ Server = 'PROXY01' }
            Test-Path -LiteralPath (Join-Path $r.Log 'transcript.txt') | Should -BeTrue
            Get-Content -LiteralPath (Join-Path $r.Log 'transcript.txt') -Raw | Should -Match 'PROXY01\s+RESCANNED'
            @($r.Rows[0].PSObject.Properties.Name) | Should -Be @('Type', 'Name', 'Status', 'Duration', 'Detail')
        }
    }

    Context '-WhatIf' {

        It 'lists what would be rescanned, rescans nothing and writes nothing (exit 0)' {
            $r = Invoke-Rescan -Params @{ WhatIf = $true }
            $r.ExitCode | Should -Be 0
            $r.Rescans.Count | Should -Be 0
            $r.Output | Should -Match 'Server\s+PROXY01\s+WHATIF'
            $r.Output | Should -Match 'Repository\s+Repository 01\s+WHATIF'
            $r.Output | Should -Match 'WhatIf: nothing was rescanned'
            Test-Path -LiteralPath $r.Log | Should -BeFalse
        }

        It 'a name that matches nothing is still reported (exit 1)' {
            $r = Invoke-Rescan -Params @{ WhatIf = $true; Server = 'SRV99' }
            $r.ExitCode | Should -Be 1
            $r.Rescans.Count | Should -Be 0
            $r.Output | Should -Match 'SRV99\s+NOT FOUND'
        }
    }

    Context 'Default log folder' {

        It 'without -LogPath: a timestamp folder in InfraToolkit-Output\Invoke-VeeamRescan next to the script, nothing under -WhatIf' {
            $folder = Join-Path $TestDrive 'default-log'
            $null = New-Item -ItemType Directory -Path $folder -Force
            Copy-Item -LiteralPath $script:Target -Destination $folder
            $copy = Join-Path $folder 'Invoke-VeeamRescan.ps1'
            $base = Join-Path $folder 'InfraToolkit-Output'
            $global:VeeamScenario = @{ Servers = $script:Servers; Repositories = $script:Repositories; Calls = @(); Rescans = @(); FailOn = @(); WarnOn = @(); ServerError = '' }

            & $copy -Server 'PROXY01' -WhatIf *> $null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $base | Should -BeFalse

            $output = & $copy -Server 'PROXY01' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $runs = @(Get-ChildItem -LiteralPath (Join-Path $base 'Invoke-VeeamRescan') -Directory)
            $runs.Count | Should -Be 1
            $runs[0].Name | Should -Match '^\d{8}-\d{6}$'
            Test-Path -LiteralPath (Join-Path $runs[0].FullName 'transcript.txt') | Should -BeTrue
            (Import-Csv -LiteralPath (Join-Path $runs[0].FullName 'rescan-results.csv')).Name | Should -Be 'PROXY01'
            ($output -replace '\s', '') | Should -Match ([regex]::Escape((Join-Path $runs[0].FullName 'transcript.txt')))
        }
    }

    Context 'Could not run' {

        It 'Veeam PowerShell not available: exit 3, nothing rescanned' {
            Remove-Item -LiteralPath 'Function:\Get-VBRServer'
            $r = Invoke-Rescan
            $r.ExitCode | Should -Be 3
            $r.Rescans.Count | Should -Be 0
            $r.Output | Should -Match 'PowerShell is not available'
        }

        It 'the Veeam cmdlets fail: exit 3 with the error' {
            $r = Invoke-Rescan -Scenario @{ ServerError = 'Not connected to a Veeam backup server' }
            $r.ExitCode | Should -Be 3
            $r.Rescans.Count | Should -Be 0
            $r.Output | Should -Match 'ERROR: Not connected to a Veeam backup server'
        }

        It 'the log folder cannot be created: exit 3' {
            $file = Join-Path $TestDrive 'not-a-folder.txt'
            Set-Content -LiteralPath $file -Value 'x'
            $global:VeeamScenario = @{ Servers = $script:Servers; Repositories = $script:Repositories; Calls = @(); Rescans = @(); FailOn = @(); WarnOn = @(); ServerError = '' }
            & $script:Target -LogPath (Join-Path $file 'sub') *> $null
            $LASTEXITCODE | Should -Be 3
            $global:VeeamScenario.Rescans.Count | Should -Be 0
        }
    }
}
