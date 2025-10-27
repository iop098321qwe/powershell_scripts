<# 
UserProfileDataPruner.ps1
Prune stale local user profile data on Windows workstations.

- Deletes only on-disk profile data via Win32_UserProfile.Delete()
- Never deletes user accounts
- Skips servers (ProductType != 1)
- Parameters:
    -DryRun                -> shows [DRY-RUN]: lines; no deletions
    -InactiveDays [int]    -> default 90
    -PilotTestingDevices   -> optional comma-separated list or string[]; if omitted, auto-discovers all enabled Windows workstations in AD

Output:
  [INFO]: Total Hosts Queried: <N>
  [INFO]: Skipped host(s) due to WinRM/Connectivity/TimeDifference/SPN issues: <N>
  [DRY-RUN]/[INFO]: Deleting X profile(s) on "<HOST>" (user1,user2,...)   # per host
  <ASCII summary table at the bottom>
#>

[CmdletBinding()]
param(
  [switch]$DryRun,
  [int]$InactiveDays = 90,
  [string[]]$PilotTestingDevices
)

begin {
  function Write-Info([string]$msg){ Write-Host "[INFO]: $msg" }
  function Write-Dry ([string]$msg){ Write-Host "[DRY-RUN]: $msg" }

  function Convert-LastUse {
    param([object]$raw)
    if ($null -eq $raw) { return $null }
    if ($raw -is [datetime]) {
      $dt = [datetime]$raw
      if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt } else { return $dt.ToUniversalTime() }
    }
    if ($raw -is [int64] -or $raw -is [uint64] -or $raw -is [int] -or ($raw -is [string] -and $raw -match '^\d+$')) {
      try { return [DateTime]::FromFileTimeUtc([int64]$raw) } catch { return $null }
    }
    if ($raw -is [string] -and $raw -match '^\d{14}\.\d{6}[-+]\d{3}$') {
      try { $d = [System.Management.ManagementDateTimeConverter]::ToDateTime($raw); return $d.ToUniversalTime() }
      catch { return $null }
    }
    if ($raw -is [string]) {
      $tmp = $null
      if ([DateTime]::TryParse($raw, [ref]$tmp)) { return $tmp.ToUniversalTime() }
    }
    return $null
  }

  function Try-TranslateSid($sid) {
    try {
      (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch { $null }
  }

  function Test-HostOnline {
    param([string]$Computer)
    try { Test-WSMan -ComputerName $Computer -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
  }

  function Show-AsciiTable {
    param([hashtable]$Data)
    # Keep order if [ordered] was used
    $keys   = @($Data.Keys)
    $values = $keys | ForEach-Object { [string]$Data[$_] }
    $wKey   = [Math]::Max(4, ($keys   | ForEach-Object { $_.ToString().Length }  | Measure-Object -Maximum).Maximum)
    $wVal   = [Math]::Max(5, ($values | ForEach-Object { $_.ToString().Length }  | Measure-Object -Maximum).Maximum)
    $sep    = '+' + ('-'*($wKey+2)) + '+' + ('-'*($wVal+2)) + '+'
    Write-Host $sep
    foreach ($k in $keys) {
      $v = [string]$Data[$k]
      Write-Host ('| {0} | {1} |' -f $k.PadRight($wKey), $v.PadRight($wVal))
    }
    Write-Host $sep
  }

  # Normalize any comma-separated single string into an array
  if ($PilotTestingDevices -and $PilotTestingDevices.Count -eq 1 -and $PilotTestingDevices[0] -match ',') {
    $PilotTestingDevices = $PilotTestingDevices[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  }

  # Targets: use provided list, else discover workstations from AD
  $Targets = @()
  if ($PilotTestingDevices -and ($PilotTestingDevices | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $Targets = $PilotTestingDevices | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
  } else {
    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { throw "ActiveDirectory module not found. Install RSAT or specify -PilotTestingDevices." }

    # Discover enabled Windows workstations (exclude servers)
    $ad = Get-ADComputer -Filter * -Properties OperatingSystem, DNSHostName, Enabled
    $Targets = $ad |
      Where-Object {
        $_.Enabled -and $_.DNSHostName -and
        ($_.OperatingSystem -like 'Windows*') -and
        ($_.OperatingSystem -notmatch 'Server')
      } |
      Select-Object -ExpandProperty DNSHostName
  }

  if (-not $Targets -or $Targets.Count -eq 0) { throw "No eligible Windows workstations to query." }

  $CutoffUtc = [DateTime]::UtcNow.AddDays(-$InactiveDays)
  $Throttle  = 25

  # ---------- Remote blocks ----------

  $RemoteEnumerateProfiles = {
    param([datetime]$CutoffUtc)

    function Convert-LastUse {
      param([object]$raw)
      if ($null -eq $raw) { return $null }
      if ($raw -is [datetime]) {
        $dt = [datetime]$raw
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt } else { return $dt.ToUniversalTime() }
      }
      if ($raw -is [int64] -or $raw -is [uint64] -or $raw -is [int] -or ($raw -is [string] -and $raw -match '^\d+$')) {
        try { return [DateTime]::FromFileTimeUtc([int64]$raw) } catch { return $null }
      }
      if ($raw -is [string] -and $raw -match '^\d{14}\.\d{6}[-+]\d{3}$') {
        try { $d = [System.Management.ManagementDateTimeConverter]::ToDateTime($raw); return $d.ToUniversalTime() }
        catch { return $null }
      }
      if ($raw -is [string]) {
        $tmp = $null
        if ([DateTime]::TryParse($raw, [ref]$tmp)) { return $tmp.ToUniversalTime() }
      }
      return $null
    }

    function Try-TranslateSid($sid) {
      try { (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value }
      catch { $null }
    }

    # Skip non-workstations
    try {
      $hasCIM = [bool](Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)
      $os = if ($hasCIM) { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
            else          { Get-WmiObject  Win32_OperatingSystem -ErrorAction Stop }
      if ($os.ProductType -ne 1) { return } # not a workstation
    } catch { return }

    try {
      $hasCIM = [bool](Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)
      $profiles = if ($hasCIM) {
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop
      } else {
        Get-WmiObject  -Class Win32_UserProfile      -ErrorAction Stop
      }

      $profiles = $profiles | Where-Object {
        $_.Special -eq $false -and
        $_.Loaded  -eq $false -and
        $_.LocalPath -like 'C:\Users\*'
      }

      foreach ($p in $profiles) {
        $sid       = $p.SID
        $nameGuess = Split-Path $p.LocalPath -Leaf
        $acc       = Try-TranslateSid $sid
        $accName   = if ($acc -and ($acc -like '*\*')) { ($acc -split '\\',2)[1] } else { $nameGuess }
        $luUtc     = Convert-LastUse ($p.PSObject.Properties['LastUseTime'].Value)

        # Optional fast size (not always present)
        $sizeBytes = $null
        $szProp = $p.PSObject.Properties['Size']
        if ($szProp -and $szProp.Value -ne $null) { try { $sizeBytes = [int64]$szProp.Value } catch { } }

        $stale = ($null -eq $luUtc) -or ($luUtc -lt $CutoffUtc)

        [PSCustomObject]@{
          Computer    = $env:COMPUTERNAME
          SID         = $sid
          AccountName = $accName
          AccountFQN  = $acc
          LocalPath   = $p.LocalPath
          LastUseUtc  = $luUtc
          Eligible    = $stale
          SizeBytes   = $sizeBytes
        }
      }
    } catch {
      Write-Error ($_.Exception.Message)
    }
  }

  $RemoteDeleteProfiles = {
    param([string[]]$SIDs)
    $results = @()
    $hasCIM = [bool](Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)
    foreach ($sid in $SIDs) {
      try {
        if ($hasCIM) {
          $obj = Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='{0}'" -f $sid) -ErrorAction Stop
          if (-not $obj -or $obj.Loaded -or $obj.Special) { $results += [pscustomobject]@{SID=$sid;Deleted=$false;Code='SKIP';Message='Not found or loaded/special'}; continue }
          $rv = Invoke-CimMethod -InputObject $obj -MethodName Delete -ErrorAction Stop
          if ($rv.ReturnValue -eq 0) { $results += [pscustomobject]@{SID=$sid;Deleted=$true; Code=0; Message='OK'} }
          else                       { $results += [pscustomobject]@{SID=$sid;Deleted=$false;Code=$rv.ReturnValue;Message='Delete returned non-zero'} }
        } else {
          $obj = Get-WmiObject -Class Win32_UserProfile -Filter ("SID='{0}'" -f $sid) -ErrorAction Stop
          if (-not $obj -or $obj.Loaded -or $obj.Special) { $results += [pscustomobject]@{SID=$sid;Deleted=$false;Code='SKIP';Message='Not found or loaded/special'}; continue }
          $rv = $obj.Delete()
          if ($rv.ReturnValue -eq 0) { $results += [pscustomobject]@{SID=$sid;Deleted=$true; Code=0; Message='OK'} }
          else                       { $results += [pscustomobject]@{SID=$sid;Deleted=$false;Code=$rv.ReturnValue;Message='Delete returned non-zero'} }
        }
      } catch {
        $results += [pscustomobject]@{SID=$sid;Deleted=$false;Code='EXC';Message=$_.Exception.Message}
      }
    }
    return $results
  }

  $SkippedHosts = New-Object System.Collections.Generic.HashSet[string]  # names we couldn’t query or errored on
}

process {
  # Reachability (WSMan) filter
  $TotalHostsQueried = $Targets.Count
  $reachable = @()
  foreach ($c in $Targets) {
    if (Test-HostOnline $c) { $reachable += $c } else { $null = $SkippedHosts.Add([string]$c) }
  }

  if (-not $reachable) {
    Write-Info ("Total Hosts Queried: {0}" -f $TotalHostsQueried)
    Write-Info ("Skipped host(s) due to WinRM/Connectivity/TimeDifference/SPN issues: {0}" -f $SkippedHosts.Count)
    throw "No reachable hosts via WinRM."
  }

  # Inventory
  $remoteErrors = @()
  $inv = Invoke-Command -ComputerName $reachable -ThrottleLimit 25 `
          -ScriptBlock $RemoteEnumerateProfiles -ArgumentList $CutoffUtc `
          -ErrorAction Continue -ErrorVariable +remoteErrors

  foreach ($e in $remoteErrors) {
    if ($e.PSComputerName) { $null = $SkippedHosts.Add([string]$e.PSComputerName) }
  }

  $rows = $inv | Where-Object { $_ -and $_.SID -and $_.LocalPath -like 'C:\Users\*' }
  $eligibleRows = $rows | Where-Object { $_.Eligible -eq $true }

  # Plan per host
  $plan = @{}
  foreach ($r in $eligibleRows) {
    if (-not $plan.ContainsKey($r.Computer)) {
      $plan[$r.Computer] = [PSCustomObject]@{
        SIDs  = New-Object System.Collections.Generic.List[string]
        Names = New-Object System.Collections.Generic.List[string]
        Size  = [int64]0
      }
    }
    $plan[$r.Computer].SIDs.Add($r.SID)
    $plan[$r.Computer].Names.Add($r.AccountName)
    if ($r.SizeBytes -ne $null) { $plan[$r.Computer].Size += [int64]$r.SizeBytes }
  }

  # Host-level counters first
  Write-Info ("Total Hosts Queried: {0}" -f $TotalHostsQueried)
  Write-Info ("Skipped host(s) due to WinRM/Connectivity/TimeDifference/SPN issues: {0}" -f $SkippedHosts.Count)

  # Per-host summary lines
  $hostKeys = $plan.Keys | Sort-Object
  foreach ($h in $hostKeys) {
    $sids  = $plan[$h].SIDs  | Sort-Object -Unique
    $names = $plan[$h].Names | Where-Object { $_ } | Sort-Object -Unique
    $list  = '(' + ($names -join ',') + ')'
    if ($DryRun) { Write-Dry ("Deleting {0} profile(s) on ""{1}"" {2}" -f $sids.Count, $h, $list) }
    else         { Write-Info("Deleting {0} profile(s) on ""{1}"" {2}" -f $sids.Count, $h, $list) }
  }

  # Execute deletes when not DryRun
  if (-not $DryRun -and $hostKeys.Count -gt 0) {
    foreach ($h in $hostKeys) {
      $sids = $plan[$h].SIDs | Sort-Object -Unique
      try {
        $null = Invoke-Command -ComputerName $h -ThrottleLimit 1 `
                -ScriptBlock $RemoteDeleteProfiles -ArgumentList (,$sids) `
                -ErrorAction Stop
      } catch {
        Write-Info ("Host ""{0}"": delete attempt failed: {1}" -f $h, $_.Exception.Message)
      }
    }
  }

  # ---------- Bottom summary table ----------
  $analyzed      = $rows.Count
  $evaluated     = $rows.Count
  $eligibleCount = $eligibleRows.Count
  $fleetBytes    = ($eligibleRows | Where-Object { $_.SizeBytes -ne $null } | Measure-Object -Property SizeBytes -Sum).Sum
  $fleetGB       = if ($fleetBytes -and $fleetBytes -gt 0) { "{0} GB" -f ([Math]::Round($fleetBytes / 1GB, 2)) } else { "N/A" }

  $summary = [ordered]@{
    "Local User Profiles Analyzed"                    = "$analyzed"
    "User Profiles Evaluated"                         = "$evaluated"
    ("User Profiles Not Logged in for {0}+ Days" -f $InactiveDays) = "$eligibleCount"
    "Estimated Data To Remove (if executed)"          = "$fleetGB"
  }

  Show-AsciiTable -Data $summary
}

end { }
