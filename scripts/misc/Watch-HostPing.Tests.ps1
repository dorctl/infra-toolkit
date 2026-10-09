#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Watch-HostPing.ps1 - log lines, outage lines, summary and exit codes against a mocked ping.

.DESCRIPTION
    Test-Connection is replaced by a global function that plays a scripted sequence of replies, timeouts
    and errors, in the result shape of Windows PowerShell 5.1 or of PowerShell 7. Like the real 5.1 cmdlet,
    the 5.1 mock returns a Win32_PingStatus only for a reply and writes every other status as an error
    (PingException with an inner Win32Exception that carries the IP status code). The PowerShell 7 mock
    returns PingStatus objects, and an error with an inner SocketException for a name that cannot be
    resolved. Start-Sleep is replaced too, so the interval is checked without waiting.
    No network access is needed.

.NOTES
    Mode: Read-only
    Network: none
#>

BeforeAll {
    $script:Target = Join-Path $PSScriptRoot 'Watch-HostPing.ps1'
    $script:Stamp = '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'

    # Error record as Test-Connection writes it (see ProcessPingStatus in the PowerShell source)
    function global:New-PingMockError {
        param([string]$Target, [int]$Code, [switch]$Socket, [string]$Message)
        if ($Socket) { $inner = New-Object System.Net.Sockets.SocketException ([int][System.Net.Sockets.SocketError]::HostNotFound) }
        else { $inner = New-Object System.ComponentModel.Win32Exception $Code }
        if (-not $Message) { $Message = "Testing connection to computer '{0}' failed: {1}" -f $Target, $inner.Message }
        $ex = New-Object System.Net.NetworkInformation.PingException $Message, $inner
        return (New-Object System.Management.Automation.ErrorRecord $ex, 'TestConnectionException',
            ([System.Management.Automation.ErrorCategory]::ResourceUnavailable), $Target)
    }

    # One step of the scripted sequence -> what Test-Connection does
    #   R<ms>     reply                     T       timeout (5.1: error with status 11010)
    #   E         error thrown, no status   U       host name cannot be resolved
    #   S<code>   5.1: error with this IP status code, for example S11003 (destination host unreachable)
    #   L<code>   5.1: the same with a message in another language that says "timed out"
    #   X<status> 7: PingStatus with another Status, for example XDestinationHostUnreachable
    #   N         reply without TTL (PowerShell 7 on some platforms)
    function global:Get-PingMockStep {
        param([string]$Target, [hashtable]$Bound)
        $s = $global:PingScenario
        $s.Calls += , @{ Target = $Target; Count = $Bound['Count']; Timeout = $Bound.ContainsKey('TimeoutSeconds') }
        $step = [string]$s.Steps[[Math]::Min($s.Index, $s.Steps.Count - 1)]
        $s.Index++
        $address = '192.0.2.10'
        $winPs = $s.Shape -eq 'WinPS'
        switch -Regex ($step) {
            '^R(\d+)$' {
                $ms = [int]$Matches[1]
                if ($winPs) {
                    return @{ Object = [pscustomobject]@{ Address = $Target; IPV4Address = $address; ProtocolAddress = $address
                                ResponseTime = $ms; ResponseTimeToLive = 128; ReplySize = 32; StatusCode = 0 } }
                }
                return @{ Object = [pscustomobject]@{ Ping = 1; Source = 'SRV01'; Destination = $Target; Address = [System.Net.IPAddress]::Parse($address)
                            DisplayAddress = $address; Latency = $ms; Status = 'Success'; BufferSize = 32
                            Reply = [pscustomobject]@{ Status = 'Success'; RoundtripTime = $ms; Options = [pscustomobject]@{ Ttl = 64; DontFragment = $false } } } }
            }
            '^N$' {
                return @{ Object = [pscustomobject]@{ Ping = 1; Destination = $Target; Address = [System.Net.IPAddress]::Parse($address)
                            Latency = 3; Status = 'Success'; Reply = [pscustomobject]@{ Status = 'Success'; Options = $null } } }
            }
            '^T$' {
                if ($winPs) { return @{ Error = (New-PingMockError -Target $Target -Code 11010) } }
                return @{ Object = [pscustomobject]@{ Ping = 1; Destination = $Target; Address = [System.Net.IPAddress]::Parse($address)
                            Latency = 0; Status = 'TimedOut'; Reply = [pscustomobject]@{ Status = 'TimedOut'; Options = $null } } }
            }
            '^E$' { return @{ Throw = "Testing connection to computer '$Target' failed: Request timed out" } }
            '^U$' {
                if ($winPs) { return @{ Error = (New-PingMockError -Target $Target -Code 11001) } }
                return @{ Error = (New-PingMockError -Target $Target -Socket) }
            }
            '^S(\d+)$' { return @{ Error = (New-PingMockError -Target $Target -Code ([int]$Matches[1])) } }
            '^L(\d+)$' {
                return @{ Error = (New-PingMockError -Target $Target -Code ([int]$Matches[1]) -Message "Echec du test de connexion vers '$Target': delai d'attente depasse") }
            }
            '^X(\w+)$' {
                return @{ Object = [pscustomobject]@{ Ping = 1; Destination = $Target; Address = [System.Net.IPAddress]::Parse($address)
                            Latency = 0; Status = $Matches[1]; Reply = [pscustomobject]@{ Status = $Matches[1]; Options = $null } } }
            }
        }
        throw "Unknown mock step '$step'"
    }

    # The two Test-Connection versions differ in their parameters: only PowerShell 7 has -TimeoutSeconds
    function script:Set-PingMock {
        param([ValidateSet('WinPS', 'Core')][string]$Shape)
        if ($Shape -eq 'Core') {
            function global:Test-Connection {
                [CmdletBinding()]
                param([Parameter(Position = 0)][Alias('ComputerName')][string[]]$TargetName, [int]$Count, [int]$TimeoutSeconds)
                $step = Get-PingMockStep -Target ([string]$TargetName[0]) -Bound $PSBoundParameters
                if ($step.Throw) { throw $step.Throw }
                if ($step.Error) { $PSCmdlet.WriteError($step.Error); return }
                $step.Object
            }
        } else {
            function global:Test-Connection {
                [CmdletBinding()]
                param([Parameter(Position = 0)][string[]]$ComputerName, [int]$Count)
                $step = Get-PingMockStep -Target ([string]$ComputerName[0]) -Bound $PSBoundParameters
                if ($step.Throw) { throw $step.Throw }
                if ($step.Error) { $PSCmdlet.WriteError($step.Error); return }
                $step.Object
            }
        }
    }

    function global:Start-Sleep {
        param([int]$Seconds, [int]$Milliseconds)
        $global:PingScenario.Sleeps += ($Seconds * 1000 + $Milliseconds)
    }

    function script:Invoke-Scenario {
        param(
            [string[]]$Steps,
            [ValidateSet('WinPS', 'Core')][string]$Shape = 'Core',
            [string]$TargetHost = 'SRV01',
            [hashtable]$Params = @{},
            [string]$OutputPath
        )
        Set-PingMock -Shape $Shape
        $global:PingScenario = @{ Shape = $Shape; Steps = $Steps; Index = 0; Calls = @(); Sleeps = @() }
        if (-not $OutputPath) { $OutputPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        $run = @{ ComputerName = $TargetHost; Count = $Steps.Count; IntervalSeconds = 0; OutputPath = $OutputPath }
        foreach ($k in $Params.Keys) { $run[$k] = $Params[$k] }

        $screen = & $script:Target @run *>&1 | Out-String
        $code = $LASTEXITCODE

        $logFile = $null
        $lines = @()
        if (Test-Path -LiteralPath $OutputPath -PathType Container) {
            $logFile = @(Get-ChildItem -LiteralPath $OutputPath -Filter 'Ping-*.log' -File)[0]
            if ($logFile) { $lines = @(Get-Content -LiteralPath $logFile.FullName) }
        }
        return [pscustomobject]@{
            ExitCode = $code; Screen = $screen; LogFile = $logFile; Lines = $lines; Log = ($lines -join "`n")
            Calls = @($global:PingScenario.Calls); Sleeps = @($global:PingScenario.Sleeps)
        }
    }
}

AfterAll {
    foreach ($f in 'New-PingMockError', 'Get-PingMockStep', 'Test-Connection', 'Start-Sleep') {
        Remove-Item -LiteralPath "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name PingScenario -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Watch-HostPing' {

    Context 'PowerShell 7 result shape' {

        It 'all replies: exit 0, one line per reply, summary with min/avg/max' {
            $r = Invoke-Scenario -Steps 'R12', 'R15', 'R9'
            $r.ExitCode | Should -Be 0
            $r.LogFile.Name | Should -Match '^Ping-SRV01-\d{8}-\d{6}\.log$'
            $r.Lines[0] | Should -Be 'Target host = SRV01'
            @($r.Lines | Where-Object { $_ -match "^$script:Stamp  Reply from 192\.0\.2\.10: time=\d+ms TTL=64$" }).Count | Should -Be 3
            $r.Log | Should -Match 'time=12ms TTL=64'
            $r.Log | Should -Match 'time=9ms TTL=64'
            $r.Log | Should -Not -Match 'timed out|DOWN|UP again'
            $r.Log | Should -Match 'Sent      : 3'
            $r.Log | Should -Match 'Received  : 3'
            $r.Log | Should -Match 'Lost      : 0 \(0%\)'
            $r.Log | Should -Match 'Time      : min 9ms, avg 12ms, max 15ms'
            $r.Log | Should -Not -Match 'Outages'
        }

        It 'passes -Count 1 and -TimeoutSeconds 1 to Test-Connection' {
            $r = Invoke-Scenario -Steps 'R1', 'R1'
            $r.Calls.Count | Should -Be 2
            $r.Calls | ForEach-Object { $_.Target | Should -Be 'SRV01'; $_.Count | Should -Be 1; $_.Timeout | Should -BeTrue }
        }

        It 'outage: timeout lines, a DOWN line and an UP again line, exit 1' {
            $r = Invoke-Scenario -Steps 'R10', 'T', 'T', 'R20'
            $r.ExitCode | Should -Be 1
            $body = @($r.Lines | Where-Object { $_ -match "^$script:Stamp  " } | ForEach-Object { $_.Substring(21) })
            $body[0] | Should -Be 'Reply from 192.0.2.10: time=10ms TTL=64'
            $body[1] | Should -Be 'Request timed out'
            $body[2] | Should -Match "^\*\*\* SRV01 DOWN since $script:Stamp$"
            $body[3] | Should -Be 'Request timed out'
            $body[4] | Should -Be 'Reply from 192.0.2.10: time=20ms TTL=64'
            $body[5] | Should -Match '^\*\*\* SRV01 UP again after \d{2}:\d{2}:\d{2} \(2 lost\)$'
            $body.Count | Should -Be 6
            $r.Log | Should -Match 'Sent      : 4'
            $r.Log | Should -Match 'Received  : 2'
            $r.Log | Should -Match 'Lost      : 2 \(50%\)'
            $r.Log | Should -Match 'Time      : min 10ms, avg 15ms, max 20ms'
            $r.Log | Should -Match 'Outages   : 1, longest \d{2}:\d{2}:\d{2}'
            $r.Log | Should -Not -Match 'Still DOWN'
        }

        It 'host down from the first request: DOWN line first, then UP again' {
            $r = Invoke-Scenario -Steps 'T', 'R5'
            $r.ExitCode | Should -Be 1
            $r.Log | Should -Match "(?s)Request timed out.*SRV01 DOWN since.*Reply from.*SRV01 UP again after \d{2}:\d{2}:\d{2} \(1 lost\)"
        }

        It 'still down at the end: summary says so, two outages counted' {
            $r = Invoke-Scenario -Steps 'R5', 'T', 'R5', 'T', 'T'
            $r.ExitCode | Should -Be 1
            @($r.Lines | Where-Object { $_ -match '\*\*\* SRV01 DOWN since' }).Count | Should -Be 2
            $r.Log | Should -Match 'Lost      : 3 \(60%\)'
            $r.Log | Should -Match 'Outages   : 2'
            $r.Log | Should -Match "Still DOWN since $script:Stamp"
        }

        It 'other status (unreachable) is a lost request with the status' {
            $r = Invoke-Scenario -Steps 'XDestinationHostUnreachable', 'R4'
            $r.ExitCode | Should -Be 1
            $r.Log | Should -Match "$script:Stamp  Request failed: DestinationHostUnreachable"
        }

        It 'reply without TTL: the TTL part is left out' {
            $r = Invoke-Scenario -Steps 'N'
            $r.ExitCode | Should -Be 0
            $r.Log | Should -Match "$script:Stamp  Reply from 192\.0\.2\.10: time=3ms`n"
        }

        It 'the screen shows the same lines as the log' {
            $r = Invoke-Scenario -Steps 'R7', 'T'
            $r.Screen | Should -Match 'Target host = SRV01'
            $r.Screen | Should -Match 'Reply from 192\.0\.2\.10: time=7ms TTL=64'
            $r.Screen | Should -Match 'Request timed out'
            $r.Screen | Should -Match 'Lost      : 1 \(50%\)'
            $r.Screen | Should -Match ([regex]::Escape($r.LogFile.FullName))
        }
    }

    Context 'Windows PowerShell 5.1 result shape' {

        It 'replies use ResponseTime and ResponseTimeToLive, -TimeoutSeconds is not passed' {
            $r = Invoke-Scenario -Shape WinPS -Steps 'R3', 'R5'
            $r.ExitCode | Should -Be 0
            @($r.Lines | Where-Object { $_ -match "^$script:Stamp  Reply from 192\.0\.2\.10: time=[35]ms TTL=128$" }).Count | Should -Be 2
            $r.Calls | ForEach-Object { $_.Timeout | Should -BeFalse; $_.Count | Should -Be 1 }
            $r.Log | Should -Match 'Time      : min 3ms, avg 4ms, max 5ms'
        }

        It 'timeout as an error with no result, and as a thrown error, both count as lost' {
            $r = Invoke-Scenario -Shape WinPS -Steps 'R3', 'T', 'E', 'R3'
            $r.ExitCode | Should -Be 1
            @($r.Lines | Where-Object { $_ -match "^$script:Stamp  Request timed out$" }).Count | Should -Be 2
            $r.Log | Should -Match 'UP again after \d{2}:\d{2}:\d{2} \(2 lost\)'
            $r.Log | Should -Match 'Lost      : 2 \(50%\)'
        }

        It 'status from the error record: 11003 unreachable, 11013 TTL expired, 11010 timed out' {
            $r = Invoke-Scenario -Shape WinPS -Steps 'S11003', 'S11013', 'S11010'
            $r.ExitCode | Should -Be 1
            $r.Log | Should -Match "$script:Stamp  Request failed: Destination host unreachable"
            $r.Log | Should -Match "$script:Stamp  Request failed: TTL expired in transit"
            $r.Log | Should -Match "$script:Stamp  Request timed out"
            $r.Log | Should -Match 'Time      : no replies'
        }

        It 'does not depend on the language of the error message' {
            # The message says "timed out" in French, the code says destination host unreachable
            $r = Invoke-Scenario -Shape WinPS -Steps 'L11003'
            $r.Log | Should -Match "$script:Stamp  Request failed: Destination host unreachable"
            $r.Log | Should -Not -Match 'Request timed out'
        }

        It 'host name that cannot be resolved (11001) on the first request: exit 3' {
            $r = Invoke-Scenario -Shape WinPS -Steps 'U', 'R1' -TargetHost 'nohost.example.com'
            $r.ExitCode | Should -Be 3
            $r.Calls.Count | Should -Be 1
            $r.Log | Should -Match 'ERROR: the host name nohost\.example\.com could not be resolved'
        }
    }

    Context 'Interval' {

        It '-IntervalSeconds 0 never sleeps' {
            $r = Invoke-Scenario -Steps 'R1', 'R1', 'R1'
            $r.Sleeps.Count | Should -Be 0
        }

        It '-IntervalSeconds 2 sleeps between requests, not after the last one' {
            $r = Invoke-Scenario -Steps 'R1', 'T', 'R1' -Params @{ IntervalSeconds = 2 }
            $r.ExitCode | Should -Be 1
            $r.Sleeps.Count | Should -Be 2
            $r.Sleeps | ForEach-Object { $_ | Should -BeGreaterThan 1000; $_ | Should -BeLessOrEqual 2000 }
        }
    }

    Context 'Default log folder' {

        It 'without -OutputPath the log goes to InfraToolkit-Output\Watch-HostPing in the folder of the script' {
            $dir = Join-Path $TestDrive 'script-copy'
            $null = New-Item -ItemType Directory -Path $dir -Force
            Copy-Item -LiteralPath $script:Target -Destination $dir
            Set-PingMock -Shape Core
            $global:PingScenario = @{ Shape = 'Core'; Steps = @('R5'); Index = 0; Calls = @(); Sleeps = @() }
            $run = @{ ComputerName = 'SRV01'; Count = 1; IntervalSeconds = 0 }
            $screen = & (Join-Path $dir 'Watch-HostPing.ps1') @run *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $expected = Join-Path (Join-Path $dir 'InfraToolkit-Output') 'Watch-HostPing'
            $logs = @(Get-ChildItem -LiteralPath $expected -Filter 'Ping-SRV01-*.log' -File)
            $logs.Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $expected -Directory).Count | Should -Be 0
            (Get-Content -LiteralPath $logs[0].FullName)[0] | Should -Be 'Target host = SRV01'
            $screen | Should -Match ('Log file  : ' + [regex]::Escape($logs[0].FullName))
        }
    }

    Context 'Errors' {

        It 'host name that cannot be resolved on the first request: exit 3, no summary' {
            $r = Invoke-Scenario -Steps 'U', 'R1' -TargetHost 'nohost.example.com'
            $r.ExitCode | Should -Be 3
            $r.Calls.Count | Should -Be 1
            $r.Log | Should -Match 'ERROR: the host name nohost\.example\.com could not be resolved'
            $r.Log | Should -Not -Match 'Summary'
        }

        It 'name resolution failing later counts as a lost request' {
            $r = Invoke-Scenario -Shape WinPS -Steps 'R1', 'U', 'R1'
            $r.ExitCode | Should -Be 1
            $r.Log | Should -Match "$script:Stamp  Request failed: the host name could not be resolved"
            $r.Log | Should -Match 'Lost      : 1 \('
        }

        It 'log folder cannot be created: exit 3, nothing pinged' {
            $blocker = Join-Path $TestDrive 'blocker'
            Set-Content -LiteralPath $blocker -Value 'file, not a folder'
            $r = Invoke-Scenario -Steps 'R1' -OutputPath (Join-Path $blocker 'logs')
            $r.ExitCode | Should -Be 3
            $r.Calls.Count | Should -Be 0
            $r.Screen | Should -Match 'ERROR:'
        }

        It 'host name with characters not allowed in file names gives a safe log name' {
            $r = Invoke-Scenario -Steps 'R1' -TargetHost 'fe80::1'
            $r.ExitCode | Should -Be 0
            $r.LogFile.Name | Should -Match '^Ping-fe80__1-\d{8}-\d{6}\.log$'
            $r.Lines[0] | Should -Be 'Target host = fe80::1'
        }
    }
}
