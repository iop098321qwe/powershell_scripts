[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Apply,
    [int]$InactiveDays = 90,
    [string]$ListFile = 'PotentialPurgeAccounts.md',
    [switch]$Force
)

Set-StrictMode -Version Latest

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-DryRun {
    param([string]$Message)
    Write-Host "[DRY-RUN] $Message"
}

function Write-Notice {
    param([string]$Message)
    Write-Host "[NOTICE] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Resolve-ListFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "List file path cannot be empty."
    }

    $resolved = $null
    if (Test-Path -LiteralPath $Path) {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } else {
        $scriptRoot = if ($PSCommandPath) {
            Split-Path -Parent $PSCommandPath
        } elseif ($MyInvocation.MyCommand.Path) {
            Split-Path -Parent $MyInvocation.MyCommand.Path
        } else {
            Get-Location
        }

        if ($scriptRoot) {
            $candidate = Join-Path -Path $scriptRoot -ChildPath $Path
            if (Test-Path -LiteralPath $candidate) {
                $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
            }
        }
    }

    if (-not $resolved) {
        throw "Unable to locate list file '$Path'."
    }

    return $resolved
}

function Get-AccountsFromFile {
    param([string]$Path)

    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "Failed to read list file '$Path': $($_.Exception.Message)"
    }

    $accounts = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        $clean = ($line -replace '\r', '').Trim()
        if (-not $clean) { continue }
        if ($clean.StartsWith('#')) { continue }
        $clean = $clean -replace '^\s*[\-\*\+]\s*', ''
        $clean = $clean -replace '^\s*\d+\.\s*', ''

        if ($clean.StartsWith('|') -and $clean.EndsWith('|')) {
            $cells = $clean.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($cells.Count -gt 0) { $clean = $cells[0] }
        }

        if ($clean -match '`([^`]+)`') {
            $clean = $matches[1].Trim()
        }

        $clean = ($clean -split '\s+#')[0].Trim()
        $clean = ($clean -split '\s+//')[0].Trim()

        if ($clean -like '* - *') {
            $clean = $clean.Split(' - ')[0].Trim()
        }

        if ($clean -like '*: *') {
            $clean = $clean.Split(':')[0].Trim()
        }

        if ([string]::IsNullOrWhiteSpace($clean)) { continue }

        $accounts.Add($clean)
    }

    return $accounts | Select-Object -Unique
}

function Convert-LastUseTime {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Utc) { return [datetime]$Value }
        return ([datetime]$Value).ToUniversalTime()
    }

    if ($Value -is [string]) {
        $trim = $Value.Trim()
        if (-not $trim) { return $null }

        if ($trim -match '^\d+$') {
            try { return [datetime]::FromFileTimeUtc([int64]$trim) } catch { return $null }
        }

        if ($trim -match '^\d{14}\.\d{6}[-+]\d{3}$') {
            try {
                $converted = [System.Management.ManagementDateTimeConverter]::ToDateTime($trim)
                return $converted.ToUniversalTime()
            } catch {
                return $null
            }
        }

        $candidate = $null
        if ([datetime]::TryParse($trim, [ref]$candidate)) {
            return $candidate.ToUniversalTime()
        }

        return $null
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint64]) {
        try { return [datetime]::FromFileTimeUtc([int64]$Value) } catch { return $null }
    }

    return $null
}

function Resolve-AccountNameFromSid {
    param([string]$Sid)

    if ([string]::IsNullOrWhiteSpace($Sid)) {
        return $null
    }

    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return $null
    }
}

function Get-LocalProfiles {
    $useCim = $null -ne (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)

    try {
        if ($useCim) {
            $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop
        } else {
            $profiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction Stop
        }
    } catch {
        throw "Failed to enumerate local user profiles: $($_.Exception.Message)"
    }

    foreach ($profile in $profiles) {
        if ($profile.Special) { continue }
        if ($profile.Loaded) { continue }
        if (-not $profile.LocalPath) { continue }
        if ($profile.LocalPath -notlike 'C:\\Users\\*') { continue }

        $lastUseUtc = Convert-LastUseTime -Value $profile.LastUseTime
        $account = Resolve-AccountNameFromSid -Sid $profile.SID
        if (-not $account) { $account = $profile.SID }

        $ageDays = if ($lastUseUtc) { ([datetime]::UtcNow - $lastUseUtc).TotalDays } else { $null }

        [pscustomobject]@{
            AccountName       = $account
            SID               = $profile.SID
            LocalPath         = $profile.LocalPath
            LastUseTimeUtc    = $lastUseUtc
            AgeInDays         = if ($ageDays -ne $null) { [math]::Round($ageDays, 2) } else { $null }
            SourceObject      = $profile
            UsesCim           = $useCim
        }
    }
}

function Should-RemoveProfile {
    param(
        $Profile,
        [datetime]$Cutoff,
        [string[]]$AccountFilter
    )

    $withinFilter = $true
    if ($AccountFilter -and $AccountFilter.Count -gt 0) {
        $withinFilter = $AccountFilter -contains $Profile.AccountName -or $AccountFilter -contains $Profile.SID
    }

    if (-not $withinFilter) {
        return $false
    }

    if ($null -eq $Profile.LastUseTimeUtc) {
        return $true
    }

    return ($Profile.LastUseTimeUtc -le $Cutoff)
}

function Remove-ProfileData {
    param($Profile)

    try {
        if ($Profile.UsesCim -and $Profile.SourceObject -is [Microsoft.Management.Infrastructure.CimInstance]) {
            $result = Invoke-CimMethod -InputObject $Profile.SourceObject -MethodName Delete -ErrorAction Stop
            if ($null -eq $result -or $result.ReturnValue -eq 0) {
                return $true
            }
            Write-Warn "Win32_UserProfile.Delete returned code $($result.ReturnValue) for $($Profile.LocalPath)"
            return $false
        }

        if ($Profile.SourceObject -is [System.Management.ManagementObject]) {
            $null = $Profile.SourceObject.Delete()
            return $true
        }

        throw "Unsupported profile object type for $($Profile.AccountName)."
    } catch {
        Write-Warn "Failed to delete profile for $($Profile.AccountName): $($_.Exception.Message)"
        return $false
    }
}

function Assert-Workstation {
    try {
        $useCim = $null -ne (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)
        if ($useCim) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        } else {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        }

        if ($os.ProductType -ne 1) {
            Write-Warn "This host reports ProductType $($os.ProductType); the script is intended for workstations."
        }
    } catch {
        Write-Warn "Unable to confirm workstation product type: $($_.Exception.Message)"
    }
}

try {
    if ($InactiveDays -lt 0) {
        throw "InactiveDays must be zero or greater."
    }

    Assert-Workstation

    $listPath = Resolve-ListFilePath -Path $ListFile
    $accounts = @(Get-AccountsFromFile -Path $listPath)
    if (-not $accounts -or $accounts.Count -eq 0) {
        Write-Notice "List file '$listPath' did not provide any account filters. All inactive profiles will be considered."
    } else {
        Write-Info "Loaded $($accounts.Count) account(s) from '$listPath'."
    }

    $cutoff = [datetime]::UtcNow.AddDays(-1 * [double]$InactiveDays)
    Write-Info "Profiles last used on or before $($cutoff.ToString('u')) will be considered inactive."

    $profiles = @(Get-LocalProfiles)
    if ($profiles.Count -eq 0) {
        Write-Notice "No removable user profiles were found on this system."
        return
    }

    $candidates = @()
    foreach ($profile in $profiles) {
        if (Should-RemoveProfile -Profile $profile -Cutoff $cutoff -AccountFilter $accounts) {
            $candidates += $profile
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Notice "No profiles matched the inactivity threshold and filter criteria."
        return
    }

    $mode = if ($Apply.IsPresent) { 'APPLY' } else { 'DRY-RUN' }
    Write-Info "Operating mode: $mode"

    foreach ($candidate in $candidates | Sort-Object -Property @{Expression = 'AgeInDays'; Descending = $true}, 'AccountName') {
        $lastUse = if ($candidate.LastUseTimeUtc) { $candidate.LastUseTimeUtc.ToLocalTime().ToString('g') } else { 'Unknown' }
        $age = if ($candidate.AgeInDays -ne $null) { "~$($candidate.AgeInDays) day(s)" } else { 'Unknown age' }
        $message = "Profile '$($candidate.AccountName)' at '$($candidate.LocalPath)' last used $lastUse ($age)."

        if ($Apply.IsPresent) {
            if ($PSCmdlet.ShouldProcess($candidate.LocalPath, "Remove profile for $($candidate.AccountName)")) {
                if (Remove-ProfileData -Profile $candidate) {
                    Write-Info "Removed $message"
                } else {
                    Write-Warn "Removal failed for profile '$($candidate.AccountName)'."
                }
            }
        } else {
            Write-DryRun "Would remove $message"
        }
    }

    Write-Info "Profiles evaluated: $($profiles.Count). Candidates: $($candidates.Count)."

} catch {
    Write-Error "Profile pruning failed: $($_.Exception.Message)"
    if (-not $Force.IsPresent) {
        throw
    }
}
