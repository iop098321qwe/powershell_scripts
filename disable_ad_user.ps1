<#
.SYNOPSIS
Disable an Active Directory user account and archive restore details.

.DESCRIPTION
Prompts for an Active Directory username or a partial first/last name search,
writes a restore summary to the Public Documents folder, updates the user's
description, disables the account, optionally hides the user from address
lists, removes non-default group memberships, resets the password to a random
32-character value, sets the password to never expire, and optionally moves the
user to a selected Organizational Unit.

This script is intended to be run on a domain controller from an elevated
PowerShell window by an account with permission to modify users, groups, and
Organizational Unit placement.
#>

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'

$script:AdUserProperties = @(
    'CanonicalName',
    'Description',
    'DisplayName',
    'DistinguishedName',
    'Enabled',
    'GivenName',
    'MemberOf',
    'ObjectGUID',
    'PasswordNeverExpires',
    'PrimaryGroupID',
    'SamAccountName',
    'Surname',
    'userAccountControl',
    'UserPrincipalName'
)

$script:AdGroupProperties = @(
    'DistinguishedName',
    'Name',
    'primaryGroupToken',
    'SamAccountName'
)

$script:AdServer = $null

function Write-Section {
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Output ''
    Write-Output '-------------------------------------------------------------------------------------------'
    Write-Output " $Message"
    Write-Output '-------------------------------------------------------------------------------------------'
}

function Write-Step {
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "> $Message"
}

function Write-DetailLine {
    param (
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value,

        [string]$Fallback = 'Not available'
    )

    $displayValue = Get-DisplayValue -Value $Value -Fallback $Fallback

    Write-Output ('  {0,-22} {1}' -f ('{0}:' -f $Label), $displayValue)
}

function Get-DisplayValue {
    param (
        [AllowEmptyString()]
        [string]$Value,

        [string]$Fallback = 'Not available'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Fallback
    }
    else {
        $Value.Trim()
    }
}

function Format-SummaryDetailLine {
    param (
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value,

        [string]$Fallback = 'Not available'
    )

    $displayValue = Get-DisplayValue -Value $Value -Fallback $Fallback

    return ('  {0,-28} {1}' -f ('{0}:' -f $Label), $displayValue)
}

function Add-SummarySection {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Lines.Count -gt 0) {
        [void]$Lines.Add('')
    }

    [void]$Lines.Add($Message)
    [void]$Lines.Add(('-' * $Message.Length))
}

function Read-YesNoPrompt {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [ValidateSet('Yes', 'No', 'None')]
        [string]$DefaultAnswer = 'None'
    )

    $promptSuffix = switch ($DefaultAnswer) {
        'Yes' { '(Y/n)' }
        'No' { '(y/N)' }
        default { '(y/n)' }
    }

    while ($true) {
        $response = (Read-Host "$Prompt $promptSuffix").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($response)) {
            if ($DefaultAnswer -eq 'Yes') {
                return $true
            }

            if ($DefaultAnswer -eq 'No') {
                return $false
            }
        }

        if ($response -in @('y', 'yes')) {
            return $true
        }

        if ($response -in @('n', 'no')) {
            return $false
        }

        if ($DefaultAnswer -eq 'None') {
            Write-Host "Please enter 'y' or 'n'." -ForegroundColor Yellow
        }
        else {
            Write-Host "Please enter 'y', 'n', or press Enter for $($DefaultAnswer.ToLowerInvariant())." -ForegroundColor Yellow
        }
    }
}

function Read-RequiredValue {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim()

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host 'A value is required.' -ForegroundColor Yellow
    }
}

function Wait-ForExit {
    Write-Host ''
    Write-Host 'Press Esc or Q to exit.'

    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $keyChar = [char]::ToLowerInvariant($keyInfo.KeyChar)

        if ($keyInfo.Key -eq [ConsoleKey]::Escape -or $keyChar -eq [char]'q') {
            return
        }

        Write-Host 'Press Esc or Q to exit.' -ForegroundColor Yellow
    }
}

function Read-RerunOrExitPrompt {
    Write-Host ''
    Write-Host 'Press Enter or R to run again. Press Esc or Q to exit.'

    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $keyChar = [char]::ToLowerInvariant($keyInfo.KeyChar)

        if ($keyInfo.Key -eq [ConsoleKey]::Enter -or $keyChar -eq [char]'r') {
            return $true
        }

        if ($keyInfo.Key -eq [ConsoleKey]::Escape -or $keyChar -eq [char]'q') {
            return $false
        }

        Write-Host 'Press Enter/R to run again, or Esc/Q to exit.' -ForegroundColor Yellow
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedScript {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'This script must be saved to a .ps1 file before it can relaunch elevated.'
    }

    Write-Step 'Requesting an elevated PowerShell window...'

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory (Split-Path -Parent $scriptPath) -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$scriptPath`""
    )
}

function Import-ActiveDirectoryModule {
    Write-Step 'Loading the ActiveDirectory PowerShell module...'
    Import-Module ActiveDirectory -ErrorAction Stop
}

function Resolve-ActiveDirectoryServer {
    Write-Step 'Selecting the PDC emulator domain controller...'

    $domain = Get-ADDomain -ErrorAction Stop
    $serverName = if ([string]::IsNullOrWhiteSpace($domain.PDCEmulator)) {
        $domainController = Get-ADDomainController -Discover -Writable -Service ADWS -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($domainController.HostName)) {
            $domainController.Name
        }
        else {
            $domainController.HostName
        }
    }
    else {
        $domain.PDCEmulator
    }

    if ([string]::IsNullOrWhiteSpace($serverName)) {
        throw 'Could not determine a writable Active Directory domain controller to use.'
    }

    Write-Step "Using Active Directory server '$serverName' for reads and writes."
    return $serverName
}

function ConvertTo-LdapFilterValue {
    param (
        [Parameter(Mandatory)]
        [string]$Value
    )

    $builder = [Text.StringBuilder]::new()

    foreach ($character in $Value.ToCharArray()) {
        switch ([int][char]$character) {
            0 { [void]$builder.Append('\00'); break }
            40 { [void]$builder.Append('\28'); break }
            41 { [void]$builder.Append('\29'); break }
            42 { [void]$builder.Append('\2a'); break }
            92 { [void]$builder.Append('\5c'); break }
            default { [void]$builder.Append($character); break }
        }
    }

    return $builder.ToString()
}

function ConvertTo-LdapGuidFilterValue {
    param (
        [Parameter(Mandatory)]
        [guid]$Guid
    )

    return (($Guid.ToByteArray() | ForEach-Object { '\{0:x2}' -f $_ }) -join '')
}

function Get-ReadableDirectoryLocation {
    param (
        [AllowEmptyString()]
        [string]$CanonicalName,

        [AllowEmptyString()]
        [string]$DistinguishedName,

        [switch]$InputIsContainer
    )

    if (-not [string]::IsNullOrWhiteSpace($DistinguishedName)) {
        $locationDistinguishedName = if ($InputIsContainer) {
            $DistinguishedName
        }
        else {
            Get-ParentDistinguishedName -DistinguishedName $DistinguishedName
        }

        $locationName = Get-RelativeDistinguishedNameValue -DistinguishedName $locationDistinguishedName
        if (-not [string]::IsNullOrWhiteSpace($locationName)) {
            return $locationName
        }
    }

    $canonicalLocationName = Get-CanonicalDirectoryLocationName `
        -CanonicalName $CanonicalName `
        -InputIsContainer:$InputIsContainer
    if (-not [string]::IsNullOrWhiteSpace($canonicalLocationName)) {
        return $canonicalLocationName
    }

    return 'Not available'
}

function Get-CanonicalDirectoryLocationName {
    param (
        [AllowEmptyString()]
        [string]$CanonicalName,

        [switch]$InputIsContainer
    )

    if ([string]::IsNullOrWhiteSpace($CanonicalName)) {
        return ''
    }

    $segments = @(
        $CanonicalName.Trim('/') -split '/' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($segments.Count -eq 0) {
        return ''
    }

    if ($InputIsContainer -or $segments.Count -eq 1) {
        return $segments[$segments.Count - 1]
    }

    return $segments[$segments.Count - 2]
}

function Get-RelativeDistinguishedNameValue {
    param (
        [AllowEmptyString()]
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return ''
    }

    $endIndex = $DistinguishedName.Length
    for ($index = 0; $index -lt $DistinguishedName.Length; $index++) {
        if ($DistinguishedName[$index] -eq [char]'\') {
            $index++
            continue
        }

        if ($DistinguishedName[$index] -eq [char]',') {
            $endIndex = $index
            break
        }
    }

    $relativeDistinguishedName = $DistinguishedName.Substring(0, $endIndex)
    $separatorIndex = $relativeDistinguishedName.IndexOf('=')
    if ($separatorIndex -lt 0) {
        return (ConvertFrom-LdapEscapedName -Value $relativeDistinguishedName)
    }

    $attributeName = $relativeDistinguishedName.Substring(0, $separatorIndex)
    if ($attributeName -eq 'DC') {
        return ''
    }

    return (ConvertFrom-LdapEscapedName -Value $relativeDistinguishedName.Substring($separatorIndex + 1))
}

function ConvertFrom-LdapEscapedName {
    param (
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return ($Value -replace '\\([,\\+"<>;=#])', '$1').Trim()
}

function Resolve-AdUser {
    param (
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        return Get-ADUser -Identity $Identity -Properties $script:AdUserProperties -Server $script:AdServer -ErrorAction Stop
    }
    catch {
        $ldapValue = ConvertTo-LdapFilterValue -Value $Identity
        $users = @(
            Get-ADUser `
                -LDAPFilter "(|(sAMAccountName=$ldapValue)(userPrincipalName=$ldapValue))" `
                -Properties $script:AdUserProperties `
                -Server $script:AdServer `
                -ErrorAction Stop
        )

        if ($users.Count -eq 0) {
            throw "No Active Directory user was found for '$Identity'."
        }

        if ($users.Count -gt 1) {
            throw "More than one Active Directory user matched '$Identity'. Use sAMAccountName instead."
        }

        return $users[0]
    }
}

function Test-AdUserIsEnabled {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    if ($null -ne $User.userAccountControl) {
        return (([int]$User.userAccountControl -band 2) -eq 0)
    }

    return ($User.Enabled -eq $true -or $User.Enabled -eq 'True')
}

function Get-RefreshedAdUser {
    param (
        [Parameter(Mandatory)]
        [object]$User,

        [AllowNull()]
        [object]$ExpectedEnabled = $null,

        [ValidateRange(1, 30)]
        [int]$MaxAttempts = 1,

        [ValidateRange(1, 30)]
        [int]$DelaySeconds = 1
    )

    if ($null -eq $User.ObjectGUID) {
        throw "Could not refresh '$($User.SamAccountName)' because the object GUID was not available."
    }

    $objectGuid = [guid]$User.ObjectGUID
    $ldapGuid = ConvertTo-LdapGuidFilterValue -Guid $objectGuid
    $refreshedUser = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $users = @(
            Get-ADUser `
                -LDAPFilter "(objectGUID=$ldapGuid)" `
                -Properties $script:AdUserProperties `
                -Server $script:AdServer `
                -ErrorAction Stop
        )

        if ($users.Count -ne 1) {
            throw "Could not refresh '$($User.SamAccountName)' by object GUID."
        }

        $refreshedUser = $users[0]

        if ($null -eq $ExpectedEnabled) {
            return $refreshedUser
        }

        if ((Test-AdUserIsEnabled -User $refreshedUser) -eq [bool]$ExpectedEnabled) {
            return $refreshedUser
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $expectedStatus = if ([bool]$ExpectedEnabled) { 'enabled' } else { 'disabled' }
    Write-Warning "AD did not report '$($User.SamAccountName)' as $expectedStatus after refresh attempts."

    return $refreshedUser
}

function Search-AdUsersByName {
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    $ldapValue = ConvertTo-LdapFilterValue -Value $Name

    return @(
        Get-ADUser `
            -LDAPFilter "(|(givenName=*$ldapValue*)(sn=*$ldapValue*))" `
            -Properties $script:AdUserProperties `
            -Server $script:AdServer `
            -ErrorAction Stop |
            Sort-Object -Property DisplayName, SamAccountName, DistinguishedName
    )
}

function Write-AdUserSelectionEntry {
    param (
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [object]$User
    )

    $displayName = if ([string]::IsNullOrWhiteSpace($User.DisplayName)) {
        $User.SamAccountName
    }
    else {
        $User.DisplayName.Trim()
    }

    $userPrincipalName = if ([string]::IsNullOrWhiteSpace($User.UserPrincipalName)) {
        'No sign-in address'
    }
    else {
        $User.UserPrincipalName.Trim()
    }

    $accountStatus = if (Test-AdUserIsEnabled -User $User) { 'Enabled' } else { 'Disabled' }
    $currentLocation = Get-ReadableDirectoryLocation `
        -CanonicalName $User.CanonicalName `
        -DistinguishedName $User.DistinguishedName

    Write-Host ("[{0}] {1}" -f $Number, $displayName)
    Write-DetailLine -Label 'Username' -Value $User.SamAccountName
    Write-DetailLine -Label 'Sign-in address' -Value $userPrincipalName
    Write-DetailLine -Label 'Account status' -Value $accountStatus
    Write-DetailLine -Label 'Current location' -Value $currentLocation
}

function Select-TargetAdUser {
    while ($true) {
        $identity = Read-RequiredValue -Prompt 'Enter the username (sAMAccountName or UPN), or part of a first/last name to search'
        Write-Step "Looking up Active Directory user '$identity'..."

        try {
            return Resolve-AdUser -Identity $identity
        }
        catch {
            if ($_.Exception.Message -notlike "No Active Directory user was found for '*'.") {
                throw
            }
        }

        Write-Step "No exact username or UPN match was found for '$identity'. Searching by partial first or last name..."
        $matchingUsers = @(
            Search-AdUsersByName -Name $identity |
                ForEach-Object { Get-RefreshedAdUser -User $_ }
        )

        if ($matchingUsers.Count -eq 0) {
            Write-Host "No users were found with a first or last name containing '$identity'. Try again." -ForegroundColor Yellow
            continue
        }

        Write-Host ''
        Write-Host ("Matching users for '{0}' ({1} found):" -f $identity, $matchingUsers.Count)
        Write-Host ''

        for ($index = 0; $index -lt $matchingUsers.Count; $index++) {
            $number = $index + 1
            Write-AdUserSelectionEntry -Number $number -User $matchingUsers[$index]
            Write-Host ''
        }

        while ($true) {
            $selection = (Read-Host 'Enter the user number to select, or Q to search again').Trim()

            if ($selection -match '^(q|quit|search)$') {
                Write-Host 'Search selection cleared. Enter another username or name.'
                break
            }

            [int]$selectionNumber = 0
            if (-not [int]::TryParse($selection, [ref]$selectionNumber)) {
                Write-Host 'Enter a valid number from the user list, or Q to search again.' -ForegroundColor Yellow
                continue
            }

            if ($selectionNumber -lt 1 -or $selectionNumber -gt $matchingUsers.Count) {
                Write-Host 'That number is not in the user list.' -ForegroundColor Yellow
                continue
            }

            return $matchingUsers[$selectionNumber - 1]
        }
    }
}

function Confirm-TargetAdUser {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    Write-Section -Message 'Confirm Target User'
    $accountStatus = if (Test-AdUserIsEnabled -User $User) {
        'Enabled (can sign in)'
    }
    else {
        'Disabled (cannot sign in)'
    }

    $currentLocation = Get-ReadableDirectoryLocation `
        -CanonicalName $User.CanonicalName `
        -DistinguishedName $User.DistinguishedName
    $objectGuid = if ($null -eq $User.ObjectGUID) { '' } else { $User.ObjectGUID.ToString() }

    Write-Output 'Please review the selected account before any changes are made:'
    Write-Output ''

    Write-Output 'Identity'
    Write-DetailLine -Label 'First name' -Value $User.GivenName -Fallback 'Not set'
    Write-DetailLine -Label 'Last name' -Value $User.Surname -Fallback 'Not set'
    Write-DetailLine -Label 'Display name' -Value $User.DisplayName -Fallback $User.SamAccountName
    Write-DetailLine -Label 'Username' -Value $User.SamAccountName
    Write-DetailLine -Label 'Sign-in address' -Value $User.UserPrincipalName -Fallback 'Not set'
    Write-Output ''

    Write-Output 'Account'
    Write-DetailLine -Label 'Current status' -Value $accountStatus
    Write-DetailLine -Label 'Description' -Value $User.Description -Fallback 'No description set'
    Write-Output ''

    Write-Output 'Directory'
    Write-DetailLine -Label 'Current location' -Value $currentLocation
    Write-DetailLine -Label 'Object GUID' -Value $objectGuid -Fallback 'Not available'
    Write-Output ''

    return (Read-YesNoPrompt -Prompt 'Is this the correct account to disable' -DefaultAnswer None)
}

function ConvertTo-SafeFileNamePart {
    param (
        [Parameter(Mandatory)]
        [string]$Value
    )

    $safeValue = $Value.Trim() -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_'
    $safeValue = $safeValue.Trim([char[]]'._ ')

    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        throw "'$Value' cannot be used in the group export file name."
    }

    return $safeValue
}

function Get-DisableSummaryExportPath {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    $firstName = $User.GivenName
    if ([string]::IsNullOrWhiteSpace($firstName)) {
        $firstName = Read-RequiredValue -Prompt 'The AD user first name is blank. Enter the first name for the export file'
    }

    $lastName = $User.Surname
    if ([string]::IsNullOrWhiteSpace($lastName)) {
        $lastName = Read-RequiredValue -Prompt 'The AD user last name is blank. Enter the last name for the export file'
    }

    $publicRoot = if ([string]::IsNullOrWhiteSpace($env:PUBLIC)) { 'C:\Users\Public' } else { $env:PUBLIC }
    $publicDocuments = Join-Path -Path $publicRoot -ChildPath 'Documents'

    if (-not (Test-Path -LiteralPath $publicDocuments)) {
        Write-Step "Creating Public Documents folder at '$publicDocuments'..."
        New-Item -Path $publicDocuments -ItemType Directory -Force | Out-Null
    }

    $fileName = '{0}_{1}_summary.txt' -f `
        (ConvertTo-SafeFileNamePart -Value $firstName), `
        (ConvertTo-SafeFileNamePart -Value $lastName)

    return Join-Path -Path $publicDocuments -ChildPath $fileName
}

function Assert-ExportFileDoesNotExist {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (Test-Path -LiteralPath $Path) {
        throw "The $Description file already exists: $Path"
    }
}

function Get-DirectMemberOfGroups {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    $groups = foreach ($groupDn in @($User.MemberOf)) {
        if ([string]::IsNullOrWhiteSpace($groupDn)) {
            continue
        }

        Get-ADGroup -Identity $groupDn -Properties $script:AdGroupProperties -Server $script:AdServer -ErrorAction Stop
    }

    return @($groups | Sort-Object -Property Name)
}

function Get-DomainGroupByRid {
    param (
        [Parameter(Mandatory)]
        [int]$Rid
    )

    $domain = Get-ADDomain -Server $script:AdServer -ErrorAction Stop
    $groupSid = "$($domain.DomainSID.Value)-$Rid"

    return Get-ADGroup -Identity $groupSid -Properties $script:AdGroupProperties -Server $script:AdServer -ErrorAction Stop
}

function Get-OptionalAdUserPropertyState {
    param (
        [Parameter(Mandatory)]
        [object]$User,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    try {
        $propertyUser = Get-ADUser -Identity $User.DistinguishedName -Properties $PropertyName -ErrorAction Stop
        $property = $propertyUser.PSObject.Properties[$PropertyName]

        if ($null -eq $property) {
            return [pscustomobject]@{
                IsAvailable = $false
                Value = $null
            }
        }

        return [pscustomobject]@{
            IsAvailable = $true
            Value = $property.Value
        }
    }
    catch {
        return [pscustomobject]@{
            IsAvailable = $false
            Value = $null
        }
    }
}

function New-DisableAdUserRestoreSnapshot {
    param (
        [Parameter(Mandatory)]
        [object]$User,

        [Parameter(Mandatory)]
        [object]$PrimaryGroup,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$DirectGroups,

        [Parameter(Mandatory)]
        [object]$HideFromAddressListsState
    )

    $currentLocation = Get-ReadableDirectoryLocation `
        -CanonicalName $User.CanonicalName `
        -DistinguishedName $User.DistinguishedName
    $objectGuid = if ($null -eq $User.ObjectGUID) { '' } else { $User.ObjectGUID.ToString() }

    return [pscustomobject]@{
        CanonicalName = $User.CanonicalName
        Description = $User.Description
        DisplayName = $User.DisplayName
        DistinguishedName = $User.DistinguishedName
        Enabled = $User.Enabled
        GivenName = $User.GivenName
        HideFromAddressListsState = $HideFromAddressListsState
        Location = $currentLocation
        ObjectGUID = $objectGuid
        ParentDistinguishedName = Get-ParentDistinguishedName -DistinguishedName $User.DistinguishedName
        PasswordNeverExpires = $User.PasswordNeverExpires
        PrimaryGroup = $PrimaryGroup
        PrimaryGroupID = $User.PrimaryGroupID
        SamAccountName = $User.SamAccountName
        Surname = $User.Surname
        UserPrincipalName = $User.UserPrincipalName
        DirectGroups = @($DirectGroups)
    }
}

function Format-CountSummary {
    param (
        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [string]$Singular,

        [Parameter(Mandatory)]
        [string]$Plural
    )

    if ($Count -eq 1) {
        return "1 $Singular"
    }

    return "$Count $Plural"
}

function Format-BooleanState {
    param (
        [AllowNull()]
        [object]$Value,

        [string]$TrueText = 'Yes',

        [string]$FalseText = 'No',

        [string]$NullText = 'Not set'
    )

    if ($Value -eq $true) {
        return $TrueText
    }

    if ($Value -eq $false) {
        return $FalseText
    }

    return $NullText
}

function Export-DisableAdUserSummary {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-ExportFileDoesNotExist -Path $Path -Description 'summary export'
    $Lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-DisableAdUserSummaryLines {
    param (
        [Parameter(Mandatory)]
        [object]$OriginalUser,

        [Parameter(Mandatory)]
        [object]$User,

        [AllowEmptyString()]
        [string]$MovedToOu,

        [Parameter(Mandatory)]
        [string]$SummaryExportPath,

        [Parameter(Mandatory)]
        [string]$GeneratedAt,

        [AllowEmptyCollection()]
        [string[]]$RemovedGroups = @(),

        [switch]$IncludeSummaryFilePath,

        [switch]$IncludeOriginalPrimaryGroup
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $finalLocation = Get-ReadableDirectoryLocation `
        -CanonicalName $User.CanonicalName `
        -DistinguishedName $User.DistinguishedName
    $removedGroupList = @($RemovedGroups)
    $removedGroupSummary = Format-CountSummary -Count $removedGroupList.Count -Singular 'group' -Plural 'groups'

    [void]$lines.Add('Disable Account Summary')
    [void]$lines.Add('=======================')
    [void]$lines.Add("Finished disabling account '$($User.SamAccountName)'.")
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Summary generated' -Value $GeneratedAt))

    Add-SummarySection -Lines $lines -Message 'Account Details'
    [void]$lines.Add((Format-SummaryDetailLine -Label 'First name' -Value $OriginalUser.GivenName -Fallback 'Not set'))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Last name' -Value $OriginalUser.Surname -Fallback 'Not set'))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Display name' -Value $OriginalUser.DisplayName -Fallback $OriginalUser.SamAccountName))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Username' -Value $OriginalUser.SamAccountName))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Sign-in address' -Value $OriginalUser.UserPrincipalName))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Object GUID' -Value $OriginalUser.ObjectGUID))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Organizational Unit' -Value $finalLocation))

    Add-SummarySection -Lines $lines -Message 'Changes Made'
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Password reset' -Value 'Yes'))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Previous pwd never exp' -Value (Format-BooleanState -Value $OriginalUser.PasswordNeverExpires)))
    [void]$lines.Add((Format-SummaryDetailLine -Label 'Final pwd never exp' -Value 'Yes'))

    if ($MovedToOu) {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Move result' -Value "$($OriginalUser.Location) -> $MovedToOu"))
    }
    else {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Move result' -Value "$($OriginalUser.Location) -> $finalLocation"))
    }

    Add-SummarySection -Lines $lines -Message 'Group Memberships'
    if ($IncludeSummaryFilePath) {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Summary file' -Value $SummaryExportPath))
    }

    if ($IncludeOriginalPrimaryGroup) {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Original primary group' -Value $OriginalUser.PrimaryGroup.Name))
    }

    if ($removedGroupList.Count -gt 0) {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Non-default groups removed' -Value $removedGroupSummary))
    }
    else {
        [void]$lines.Add((Format-SummaryDetailLine -Label 'Non-default groups removed' -Value 'None'))
    }

    [void]$lines.Add('  Removed groups:')

    if ($removedGroupList.Count -gt 0) {
        foreach ($groupName in $removedGroupList) {
            [void]$lines.Add("    - $groupName")
        }
    }
    else {
        [void]$lines.Add('    - None')
    }

    return @($lines)
}

function Get-SecureRandomIndex {
    param (
        [Parameter(Mandatory)]
        [ValidateRange(1, 2147483647)]
        [int]$ExclusiveMaximum,

        [Parameter(Mandatory)]
        [Security.Cryptography.RandomNumberGenerator]$RandomNumberGenerator
    )

    $bytes = [byte[]]::new(4)
    $validMaximum = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$ExclusiveMaximum)

    do {
        $RandomNumberGenerator.GetBytes($bytes)
        $value = [BitConverter]::ToUInt32($bytes, 0)
    }
    while ($value -ge $validMaximum)

    return [int]($value % [uint32]$ExclusiveMaximum)
}

function New-RandomPassword {
    param (
        [ValidateRange(4, 2147483647)]
        [int]$Length = 32
    )

    $lowercaseLetters = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $uppercaseLetters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $digits = '0123456789'.ToCharArray()
    $symbols = '!@#$%^&*()-_=+[]{}:;,.?'.ToCharArray()
    $characterSets = @($lowercaseLetters, $uppercaseLetters, $digits, $symbols)
    $allPasswordCharacters = $lowercaseLetters + $uppercaseLetters + $digits + $symbols
    $passwordCharacters = [System.Collections.Generic.List[char]]::new()
    $randomNumberGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        foreach ($characterSet in $characterSets) {
            $index = Get-SecureRandomIndex `
                -ExclusiveMaximum $characterSet.Count `
                -RandomNumberGenerator $randomNumberGenerator

            [void]$passwordCharacters.Add($characterSet[$index])
        }

        while ($passwordCharacters.Count -lt $Length) {
            $index = Get-SecureRandomIndex `
                -ExclusiveMaximum $allPasswordCharacters.Count `
                -RandomNumberGenerator $randomNumberGenerator

            [void]$passwordCharacters.Add($allPasswordCharacters[$index])
        }

        for ($index = $passwordCharacters.Count - 1; $index -gt 0; $index--) {
            $swapIndex = Get-SecureRandomIndex `
                -ExclusiveMaximum ($index + 1) `
                -RandomNumberGenerator $randomNumberGenerator

            if ($swapIndex -ne $index) {
                $currentCharacter = $passwordCharacters[$index]
                $passwordCharacters[$index] = $passwordCharacters[$swapIndex]
                $passwordCharacters[$swapIndex] = $currentCharacter
            }
        }

        return (-join $passwordCharacters)
    }
    finally {
        if ($null -ne $randomNumberGenerator) {
            $randomNumberGenerator.Dispose()
        }
    }
}

function Get-DomainDistinguishedName {
    param (
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    $domainComponents = @(
        [regex]::Matches($DistinguishedName, '(?i)(?:^|,)(DC=(?:\\.|[^,])+)') |
            ForEach-Object { $_.Groups[1].Value }
    )

    if ($domainComponents.Count -eq 0) {
        throw "Could not determine the user's domain from '$DistinguishedName'."
    }

    return ($domainComponents -join ',')
}

function Get-ParentDistinguishedName {
    param (
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    for ($index = 0; $index -lt $DistinguishedName.Length; $index++) {
        if ($DistinguishedName[$index] -eq [char]'\') {
            $index++
            continue
        }

        if ($DistinguishedName[$index] -eq [char]',') {
            return $DistinguishedName.Substring($index + 1)
        }
    }

    return $null
}

function Add-OrganizationalUnitMenuEntries {
    param (
        [Parameter(Mandatory)]
        [string]$ParentDistinguishedName,

        [Parameter(Mandatory)]
        [hashtable]$ChildrenByParentDistinguishedName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$MenuEntries,

        [string]$Prefix = '',

        [int]$Depth = 0
    )

    if (-not $ChildrenByParentDistinguishedName.ContainsKey($ParentDistinguishedName)) {
        return
    }

    $children = @(
        $ChildrenByParentDistinguishedName[$ParentDistinguishedName] |
            Sort-Object -Property Name, DistinguishedName
    )

    for ($index = 0; $index -lt $children.Count; $index++) {
        $child = $children[$index]
        $isLastChild = $index -eq ($children.Count - 1)

        if ($Depth -eq 0) {
            $displayName = $child.Name
            $childPrefix = ''
        }
        else {
            $connector = if ($isLastChild) { '`-- ' } else { '|-- ' }
            $displayName = "$Prefix$connector$($child.Name)"
            $childPrefix = if ($isLastChild) { "$Prefix    " } else { "$Prefix|   " }
        }

        [void]$MenuEntries.Add([pscustomobject]@{
            DisplayName = $displayName
            OrganizationalUnit = $child
        })

        Add-OrganizationalUnitMenuEntries `
            -ParentDistinguishedName $child.DistinguishedName `
            -ChildrenByParentDistinguishedName $ChildrenByParentDistinguishedName `
            -MenuEntries $MenuEntries `
            -Prefix $childPrefix `
            -Depth ($Depth + 1)
    }
}

function Get-OrganizationalUnitMenuEntries {
    param (
        [Parameter(Mandatory)]
        [object[]]$OrganizationalUnits,

        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName
    )

    $organizationalUnitsByDn = @{}
    foreach ($organizationalUnit in @($OrganizationalUnits)) {
        $organizationalUnitsByDn[$organizationalUnit.DistinguishedName] = $organizationalUnit
    }

    $childrenByParentDistinguishedName = @{}
    foreach ($organizationalUnit in @($OrganizationalUnits)) {
        $parentDistinguishedName = Get-ParentDistinguishedName -DistinguishedName $organizationalUnit.DistinguishedName

        if ([string]::IsNullOrWhiteSpace($parentDistinguishedName) -or
            -not $organizationalUnitsByDn.ContainsKey($parentDistinguishedName)) {
            $parentDistinguishedName = $DomainDistinguishedName
        }

        if (-not $childrenByParentDistinguishedName.ContainsKey($parentDistinguishedName)) {
            $childrenByParentDistinguishedName[$parentDistinguishedName] = [System.Collections.Generic.List[object]]::new()
        }

        [void]$childrenByParentDistinguishedName[$parentDistinguishedName].Add($organizationalUnit)
    }

    $menuEntries = [System.Collections.Generic.List[object]]::new()
    Add-OrganizationalUnitMenuEntries `
        -ParentDistinguishedName $DomainDistinguishedName `
        -ChildrenByParentDistinguishedName $childrenByParentDistinguishedName `
        -MenuEntries $menuEntries

    return @($menuEntries)
}

function Select-TargetOrganizationalUnit {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    $userDomainDn = Get-DomainDistinguishedName -DistinguishedName $User.DistinguishedName
    $organizationalUnits = @(
        Get-ADOrganizationalUnit `
            -Filter * `
            -SearchBase $userDomainDn `
            -SearchScope Subtree `
            -Properties Name, DistinguishedName, CanonicalName `
            -Server $script:AdServer `
            -ErrorAction Stop |
            Sort-Object -Property Name, DistinguishedName
    )

    if ($organizationalUnits.Count -eq 0) {
        throw "No Organizational Units were found under '$userDomainDn'."
    }

    $organizationalUnitMenuEntries = Get-OrganizationalUnitMenuEntries `
        -OrganizationalUnits $organizationalUnits `
        -DomainDistinguishedName $userDomainDn

    Write-Host ('Available Organizational Units under {0}:' -f $userDomainDn)
    for ($index = 0; $index -lt $organizationalUnitMenuEntries.Count; $index++) {
        $number = $index + 1
        Write-Host ("[{0}] {1}" -f $number, $organizationalUnitMenuEntries[$index].DisplayName)
    }

    Write-Host ''

    while ($true) {
        $selection = (Read-Host 'Enter the OU number to move the user into, or Q to skip the move').Trim()

        if ($selection -match '^(q|quit|skip)$') {
            return $null
        }

        [int]$selectionNumber = 0
        if (-not [int]::TryParse($selection, [ref]$selectionNumber)) {
            Write-Host 'Enter a valid number from the OU list, or Q to skip.' -ForegroundColor Yellow
            continue
        }

        if ($selectionNumber -lt 1 -or $selectionNumber -gt $organizationalUnitMenuEntries.Count) {
            Write-Host 'That number is not in the OU list.' -ForegroundColor Yellow
            continue
        }

        $selectedOu = $organizationalUnitMenuEntries[$selectionNumber - 1].OrganizationalUnit
        $selectedOuLocation = Get-ReadableDirectoryLocation `
            -CanonicalName $selectedOu.CanonicalName `
            -DistinguishedName $selectedOu.DistinguishedName `
            -InputIsContainer

        Write-Host ''
        Write-Host "Selected destination: $selectedOuLocation"

        if (Read-YesNoPrompt -Prompt "Move '$($User.SamAccountName)' to this location" -DefaultAnswer None) {
            return $selectedOu
        }

        Write-Host 'Move not confirmed. Choose another location or skip.'
    }
}

function Test-IsAlreadyMemberError {
    param (
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    return $Exception.Message -match 'already.*member'
}

function Test-IsNotMemberError {
    param (
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    return $Exception.Message -match 'not.*member'
}

try {
    if (-not (Test-IsAdministrator)) {
        Write-Section -Message 'Disable Active Directory User'
        Write-Warning 'This script must run in an elevated PowerShell window.'
        Write-Output 'No Active Directory changes will be made from this unelevated session.'

        if (Read-YesNoPrompt -Prompt 'Relaunch this script as Administrator now' -DefaultAnswer Yes) {
            Start-ElevatedScript
            exit 0
        }

        Write-Output 'Elevation was declined. Exiting without making changes.'
        Wait-ForExit
        exit 1
    }

    Write-Step 'Confirmed this PowerShell window is elevated.'
    Import-ActiveDirectoryModule
    $script:AdServer = Resolve-ActiveDirectoryServer

    while ($true) {
        Write-Section -Message 'Disable Active Directory User'

        $user = $null
        while ($true) {
            $user = Select-TargetAdUser
            $user = Get-RefreshedAdUser -User $user

            if (Confirm-TargetAdUser -User $user) {
                break
            }

            Write-Output 'Target user was not confirmed. Search for another user.'
            Write-Output ''
        }

        Write-Section -Message 'Document Current Groups'
        Write-Step 'Reading direct memberOf group memberships...'
        $directGroups = @(Get-DirectMemberOfGroups -User $user)
        $primaryGroup = Get-DomainGroupByRid -Rid $user.PrimaryGroupID
        $defaultGroup = Get-DomainGroupByRid -Rid 513
        $summaryExportPath = Get-DisableSummaryExportPath -User $user
        Assert-ExportFileDoesNotExist -Path $summaryExportPath -Description 'summary export'
        $hideFromAddressListsState = Get-OptionalAdUserPropertyState `
            -User $user `
            -PropertyName 'msExchHideFromAddressLists'
        $originalUser = New-DisableAdUserRestoreSnapshot `
            -User $user `
            -PrimaryGroup $primaryGroup `
            -DirectGroups $directGroups `
            -HideFromAddressListsState $hideFromAddressListsState

        Write-Step "Documented the primary group and $($directGroups.Count) direct memberOf group membership(s) for the summary."

        Write-Section -Message 'Disable Account'
        $disabledDate = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $disabledDescription = "Disabled $disabledDate"

        Write-Step "Setting description to '$disabledDescription'..."
        Set-ADUser -Identity $user.DistinguishedName -Description $disabledDescription -Server $script:AdServer -ErrorAction Stop

        Write-Step 'Disabling the user account...'
        Disable-ADAccount -Identity $user.DistinguishedName -Server $script:AdServer -ErrorAction Stop
        $user = Get-RefreshedAdUser -User $user -ExpectedEnabled $false -MaxAttempts 10 -DelaySeconds 2

        Write-Section -Message 'Address Lists'
        if (Read-YesNoPrompt -Prompt 'Hide this user from address lists' -DefaultAnswer Yes) {
            Write-Step 'Hiding the user from address lists...'
            Set-ADUser -Identity $user.DistinguishedName -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop
        }
        else {
            Write-Step 'Address list visibility left unchanged by operator selection.'
        }

        Write-Section -Message 'Remove Group Memberships'
        $primaryGroupChanged = $false

        if ($primaryGroup.DistinguishedName -ne $defaultGroup.DistinguishedName) {
            Write-Step "Primary group is '$($primaryGroup.Name)'. Changing primary group to '$($defaultGroup.Name)' first..."

            try {
                Add-ADGroupMember -Identity $defaultGroup.DistinguishedName -Members $user.DistinguishedName -Server $script:AdServer -ErrorAction Stop
            }
            catch {
                if (-not (Test-IsAlreadyMemberError -Exception $_.Exception)) {
                    throw
                }
            }

            $defaultPrimaryGroupToken = $defaultGroup.primaryGroupToken
            if (-not $defaultPrimaryGroupToken) {
                $defaultPrimaryGroupToken = 513
            }

            Set-ADUser -Identity $user.DistinguishedName -Replace @{ primaryGroupID = $defaultPrimaryGroupToken } -Server $script:AdServer -ErrorAction Stop
            $primaryGroupChanged = $true
        }
        else {
            Write-Step "Default primary group '$($defaultGroup.Name)' will be preserved."
        }

        $groupRemovalEntries = @(
            $directGroups |
                Where-Object { $_.DistinguishedName -ne $defaultGroup.DistinguishedName } |
                ForEach-Object {
                    [pscustomobject]@{
                        Group = $_
                        IgnoreNotMember = $false
                    }
                }
        )

        if ($primaryGroupChanged) {
            $formerPrimaryQueued = @(
                $groupRemovalEntries |
                    Where-Object { $_.Group.DistinguishedName -eq $primaryGroup.DistinguishedName }
            ).Count -gt 0

            if (-not $formerPrimaryQueued) {
                $groupRemovalEntries += [pscustomobject]@{
                    Group = $primaryGroup
                    IgnoreNotMember = $true
                }
            }
        }

        $removedGroups = [System.Collections.Generic.List[string]]::new()

        if ($groupRemovalEntries.Count -eq 0) {
            Write-Step 'No non-default direct group memberships were found to remove.'
        }
        else {
            foreach ($entry in $groupRemovalEntries) {
                Write-Step "Removing membership from '$($entry.Group.Name)'..."

                try {
                    Remove-ADGroupMember `
                        -Identity $entry.Group.DistinguishedName `
                        -Members $user.DistinguishedName `
                        -Confirm:$false `
                        -Server $script:AdServer `
                        -ErrorAction Stop

                    [void]$removedGroups.Add($entry.Group.Name)
                }
                catch {
                    if ($entry.IgnoreNotMember -and (Test-IsNotMemberError -Exception $_.Exception)) {
                        Write-Step "No direct membership remained in '$($entry.Group.Name)' after the primary group change."
                        continue
                    }

                    throw
                }
            }
        }

        Write-Section -Message 'Password'
        Write-Step 'Generating a random 32-character password...'
        $newPasswordPlainText = New-RandomPassword -Length 32
        $newPassword = ConvertTo-SecureString -String $newPasswordPlainText -AsPlainText -Force

        Write-Step 'Changing the user password...'
        Set-ADAccountPassword -Identity $user.DistinguishedName -Reset -NewPassword $newPassword -ErrorAction Stop
        $newPasswordPlainText = $null

        Write-Step 'Setting password to never expire...'
        Set-ADUser -Identity $user.DistinguishedName -PasswordNeverExpires $true -Server $script:AdServer -ErrorAction Stop

        $newPassword = $null

        Write-Section -Message 'Move User'
        $targetOu = Select-TargetOrganizationalUnit -User $user
        $movedToOu = $null

        if ($null -ne $targetOu) {
            $targetOuLocation = Get-ReadableDirectoryLocation `
                -CanonicalName $targetOu.CanonicalName `
                -DistinguishedName $targetOu.DistinguishedName `
                -InputIsContainer

            Write-Step "Moving user to '$targetOuLocation'..."
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $targetOu.DistinguishedName -Server $script:AdServer -ErrorAction Stop
            $movedToOu = $targetOuLocation
        }
        else {
            Write-Step 'OU move skipped by operator selection.'
        }

        $user = Get-RefreshedAdUser -User $user -ExpectedEnabled $false -MaxAttempts 5 -DelaySeconds 1

        Write-Section -Message 'Summary'
        $summaryGeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $summaryFileLines = Get-DisableAdUserSummaryLines `
            -OriginalUser $originalUser `
            -User $user `
            -MovedToOu $movedToOu `
            -SummaryExportPath $summaryExportPath `
            -GeneratedAt $summaryGeneratedAt `
            -RemovedGroups $removedGroups `
            -IncludeOriginalPrimaryGroup

        Write-Step "Writing disable summary to '$summaryExportPath'..."
        Export-DisableAdUserSummary -Lines $summaryFileLines -Path $summaryExportPath

        $summaryLines = Get-DisableAdUserSummaryLines `
            -OriginalUser $originalUser `
            -User $user `
            -MovedToOu $movedToOu `
            -SummaryExportPath $summaryExportPath `
            -GeneratedAt $summaryGeneratedAt `
            -RemovedGroups $removedGroups `
            -IncludeSummaryFilePath

        $summaryLines | Write-Output

        Write-Output ''
        Write-Host 'Reminder: verify the account status, description, group memberships, password settings, and OU placement manually.' -ForegroundColor Yellow

        if (-not (Read-RerunOrExitPrompt)) {
            break
        }
    }
}
catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Output ''
    Write-Output 'Review any completed steps in Active Directory before rerunning this script.'
    Wait-ForExit
    exit 1
}
