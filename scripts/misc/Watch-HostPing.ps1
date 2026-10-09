#Requires -Version 5.1

<#
.SYNOPSIS
    Pings a host continuously, logs every reply with a timestamp to the screen and a file, and ends with a summary.

.DESCRIPTION
    Sends one ICMP echo request at a time with Test-Connection and writes one line per request:

        2026-01-31 10:15:02  Reply from 192.0.2.10: time=1ms TTL=128
        2026-01-31 10:15:03  Request timed out

    When the host stops answering, and again when it answers after an outage, an extra line marks the
    change (DOWN since / UP again after <duration>) so outages stand out in a long log.

    It runs until Ctrl+C, or for -Count requests. At the end, also after Ctrl+C, it prints and logs a
    summary: sent, received, lost (%), minimum, average and maximum time, outages.

    The log is Ping-<host>-<yyyyMMdd-HHmmss>.log in the output folder. Its first line is
    "Target host = <host>".

    Works in Windows PowerShell 5.1 and PowerShell 7, and in Constrained Language Mode.
    In PowerShell 7 each request waits up to 1 second for the reply.

.PARAMETER ComputerName
    Host name or IP address to ping.

.PARAMETER IntervalSeconds
    Seconds from the start of one request to the start of the next. 0 sends the next request at once.
    Default: 1.

.PARAMETER Count
    Number of requests. Default: 0, ping until Ctrl+C.

.PARAMETER OutputPath
    Folder for the log file. Default: %USERPROFILE%\InfraToolkit-Output\Watch-HostPing

.EXAMPLE
    .\Watch-HostPing.ps1 -ComputerName SRV01
    Ping SRV01 every second until Ctrl+C.

.EXAMPLE
    .\Watch-HostPing.ps1 -ComputerName 192.0.2.10 -IntervalSeconds 5 -Count 720
    Ping every 5 seconds for one hour.

.EXAMPLE
    .\Watch-HostPing.ps1 -ComputerName ex01.contoso.com -OutputPath C:\Temp\ping
    Write the log into C:\Temp\ping.

.NOTES
    Mode: Read-only
    Network: ICMP echo to the target host only
    Tested on: mocked tests only, not yet run on a real system
    Last verified: not yet
    Exit codes: 0 = no request lost, 1 = at least one request lost, 3 = the script could not run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [ValidateRange(0, 3600)]
    [int]$IntervalSeconds = 1,

    [ValidateRange(0, 2147483647)]
    [int]$Count = 0,

    [string]$OutputPath = (Join-Path $env:USERPROFILE ('InfraToolkit-Output\{0}' -f
        ($MyInvocation.MyCommand.Name -replace '\.ps1$', '')))
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$EXIT_OK      = 0
$EXIT_LOSS    = 1
$EXIT_NOT_RUN = 3
$TimeFormat   = 'yyyy-MM-dd HH:mm:ss'

# IP_STATUS codes. Windows PowerShell 5.1 Test-Connection returns a Win32_PingStatus only for a reply
# (status 0). Any other status is written as an error whose inner Win32Exception carries the code in
# NativeErrorCode. A failed name resolution comes the same way, with WSAHOST_NOT_FOUND (11001).
$StatusTimedOut    = 11010
$StatusUnresolved  = 11001
$IpStatusText = @{
    11002 = 'Destination net unreachable'; 11003 = 'Destination host unreachable'
    11004 = 'Destination protocol unreachable'; 11005 = 'Destination port unreachable'; 11006 = 'No resources'
    11007 = 'Bad option'; 11008 = 'Hardware error'; 11009 = 'Packet too big'; 11011 = 'Bad request'
    11012 = 'Bad route'; 11013 = 'TTL expired in transit'; 11014 = 'TTL expired in reassembly'
    11015 = 'Parameter problem'; 11016 = 'Source quench'; 11017 = 'Option too big'; 11018 = 'Bad destination'
    11032 = 'Negotiating IPSEC'; 11050 = 'General failure'
}

$script:LogFile = $null
$script:Stats = @{
    Sent = 0; Received = 0; Lost = 0; Min = $null; Max = $null; Sum = 0
    State = ''; DownSince = $null; DownLost = 0; Outages = 0; Longest = $null; Started = $null
}

# ------------------------------------------------------------------ helpers
function Write-LogLine {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if (-not $script:LogFile) { return }
    try {
        Add-Content -LiteralPath $script:LogFile -Value $Text -Encoding UTF8
    } catch {
        Write-Warning ('Could not write to the log file, continuing on screen only: {0}' -f $_.Exception.Message)
        $script:LogFile = $null
    }
}

function Format-Duration {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Get-SafeFileName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Get-PropertyValue {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-TimeoutSupport {
    # PowerShell 7 Test-Connection has -TimeoutSeconds, Windows PowerShell 5.1 does not
    $cmd = Get-Command -Name Test-Connection -ErrorAction Stop
    return (@($cmd.Parameters.Keys) -contains 'TimeoutSeconds')
}

function Get-PingErrorStatus {
    # Status code of a failed request from its error record, independent of the message language:
    # IP_STATUS from a Win32Exception (5.1), 11001 for a host name that cannot be resolved (5.1 and 7)
    param($ErrorRecord)
    $e = Get-PropertyValue $ErrorRecord 'Exception'
    while ($null -ne $e) {
        $socketError = [string](Get-PropertyValue $e 'SocketErrorCode')
        if (@('HostNotFound', 'NoData', 'TryAgain') -contains $socketError) { return $StatusUnresolved }
        $native = Get-PropertyValue $e 'NativeErrorCode'
        if ($null -ne $native -and [int]$native -ge 11001 -and [int]$native -le 11050) { return [int]$native }
        $e = Get-PropertyValue $e 'InnerException'
    }
    return $null
}

function Get-FailureText {
    param($Status)
    if ($null -eq $Status -or $Status -eq $StatusTimedOut) { return 'Request timed out' }
    if ($Status -eq $StatusUnresolved) { return 'Request failed: the host name could not be resolved' }
    $text = $IpStatusText[[int]$Status]
    if (-not $text) { $text = 'status {0}' -f $Status }
    return ('Request failed: {0}' -f $text)
}

function ConvertTo-PingResult {
    # One Test-Connection result (5.1: Win32_PingStatus, 7: PingStatus) or the status of its error
    # -> Success, Address, Time, Ttl, Text, Unresolved
    param($Reply, $ErrorStatus)
    $r = @{ Success = $false; Address = ''; Time = $null; Ttl = $null; Text = 'Request timed out'; Unresolved = $false }

    if ($null -eq $Reply) {
        $r.Text = Get-FailureText $ErrorStatus
        $r.Unresolved = ($null -ne $ErrorStatus -and $ErrorStatus -eq $StatusUnresolved)
        return [pscustomobject]$r
    }

    $statusCode = Get-PropertyValue $Reply 'StatusCode'
    if ($null -ne $statusCode) {
        # Windows PowerShell 5.1 (a Win32_PingStatus is only returned for a reply)
        $address = Get-PropertyValue $Reply 'ProtocolAddress'
        if (-not $address) { $address = Get-PropertyValue $Reply 'IPV4Address' }
        if (-not $address) { $address = Get-PropertyValue $Reply 'Address' }
        $r.Address = [string]$address
        if ([int]$statusCode -eq 0) {
            $r.Success = $true
            $r.Time = [int](Get-PropertyValue $Reply 'ResponseTime')
            $r.Ttl = Get-PropertyValue $Reply 'ResponseTimeToLive'
        } else {
            $r.Text = Get-FailureText ([int]$statusCode)
            $r.Unresolved = ([int]$statusCode -eq $StatusUnresolved)
        }
        return [pscustomobject]$r
    }

    # PowerShell 7
    $status = [string](Get-PropertyValue $Reply 'Status')
    $address = Get-PropertyValue $Reply 'Address'
    if (-not $address) { $address = Get-PropertyValue $Reply 'Destination' }
    $r.Address = [string]$address
    if ($status -eq 'Success') {
        $r.Success = $true
        $r.Time = [int](Get-PropertyValue $Reply 'Latency')
        $options = Get-PropertyValue (Get-PropertyValue $Reply 'Reply') 'Options'
        $r.Ttl = Get-PropertyValue $options 'Ttl'
    } elseif ($status -and $status -ne 'TimedOut') {
        $r.Text = 'Request failed: {0}' -f $status
    }
    return [pscustomobject]$r
}

function Invoke-SinglePing {
    param([bool]$UseTimeout)
    $params = @{ ComputerName = $ComputerName; Count = 1; ErrorAction = 'SilentlyContinue' }
    if ($UseTimeout) { $params['TimeoutSeconds'] = 1 }
    $pingError = $null
    $reply = $null
    try {
        $reply = @(Test-Connection @params -ErrorVariable pingError) | Select-Object -First 1
    } catch {
        $pingError = $_
    }
    $status = $null
    foreach ($record in @($pingError)) {
        if ($null -eq $status -and $null -ne $record) { $status = Get-PingErrorStatus $record }
    }
    return (ConvertTo-PingResult -Reply $reply -ErrorStatus $status)
}

function Add-PingResult {
    param($Result, [datetime]$When)
    $s = $script:Stats
    $stamp = $When.ToString($TimeFormat)

    if ($Result.Success) {
        $s.Received++
        if ($null -eq $s.Min -or $Result.Time -lt $s.Min) { $s.Min = $Result.Time }
        if ($null -eq $s.Max -or $Result.Time -gt $s.Max) { $s.Max = $Result.Time }
        $s.Sum += $Result.Time
        $line = '{0}  Reply from {1}: time={2}ms' -f $stamp, $Result.Address, $Result.Time
        if ($null -ne $Result.Ttl) { $line += (' TTL={0}' -f $Result.Ttl) }
        Write-LogLine $line
        if ($s.State -eq 'DOWN') {
            $outage = $When - $s.DownSince
            if ($null -eq $s.Longest -or $outage -gt $s.Longest) { $s.Longest = $outage }
            Write-LogLine ('{0}  *** {1} UP again after {2} ({3} lost)' -f $stamp, $ComputerName, (Format-Duration $outage), $s.DownLost) 'Green'
        }
        $s.State = 'UP'
        return
    }

    $s.Lost++
    Write-LogLine ('{0}  {1}' -f $stamp, $Result.Text) 'Yellow'
    if ($s.State -ne 'DOWN') {
        $s.State = 'DOWN'
        $s.DownSince = $When
        $s.DownLost = 0
        $s.Outages++
        Write-LogLine ('{0}  *** {1} DOWN since {0}' -f $stamp, $ComputerName) 'Red'
    }
    $s.DownLost++
}

function Write-Summary {
    $s = $script:Stats
    $ended = Get-Date
    $lostPct = 0
    if ($s.Sent -gt 0) { $lostPct = [math]::Round(100 * $s.Lost / $s.Sent, 1) }
    $timeText = 'no replies'
    if ($s.Received -gt 0) {
        $avg = [int][math]::Floor($s.Sum / $s.Received + 0.5)
        $timeText = 'min {0}ms, avg {1}ms, max {2}ms' -f $s.Min, $avg, $s.Max
    }
    Write-LogLine ''
    Write-LogLine ('----- Summary for {0} -----' -f $ComputerName) 'Cyan'
    Write-LogLine (' Started   : {0}' -f $s.Started.ToString($TimeFormat))
    Write-LogLine (' Ended     : {0}  (ran {1})' -f $ended.ToString($TimeFormat), (Format-Duration ($ended - $s.Started)))
    Write-LogLine (' Sent      : {0}' -f $s.Sent)
    Write-LogLine (' Received  : {0}' -f $s.Received)
    $color = 'Green'
    if ($s.Lost -gt 0) { $color = 'Yellow' }
    Write-LogLine (' Lost      : {0} ({1}%)' -f $s.Lost, $lostPct) $color
    Write-LogLine (' Time      : {0}' -f $timeText)
    if ($s.Outages -gt 0) {
        $outageText = '{0}' -f $s.Outages
        if ($null -ne $s.Longest) { $outageText += (', longest {0}' -f (Format-Duration $s.Longest)) }
        Write-LogLine (' Outages   : {0}' -f $outageText) $color
    }
    if ($s.State -eq 'DOWN') {
        Write-LogLine (' Still DOWN since {0}' -f $s.DownSince.ToString($TimeFormat)) 'Red'
    }
    if ($script:LogFile) { Write-Host (' Log file  : {0}' -f $script:LogFile) -ForegroundColor Cyan }
}

# ------------------------------------------------------------------ main
$exitCode = $EXIT_NOT_RUN
$running = $false
try {
    $useTimeout = Test-TimeoutSupport

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        throw ('could not create the log folder {0}' -f $OutputPath)
    }
    $script:Stats.Started = Get-Date
    $logName = 'Ping-{0}-{1}.log' -f (Get-SafeFileName $ComputerName), $script:Stats.Started.ToString('yyyyMMdd-HHmmss')
    $logPath = Join-Path $OutputPath $logName
    Set-Content -LiteralPath $logPath -Value ('Target host = {0}' -f $ComputerName) -Encoding UTF8
    $script:LogFile = $logPath
    Write-Host ('Target host = {0}' -f $ComputerName) -ForegroundColor Cyan
    $countText = 'until Ctrl+C'
    if ($Count -gt 0) { $countText = '{0} requests' -f $Count }
    Write-LogLine ('Started {0}, interval {1} s, {2}' -f $script:Stats.Started.ToString($TimeFormat), $IntervalSeconds, $countText)
    Write-Host ('Log file: {0}' -f $script:LogFile) -ForegroundColor Cyan
    Write-LogLine ''

    $running = $true
    while ($Count -eq 0 -or $script:Stats.Sent -lt $Count) {
        $requestStart = Get-Date
        $script:Stats.Sent++
        $result = Invoke-SinglePing -UseTimeout $useTimeout
        if ($result.Unresolved -and $script:Stats.Sent -eq 1) {
            $running = $false
            throw ('the host name {0} could not be resolved' -f $ComputerName)
        }
        Add-PingResult -Result $result -When $requestStart

        $more = ($Count -eq 0 -or $script:Stats.Sent -lt $Count)
        if ($more -and $IntervalSeconds -gt 0) {
            $wait = [int]($IntervalSeconds * 1000 - ((Get-Date) - $requestStart).TotalMilliseconds)
            if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        }
    }

    $exitCode = $EXIT_OK
    if ($script:Stats.Lost -gt 0) { $exitCode = $EXIT_LOSS }
} catch {
    Write-LogLine ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    $exitCode = $EXIT_NOT_RUN
} finally {
    # Also runs on Ctrl+C
    if ($running) { Write-Summary }
}
exit $exitCode
