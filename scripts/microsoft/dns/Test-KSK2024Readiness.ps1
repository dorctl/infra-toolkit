#Requires -Version 3.0
<#
.SYNOPSIS
    Read-only readiness check for the DNSSEC Root KSK rollover to KSK-2024 (key tag 38696)
    on Windows DNS servers / Domain Controllers.

.DESCRIPTION
    Root KSK rollover: 11-Oct-2026 16:00 UTC (19:00 Israel time).

    The script is READ-ONLY. It does not change any setting, trust anchor or record.

    For every DNS server it checks:
      1. Local validation  - EnableDnsSec + root trust point (".") + state of key tag 38696.
      2. Auto update       - root trust point state and last RFC 5011 active refresh.
      3. Live path test    - test queries through the server: control names, names with a
                             deliberately broken signature, and RFC 8509 trust-anchor
                             sentinels for key tag 38696 (dnstest.dev, by Cloudflare).
      4. Forwarders        - the same live test sent directly to every forwarder.

    It ends with a verdict per server and an overall status:
        NO ACTION REQUIRED / ACTION REQUIRED / MANUAL CHECK REQUIRED

    Decision logic (per server):
      - No root trust anchor, or EnableDnsSec=False  -> the server does not validate the root
        chain itself, the rollover does not affect it locally.
      - Validates locally and key tag 38696 is Valid -> ready.
      - Validates locally and key tag 38696 is missing / AddPending / DSPending / Revoked
                                                      -> ACTION REQUIRED.
      - A sentinel test (through the server or a forwarder) shows KSK-2024 is not trusted
                                                      -> ACTION REQUIRED.
      - Internal forwarder that validates but its KSK-2024 trust cannot be proven
                                                      -> MANUAL CHECK REQUIRED.
      - External forwarder (ISP / Google / Cloudflare etc.) -> provider managed, info only.

    Requirements:
      - Windows Server 2012 or later with the DnsServer PowerShell module
        (DNS role, or RSAT-DNS-Server on a management station).
      - DNS admin rights on the checked servers.
      - Live tests need outbound DNS. Forwarder tests are sent from the machine running the
        script, so running it on the DNS server itself gives the most accurate result.

.PARAMETER ComputerName
    DNS servers to check. Default: the local computer.

.PARAMETER AllDomainControllers
    Check every domain controller in the current AD domain.

.PARAMETER SkipLiveTests
    Configuration checks only, no test queries.

.PARAMETER ReportPath
    Where to save the text report. Default: %TEMP%\KSK2024-Readiness-<host>-<timestamp>.txt

.EXAMPLE
    .\Test-KSK2024Readiness.ps1
    Check the local DNS server.

.EXAMPLE
    .\Test-KSK2024Readiness.ps1 -AllDomainControllers
    Check every DC in the domain.

.EXAMPLE
    .\Test-KSK2024Readiness.ps1 -ComputerName DC01,DC02 -ReportPath C:\Temp\KSK2024.txt

.NOTES
    Mode: Read-only
    Network: live tests query valid/invalid.alg13.dnstest.dev, root-key-sentinel-*.dnstest.dev,
             cloudflare.com and dnssec-failed.org through the checked servers and forwarders.
             Disable with -SkipLiveTests.
    Tested on: mocked scenarios only (Pester), not yet run on a production DC
    Last verified: not yet
    Exit codes: 0 = no action required, 1 = action required, 2 = manual check required,
                3 = the script could not run.
    Version 1.0, 2026-10-08
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [switch]$AllDomainControllers,
    [switch]$SkipLiveTests,
    [string]$ReportPath
)

# ------------------------------------------------------------------ constants
$NewKeyTag        = 38696
$OldKeyTag        = 20326
$RolloverUtc      = [DateTimeOffset]::Parse('2026-10-11T16:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
$SentinelZone     = 'dnstest.dev'
$ControlNames     = @("valid.alg13.$SentinelZone", 'cloudflare.com')
$BogusNames       = @("invalid.alg13.$SentinelZone", 'dnssec-failed.org')
$IsTaName         = "root-key-sentinel-is-ta-$NewKeyTag.$SentinelZone"
$NotTaName        = "root-key-sentinel-not-ta-$NewKeyTag.$SentinelZone"
$RefreshStaleDays = 7
$LocalName        = [Environment]::MachineName

$SEV_OK     = 0
$SEV_CHECK  = 1
$SEV_ACTION = 2

$script:Report = New-Object 'System.Collections.Generic.List[string]'

# ------------------------------------------------------------------ output helpers
function Out-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Report.Add($Text)
}

function Format-Row {
    param([string]$Label, $Value)
    return (' {0,-36}: {1}' -f $Label, $Value)
}

function Get-VerdictText {
    param([int]$Sev)
    switch ($Sev) {
        2       { return 'ACTION REQUIRED' }
        1       { return 'MANUAL CHECK REQUIRED' }
        default { return 'NO ACTION REQUIRED' }
    }
}

function Get-VerdictColor {
    param([int]$Sev)
    switch ($Sev) {
        2       { return 'Red' }
        1       { return 'Yellow' }
        default { return 'Green' }
    }
}

# ------------------------------------------------------------------ generic helpers
function Test-IsLocalComputer {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    $locals = @('.', 'localhost', '127.0.0.1', '::1', $LocalName.ToLowerInvariant())
    if ($env:USERDNSDOMAIN) { $locals += ("$LocalName.$env:USERDNSDOMAIN").ToLowerInvariant() }
    return ($locals -contains $n)
}

function Test-PrivateAddress {
    param([string]$Ip)
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
    $b = $addr.GetAddressBytes()
    if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return (($b[0] -eq 10) -or
                ($b[0] -eq 127) -or
                ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
                ($b[0] -eq 192 -and $b[1] -eq 168) -or
                ($b[0] -eq 169 -and $b[1] -eq 254))
    }
    return ((($b[0] -band 0xFE) -eq 0xFC) -or
            ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0x80) -or
            [System.Net.IPAddress]::IsLoopback($addr))
}

function Get-AnchorKeyTag {
    param($Anchor)
    $d = $Anchor.TrustAnchorData
    if ($null -ne $d) {
        try {
            if ($d.PSObject.Properties['KeyTag'] -and $null -ne $d.KeyTag) { return [int]$d.KeyTag }
        } catch { Write-Verbose $_.Exception.Message }
        try {
            if ($d.CimInstanceProperties -and $d.CimInstanceProperties['KeyTag']) {
                return [int]$d.CimInstanceProperties['KeyTag'].Value
            }
        } catch { Write-Verbose $_.Exception.Message }
    }
    $txt = ($Anchor | Format-List * | Out-String)
    if ($txt -match '\[(\d{1,5})\]') { return [int]$Matches[1] }
    return $null
}

function Get-KeyState {
    param($Anchors, [int]$Tag)
    $m = @($Anchors | Where-Object { $_.KeyTag -eq $Tag })
    if ($m.Count -eq 0) { return 'Absent' }
    if (@($m | Where-Object { $_.State -match '^(Valid|Active)$' }).Count -gt 0) { return 'Valid' }
    if (@($m | Where-Object { $_.State -eq 'Missing' }).Count -gt 0) { return 'Missing' }
    return ((@($m | ForEach-Object { $_.State }) | Sort-Object -Unique) -join ',')
}

# ------------------------------------------------------------------ live DNS tests
function Invoke-DnsProbe {
    param([string]$Name, [string]$Server)
    try {
        $r = Resolve-DnsName -Name $Name -Type A -Server $Server -DnsOnly -NoHostsFile -DnssecOk -ErrorAction Stop
        if (@($r | Where-Object { [string]$_.Type -eq 'A' }).Count -gt 0) { return 'OK' }
        return 'NOANSWER'
    } catch {
        $id   = [string]$_.FullyQualifiedErrorId
        $msg  = [string]$_.Exception.Message
        $code = 0
        if ($_.Exception -is [System.ComponentModel.Win32Exception]) { $code = $_.Exception.NativeErrorCode }
        if ($code -eq 9002 -or $id -match 'SERVER_FAILURE' -or $msg -match 'server failure') { return 'SERVFAIL' }
        if ($code -eq 9003 -or $id -match 'NAME_ERROR'     -or $msg -match 'does not exist')  { return 'NXDOMAIN' }
        if ($code -eq 1460 -or $id -match 'TIMEOUT'        -or $msg -match 'time ?out|timed out') { return 'TIMEOUT' }
        if ($code -eq 9501 -or $id -match 'NO_RECORDS') { return 'NOANSWER' }
        return 'ERROR'
    }
}

function New-PathResult {
    param([string]$Result, [string]$Detail, [string]$Raw)
    return [pscustomobject]@{ Result = $Result; Detail = $Detail; Raw = $Raw }
}

function Test-ResolutionPath {
    param([string]$Server)
    $ctl = @(foreach ($n in $ControlNames) { Invoke-DnsProbe -Name $n -Server $Server })
    $raw = "control=$($ctl -join '/')"
    if ($ctl -notcontains 'OK') {
        return New-PathResult 'UNREACHABLE' "no answer for control queries ($($ctl -join '/'))" $raw
    }

    $bog = @(foreach ($n in $BogusNames) { Invoke-DnsProbe -Name $n -Server $Server })
    $raw += " broken-sig=$($bog -join '/')"
    if ($bog -notcontains 'SERVFAIL') {
        if ($bog -contains 'OK') {
            return New-PathResult 'NOT_VALIDATING' 'names with a broken signature resolve: no DNSSEC validation on this path' $raw
        }
        return New-PathResult 'INCONCLUSIVE' "broken-signature tests returned $($bog -join '/')" $raw
    }

    if ($ctl[0] -ne 'OK') {
        return New-PathResult 'VALIDATING' 'DNSSEC validation detected; sentinel zone not reachable, KSK-2024 trust not tested' $raw
    }

    $isTa  = Invoke-DnsProbe -Name $IsTaName  -Server $Server
    $notTa = Invoke-DnsProbe -Name $NotTaName -Server $Server
    $raw  += " is-ta-$NewKeyTag=$isTa not-ta-$NewKeyTag=$notTa"
    if ($isTa -eq 'OK' -and $notTa -eq 'SERVFAIL') {
        return New-PathResult 'READY' 'DNSSEC validation detected; RFC 8509 sentinel confirms KSK-2024 is trusted' $raw
    }
    if ($isTa -eq 'SERVFAIL' -and $notTa -eq 'OK') {
        return New-PathResult 'NOT_READY' 'DNSSEC validation detected; RFC 8509 sentinel shows KSK-2024 is NOT trusted' $raw
    }
    if ($isTa -eq 'OK' -and $notTa -eq 'OK') {
        return New-PathResult 'VALIDATING' 'DNSSEC validation detected; no RFC 8509 sentinel support, KSK-2024 trust not provable by query' $raw
    }
    return New-PathResult 'VALIDATING' "DNSSEC validation detected; sentinel result unclear (is-ta=$isTa, not-ta=$notTa)" $raw
}

# ------------------------------------------------------------------ server configuration
function Get-ServerDnssecState {
    param([string]$Computer)

    $isLocal = Test-IsLocalComputer $Computer
    $cn = @{}
    if (-not $isLocal) { $cn['ComputerName'] = $Computer }

    $s = [pscustomobject]@{
        Computer            = $Computer
        IsLocal             = $isLocal
        QueryTarget         = $(if ($isLocal) { '127.0.0.1' } else { $Computer })
        ConfigRead          = $false
        Error               = ''
        EnableDnsSec        = $null
        RootTrustAnchorsURL = ''
        ExtraSettings       = @()
        Anchors             = @()
        RootTrustPoint      = $null
        NewKeyState         = 'Absent'
        OldKeyState         = 'Absent'
        Forwarders          = @()
        UseRootHint         = $null
        LocalStatus         = 'UNKNOWN'
        Notes               = (New-Object 'System.Collections.Generic.List[string]')
        Addresses           = @()
        Path                = $null
        ForwarderResults    = @()
        Verdict             = $null
    }

    try {
        $setting = Get-DnsServerSetting -All @cn -ErrorAction Stop
        $s.ConfigRead = $true
    } catch {
        $s.Error = $_.Exception.Message
        return $s
    }

    $s.EnableDnsSec        = $setting.EnableDnsSec
    $s.RootTrustAnchorsURL = [string]$setting.RootTrustAnchorsURL
    $s.ExtraSettings = @($setting.PSObject.Properties |
        Where-Object { $_.Name -match 'TrustAnchor|DnsSec' -and $_.Name -notin @('EnableDnsSec', 'RootTrustAnchorsURL') } |
        ForEach-Object { '{0}={1}' -f $_.Name, $_.Value })

    # Root trust point
    $tpReadOk = $true
    try {
        $s.RootTrustPoint = @(Get-DnsServerTrustPoint @cn -ErrorAction Stop |
            Where-Object { ([string]$_.TrustPointName).Trim() -eq '.' }) | Select-Object -First 1
    } catch {
        $tpReadOk = $false
        $s.Notes.Add("Could not read trust points: $($_.Exception.Message)")
    }

    # Root trust anchors
    $rawAnchors = @()
    try { $rawAnchors = @(Get-DnsServerTrustAnchor -Name '.' @cn -ErrorAction Stop) } catch { $rawAnchors = @() }
    $s.Anchors = @(foreach ($a in $rawAnchors) {
        [pscustomobject]@{
            KeyTag = Get-AnchorKeyTag $a
            Type   = [string]$a.TrustAnchorType
            State  = ([string]$a.TrustAnchorState) -replace '\s', ''
        }
    })
    $s.NewKeyState = Get-KeyState $s.Anchors $NewKeyTag
    $s.OldKeyState = Get-KeyState $s.Anchors $OldKeyTag

    # Forwarders
    try {
        $f = Get-DnsServerForwarder @cn -ErrorAction Stop
        $s.Forwarders  = @($f.IPAddress | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $s.UseRootHint = $f.UseRootHint
    } catch {
        $s.Notes.Add("Could not read forwarders: $($_.Exception.Message)")
    }

    # Addresses of this server (to recognise it when another server forwards to it)
    try {
        $hostToResolve = $(if ($isLocal) { $LocalName } else { $Computer })
        $s.Addresses = @([System.Net.Dns]::GetHostAddresses($hostToResolve) | ForEach-Object { $_.ToString() })
    } catch { Write-Verbose $_.Exception.Message }

    # Local status
    $hasRoot = ($s.Anchors.Count -gt 0) -or ($null -ne $s.RootTrustPoint)
    if (-not $hasRoot -and -not $tpReadOk) {
        $s.LocalStatus = 'UNKNOWN'
        $s.Notes.Add('Root trust anchors could not be read, local validation state is unknown.')
    } elseif (-not $hasRoot) {
        $s.LocalStatus = 'NOT_VALIDATING'
        $s.Notes.Add('No root trust anchor: the server does not validate the root chain itself. Any validation happens upstream (forwarders).')
    } elseif ($s.EnableDnsSec -eq $false) {
        $s.LocalStatus = 'NOT_VALIDATING'
        $s.Notes.Add("Root trust anchors exist but DNSSEC validation is disabled (EnableDnsSec=False). If validation is enabled later, key tag $NewKeyTag must be Valid first.")
    } elseif ($s.Anchors.Count -eq 0) {
        $s.LocalStatus = 'UNKNOWN'
        $s.Notes.Add('A root trust point exists but its trust anchors could not be listed.')
    } elseif ($s.NewKeyState -eq 'Valid') {
        $s.LocalStatus = 'READY'
    } elseif ($s.NewKeyState -eq 'Missing') {
        $s.LocalStatus = 'UNKNOWN'
        $s.Notes.Add("Key tag $NewKeyTag is trusted but was not seen in the last RFC 5011 refresh (state Missing). Check that the server can query the root servers.")
    } else {
        $s.LocalStatus = 'NOT_READY'
        $s.Notes.Add("The server validates locally but key tag $NewKeyTag is '$($s.NewKeyState)'. Resolution of signed zones will fail after the rollover.")
    }

    # RFC 5011 refresh health (only relevant when the server validates locally)
    if ($s.RootTrustPoint -and $s.LocalStatus -ne 'NOT_VALIDATING') {
        $tpState = [string]$s.RootTrustPoint.TrustPointState
        if ($tpState -and $tpState -notmatch '^Active$') {
            $s.Notes.Add("Root trust point state is '$tpState' (expected Active).")
        }
        $last = $s.RootTrustPoint.LastActiveRefreshTime -as [datetime]
        if ($last -and ((Get-Date) - $last).TotalDays -gt $RefreshStaleDays) {
            $s.Notes.Add("Last RFC 5011 active refresh was $($last.ToString('yyyy-MM-dd')). Automatic trust anchor updates may not be working (check outbound DNS to the root servers).")
        }
    }

    return $s
}

# ------------------------------------------------------------------ assessment
function Get-ForwarderAssessment {
    param([string]$Ip, $Path, $AllStates)

    $scope  = $(if (Test-PrivateAddress $Ip) { 'internal' } else { 'external' })
    $owner  = @($AllStates | Where-Object { $_.ConfigRead -and ($_.Addresses -contains $Ip) }) | Select-Object -First 1
    $result = 'NOT_TESTED'
    $detail = ''
    if ($Path) { $result = $Path.Result; $detail = $Path.Detail }

    $sev  = $SEV_OK
    $text = ''
    if ($result -eq 'NOT_READY') {
        $sev = $SEV_ACTION
        if ($scope -eq 'internal') { $text = "$detail. Fix the trust anchors on this internal resolver." }
        else                       { $text = "$detail. Contact the DNS provider or switch to a ready forwarder." }
    } elseif ($owner) {
        $text = "is DNS server '$($owner.Computer)', assessed separately in this report"
        if ($detail) { $text += " ($detail)" }
    } elseif ($result -eq 'NOT_TESTED') {
        $text = 'not tested (-SkipLiveTests)'
        if ($scope -eq 'internal') { $sev = $SEV_CHECK; $text += '. Internal resolver: verify its trust anchors manually.' }
    } elseif ($result -eq 'NOT_VALIDATING' -or $result -eq 'READY') {
        $text = $detail
    } else {
        if ($scope -eq 'internal') {
            $sev  = $SEV_CHECK
            $text = "$detail. Internal resolver: verify that key tag $NewKeyTag is trusted on it (if it is a Windows DNS server, run this script with -ComputerName)."
        } else {
            $text = "$detail. External resolver, managed by the provider."
        }
    }
    return [pscustomobject]@{ Ip = $Ip; Scope = $scope; Result = $result; Sev = $sev; Text = $text }
}

function Get-ServerVerdict {
    param($s)
    $items = New-Object 'System.Collections.Generic.List[object]'
    if (-not $s.ConfigRead) {
        $items.Add([pscustomobject]@{ Sev = $SEV_CHECK; Text = "Could not read the DNS server configuration: $($s.Error)" })
    } else {
        switch ($s.LocalStatus) {
            'READY'          { $items.Add([pscustomobject]@{ Sev = $SEV_OK;     Text = "Validates locally and trusts KSK-2024 (key tag $NewKeyTag is Valid)." }) }
            'NOT_VALIDATING' { $items.Add([pscustomobject]@{ Sev = $SEV_OK;     Text = 'Does not validate the root chain locally.' }) }
            'NOT_READY'      { $items.Add([pscustomobject]@{ Sev = $SEV_ACTION; Text = "Validates locally but KSK-2024 (key tag $NewKeyTag) is '$($s.NewKeyState)'." }) }
            default          { $items.Add([pscustomobject]@{ Sev = $SEV_CHECK;  Text = 'Local trust anchor state could not be confirmed (see notes).' }) }
        }
        if ($s.Path) {
            if ($s.Path.Result -eq 'NOT_READY') {
                $items.Add([pscustomobject]@{ Sev = $SEV_ACTION; Text = 'Live sentinel test through this server: KSK-2024 is NOT trusted on the resolution path.' })
            } elseif ($s.Path.Result -eq 'READY') {
                $items.Add([pscustomobject]@{ Sev = $SEV_OK; Text = 'Live sentinel test through this server confirms KSK-2024 is trusted.' })
            }
        }
        foreach ($f in $s.ForwarderResults) {
            $items.Add([pscustomobject]@{ Sev = $f.Sev; Text = "Forwarder $($f.Ip) ($($f.Scope)): $($f.Text)" })
        }
    }
    $sev = 0
    foreach ($i in $items) { if ($i.Sev -gt $sev) { $sev = $i.Sev } }
    return [pscustomobject]@{ Sev = $sev; Items = $items.ToArray() }
}

# ------------------------------------------------------------------ report section
function Write-ServerSection {
    param($s, [int]$Index, [int]$Total)

    Out-Line ''
    Out-Line ('-' * 76) 'Cyan'
    Out-Line (' [{0}/{1}] {2}' -f $Index, $Total, $s.Computer) 'Cyan'
    Out-Line ('-' * 76) 'Cyan'

    if (-not $s.ConfigRead) {
        Out-Line (Format-Row 'DNS server configuration' "could not be read: $($s.Error)") 'Yellow'
    } else {
        Out-Line (Format-Row 'DNSSEC validation (EnableDnsSec)' $s.EnableDnsSec)
        Out-Line (Format-Row 'RootTrustAnchorsURL' $s.RootTrustAnchorsURL)
        foreach ($x in $s.ExtraSettings) { Out-Line (Format-Row 'Other DNSSEC setting' $x) }

        if ($s.RootTrustPoint) {
            $tp = $s.RootTrustPoint
            Out-Line (Format-Row 'Root trust point (.)' ('{0} (last refresh {1}, next {2})' -f $tp.TrustPointState, $tp.LastActiveRefreshTime, $tp.NextActiveRefreshTime))
        } else {
            Out-Line (Format-Row 'Root trust point (.)' 'none')
        }

        if ($s.Anchors.Count -gt 0) {
            Out-Line (Format-Row 'Root trust anchors' '')
            foreach ($a in $s.Anchors) {
                Out-Line ('      key tag {0,-6}  {1,-7}  {2}' -f $a.KeyTag, $a.Type, $a.State)
            }
        } else {
            Out-Line (Format-Row 'Root trust anchors' 'none')
        }

        $ksText  = $s.NewKeyState
        $ksColor = 'Gray'
        if ($s.LocalStatus -eq 'NOT_VALIDATING' -and $s.NewKeyState -eq 'Absent') { $ksText = 'n/a (no local root validation)' }
        elseif ($s.NewKeyState -eq 'Valid') { $ksColor = 'Green' }
        elseif ($s.LocalStatus -eq 'NOT_READY') { $ksColor = 'Red' }
        Out-Line (Format-Row "KSK-2024 (key tag $NewKeyTag)" $ksText) $ksColor

        $fw = $(if ($s.Forwarders.Count -gt 0) { $s.Forwarders -join ', ' } else { 'none (root hints)' })
        Out-Line (Format-Row 'Forwarders' ('{0} (UseRootHint={1})' -f $fw, $s.UseRootHint))
        Out-Line (Format-Row 'Local validation status' $s.LocalStatus)

        if ($s.Path) {
            $pColor = $(if ($s.Path.Result -eq 'NOT_READY') { 'Red' } else { 'Gray' })
            Out-Line (Format-Row 'Live test through this server' ('{0}: {1}' -f $s.Path.Result, $s.Path.Detail)) $pColor
            Out-Line (Format-Row '   raw answers' $s.Path.Raw) 'DarkGray'
        }

        foreach ($f in $s.ForwarderResults) {
            Out-Line (Format-Row ('Forwarder {0} ({1})' -f $f.Ip, $f.Scope) ('{0}: {1}' -f $f.Result, $f.Text)) (Get-VerdictColor $f.Sev)
        }

        if ($s.Notes.Count -gt 0) {
            Out-Line ' Notes:'
            foreach ($n in $s.Notes) { Out-Line "   - $n" 'Yellow' }
        }
    }

    Out-Line (' VERDICT: ' + (Get-VerdictText $s.Verdict.Sev)) (Get-VerdictColor $s.Verdict.Sev)
}

# ================================================================== main
try {
    if (-not (Get-Command Get-DnsServerSetting -ErrorAction SilentlyContinue)) {
        Write-Host 'The DnsServer PowerShell module is not available on this machine.' -ForegroundColor Red
        Write-Host 'Run the script on a DNS server / DC, or install RSAT-DNS-Server and use -ComputerName.' -ForegroundColor Red
        exit 3
    }

    $liveTests = -not $SkipLiveTests
    if ($liveTests -and -not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        Write-Host 'Resolve-DnsName is not available, live tests are skipped.' -ForegroundColor Yellow
        $liveTests = $false
    }

    # Targets
    $targets = @()
    if ($AllDomainControllers) {
        try {
            $targets += @([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers | ForEach-Object { $_.Name })
        } catch {
            Write-Host "Could not enumerate domain controllers: $($_.Exception.Message)" -ForegroundColor Red
            exit 3
        }
    }
    if ($ComputerName) { $targets += $ComputerName }
    if ($targets.Count -eq 0) { $targets = @($LocalName) }
    $targets = @($targets | Where-Object { $_ } | Sort-Object -Unique)

    $now       = Get-Date
    $hoursLeft = [Math]::Round(($RolloverUtc - [DateTimeOffset]::UtcNow).TotalHours, 1)
    $whenText  = $(if ($hoursLeft -gt 0) { "in $hoursLeft hours" } else { 'already took place' })

    Out-Line ('=' * 76) 'Cyan'
    Out-Line ' DNSSEC Root KSK-2024 (key tag 38696) readiness check - Windows DNS' 'Cyan'
    Out-Line ('=' * 76) 'Cyan'
    Out-Line (Format-Row 'Run on' ('{0} as {1}' -f $LocalName, [Environment]::UserName))
    Out-Line (Format-Row 'Run at' $now.ToString('yyyy-MM-dd HH:mm'))
    Out-Line (Format-Row 'Rollover' "2026-10-11 16:00 UTC / 19:00 Israel ($whenText)")
    Out-Line (Format-Row 'Servers' ($targets -join ', '))
    Out-Line (Format-Row 'Live tests' $(if ($liveTests) { 'yes' } else { 'no' }))
    Out-Line (Format-Row 'Mode' 'READ-ONLY, nothing is changed')

    # Pass 1: configuration
    $states = @()
    foreach ($t in $targets) {
        Write-Host "  Reading configuration of $t ..." -ForegroundColor DarkGray
        $states += Get-ServerDnssecState $t
    }

    # Pass 2: live tests and forwarders
    $fwdCache = @{}
    foreach ($s in $states) {
        if (-not $s.ConfigRead) { continue }
        if ($liveTests) {
            Write-Host "  Live DNS tests through $($s.Computer) ..." -ForegroundColor DarkGray
            $s.Path = Test-ResolutionPath $s.QueryTarget
        }
        $results = @()
        foreach ($ip in $s.Forwarders) {
            $p = $null
            if ($liveTests) {
                if (-not $fwdCache.ContainsKey($ip)) {
                    Write-Host "  Live DNS tests against forwarder $ip ..." -ForegroundColor DarkGray
                    $fwdCache[$ip] = Test-ResolutionPath $ip
                }
                $p = $fwdCache[$ip]
            }
            $results += Get-ForwarderAssessment -Ip $ip -Path $p -AllStates $states
        }
        $s.ForwarderResults = $results
    }

    # Verdicts and per-server sections
    $i = 0
    foreach ($s in $states) {
        $i++
        $s.Verdict = Get-ServerVerdict $s
        Write-ServerSection $s $i $states.Count
    }

    $overall = 0
    foreach ($s in $states) { if ($s.Verdict.Sev -gt $overall) { $overall = $s.Verdict.Sev } }

    # Final status
    Out-Line ''
    Out-Line ('=' * 76) 'Cyan'
    Out-Line ' FINAL STATUS' 'Cyan'
    Out-Line ('=' * 76) 'Cyan'
    foreach ($s in $states) {
        Out-Line (' {0,-34} {1}' -f $s.Computer, (Get-VerdictText $s.Verdict.Sev)) (Get-VerdictColor $s.Verdict.Sev)
    }
    Out-Line ('-' * 76) 'Cyan'
    Out-Line (' OVERALL: ' + (Get-VerdictText $overall)) (Get-VerdictColor $overall)
    Out-Line ('=' * 76) 'Cyan'

    if ($overall -gt 0) {
        Out-Line ''
        Out-Line ' Findings:'
        foreach ($s in $states) {
            foreach ($it in $s.Verdict.Items) {
                if ($it.Sev -gt 0) {
                    Out-Line ('  - [{0}] {1}: {2}' -f (Get-VerdictText $it.Sev), $s.Computer, $it.Text) (Get-VerdictColor $it.Sev)
                }
            }
        }
    }

    if (@($states | Where-Object { $_.LocalStatus -eq 'NOT_READY' }).Count -gt 0) {
        Out-Line ''
        Out-Line ' Remediation for servers that validate locally without KSK-2024 (decide with the customer):'
        Out-Line '  Option A - keep local validation:'
        Out-Line '    1. Make sure the server can reach the root servers (UDP/TCP 53) and https://data.iana.org.'
        Out-Line '    2. Reload the root trust anchors from RootTrustAnchorsURL:'
        Out-Line '         Add-DnsServerTrustAnchor -Root -ComputerName <server>'
        Out-Line '       (or DNS Manager > Trust Points > right-click > Import > Retrieve Trust Anchors)'
        Out-Line '    3. Run this script again until key tag 38696 shows Valid.'
        Out-Line '  Option B - validation is done by the forwarders, the server does not need its own:'
        Out-Line '    remove the root trust point (.) under DNS Manager > Trust Points.'
        Out-Line '  Note: on AD-integrated DNS, trust anchors are stored in AD and replicate to the other DNS servers.'
    }

    Out-Line ''
    Out-Line ' Scope: the Windows DNS servers above and their forwarders. Other components that validate'
    Out-Line ' DNSSEC on their own (firewalls, VPN, routers, mail gateways, BIND/Unbound resolvers)'
    Out-Line ' are not covered and must be checked separately.'

    if (-not $ReportPath) {
        $ReportPath = Join-Path ([System.IO.Path]::GetTempPath()) ('KSK2024-Readiness-{0}-{1}.txt' -f $LocalName, $now.ToString('yyyyMMdd-HHmm'))
    }
    try {
        $script:Report | Out-File -FilePath $ReportPath -Encoding UTF8 -ErrorAction Stop
        Write-Host ''
        Write-Host " Report saved to: $ReportPath" -ForegroundColor Cyan
    } catch {
        Write-Host " Could not save the report to $ReportPath : $($_.Exception.Message)" -ForegroundColor Yellow
    }

    switch ($overall) {
        2       { exit 1 }
        1       { exit 2 }
        default { exit 0 }
    }
} catch {
    Write-Host "Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 3
}
