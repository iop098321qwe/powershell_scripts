[CmdletBinding()]
param (
    [ValidateRange(1, [int]::MaxValue)]
    [int]$DaysInactive = 30,

    [string]$SearchBase,

    [string]$OutputPath = (Join-Path (Get-Location) 'inactive_users.csv')
)

$ErrorActionPreference = 'Stop'

<#__
.SYNOPSIS
Audit enabled AD users whose most recent logon is older than N days.

.DESCRIPTION
Queries all domain controllers in the current domain and reads each user's
non-replicated `lastLogon` attribute from each DC. The script then selects the
most recent `lastLogon` value per user (by SID) across all DCs.

Outputs one object per enabled user whose most recent logon is older than the
specified threshold. Enabled users who have never logged on are included only
when their `whenCreated` date is older than the same threshold.

Requires the RSAT ActiveDirectory module and sufficient privileges to query
domain controllers.

.PARAMETER DaysInactive
Users whose most recent logon is older than this many days will be returned.

.PARAMETER SearchBase
Optional LDAP distinguished name to scope the search (e.g. an OU DN).

.PARAMETER OutputPath
Path to write a CSV export. Defaults to `inactive_users.csv` in the current
directory. Objects are always written to the pipeline.

.EXAMPLE
./audit_inactive_ad_users.ps1 -DaysInactive 30 -OutputPath .\inactive_users.csv

.EXAMPLE
./audit_inactive_ad_users.ps1 -SearchBase "OU=Users,DC=example,DC=com" | Sort-Object DaysSinceLastLogon -Descending
#>

Import-Module ActiveDirectory -ErrorAction Stop

$cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)

Write-Verbose "Cutoff (UTC): $cutoffUtc"

$dcs = @(Get-ADDomainController -Filter * | Sort-Object -Property HostName)
if ($dcs.Count -eq 0) {
    throw 'No domain controllers were discovered.'
}

$queriedDcHostnames = New-Object System.Collections.Generic.List[string]
$failedDcHostnames = New-Object System.Collections.Generic.List[string]

# Keyed by SID string.
$usersBySid = @{}

$adUserParams = @{
    Filter      = 'Enabled -eq $true'
    Properties  = @(
        'lastLogon',
        'whenCreated',
        'displayName',
        'mail',
        'userPrincipalName'
    )
    ResultSetSize = $null
}

if ($SearchBase) {
    $adUserParams.SearchBase = $SearchBase
}

foreach ($dc in $dcs) {
    $dcHost = $dc.HostName
    try {
        Write-Verbose "Querying enabled users from DC: $dcHost"
        $queriedDcHostnames.Add($dcHost) | Out-Null

        $dcUsers = Get-ADUser @adUserParams -Server $dcHost

        foreach ($u in $dcUsers) {
            if (-not $u.Enabled) {
                continue
            }

            $sid = $u.SID.Value
            if (-not $sid) {
                continue
            }

            $lastLogonUtc = $null
            if ($null -ne $u.lastLogon -and [int64]$u.lastLogon -gt 0) {
                $lastLogonUtc = [DateTime]::FromFileTimeUtc([int64]$u.lastLogon)
            }

            $existing = $usersBySid[$sid]
            if (-not $existing) {
                $usersBySid[$sid] = [pscustomobject]@{
                    SamAccountName          = $u.SamAccountName
                    Name                    = $u.Name
                    DisplayName             = $u.DisplayName
                    UserPrincipalName       = $u.UserPrincipalName
                    Mail                    = $u.Mail
                    DistinguishedName       = $u.DistinguishedName
                    Enabled                 = $u.Enabled
                    WhenCreatedUtc          = ($u.whenCreated).ToUniversalTime()
                    MostRecentLastLogonUtc  = $lastLogonUtc
                    MostRecentLastLogonDc   = if ($lastLogonUtc) { $dcHost } else { $null }
                }
                continue
            }

            if ($lastLogonUtc -and ((-not $existing.MostRecentLastLogonUtc) -or ($lastLogonUtc -gt $existing.MostRecentLastLogonUtc))) {
                $existing.MostRecentLastLogonUtc = $lastLogonUtc
                $existing.MostRecentLastLogonDc = $dcHost
            }
        }
    }
    catch {
        $failedDcHostnames.Add($dcHost) | Out-Null
        Write-Warning "Failed querying DC '$dcHost': $($_.Exception.Message)"
        continue
    }
}

if ($usersBySid.Count -eq 0) {
    throw 'No enabled users were returned from any domain controller.'
}

Write-Verbose "Domain controllers queried: $($queriedDcHostnames.Count). Failed: $($failedDcHostnames.Count)."

$nowUtc = (Get-Date).ToUniversalTime()

$results = foreach ($entry in $usersBySid.GetEnumerator()) {
    $u = $entry.Value

    $daysSince = $null
    if ($u.MostRecentLastLogonUtc) {
        $daysSince = [math]::Floor(($nowUtc - $u.MostRecentLastLogonUtc).TotalDays)
    }

    $include = $false
    if ($u.MostRecentLastLogonUtc) {
        $include = ($u.MostRecentLastLogonUtc -lt $cutoffUtc)
    }
    else {
        # Never logged on: only include if the account itself is older than the cutoff.
        $include = ($u.WhenCreatedUtc -lt $cutoffUtc)
    }

    if (-not $include) {
        continue
    }

    $hasAuthenticated = [bool]$u.MostRecentLastLogonUtc

    [pscustomobject]@{
        SamAccountName         = $u.SamAccountName
        Name                   = $u.Name
        DisplayName            = $u.DisplayName
        UserPrincipalName      = $u.UserPrincipalName
        Mail                   = $u.Mail
        Enabled                = $u.Enabled
        AccountStatus          = if ($u.Enabled) { 'Enabled' } else { 'Disabled' }
        HasAuthenticated       = $hasAuthenticated
        AuthenticationStatus   = if ($hasAuthenticated) { 'Authenticated' } else { 'NeverAuthenticated' }
        WhenCreatedUtc         = $u.WhenCreatedUtc
        MostRecentLastLogonUtc = $u.MostRecentLastLogonUtc
        MostRecentLastLogonDc  = $u.MostRecentLastLogonDc
        DaysSinceLastLogon     = $daysSince
        DistinguishedName      = $u.DistinguishedName
    }
}

$results = @($results | Sort-Object -Property @{ Expression = 'MostRecentLastLogonUtc'; Descending = $false }, SamAccountName)

if ($OutputPath) {
    $parentDir = Split-Path -Parent $OutputPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        throw "OutputPath directory does not exist: $parentDir"
    }

    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutputPath
    Write-Verbose "Wrote CSV: $OutputPath"
}

$results
