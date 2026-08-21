<#
.SYNOPSIS
Disable an Active Directory user account and archive group memberships.

.DESCRIPTION
Prompts for an Active Directory username, writes the user's primary group and
direct memberOf group names to the Public Documents folder, updates the user's
description, disables the account, removes non-default group memberships,
resets the password, sets the password to never expire, and optionally moves
the user to a selected Organizational Unit.

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
    'PrimaryGroupID',
    'SamAccountName',
    'Surname',
    'UserPrincipalName'
)

$script:AdGroupProperties = @(
    'DistinguishedName',
    'GroupCategory',
    'GroupScope',
    'Name',
    'primaryGroupToken',
    'SamAccountName'
)

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

function Resolve-AdUser {
    param (
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        return Get-ADUser -Identity $Identity -Properties $script:AdUserProperties -ErrorAction Stop
    }
    catch {
        $ldapValue = ConvertTo-LdapFilterValue -Value $Identity
        $users = @(
            Get-ADUser `
                -LDAPFilter "(|(sAMAccountName=$ldapValue)(userPrincipalName=$ldapValue))" `
                -Properties $script:AdUserProperties `
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

function Get-GroupMembershipExportPath {
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

    $fileName = '{0}_{1}_groups.txt' -f `
        (ConvertTo-SafeFileNamePart -Value $firstName), `
        (ConvertTo-SafeFileNamePart -Value $lastName)

    return Join-Path -Path $publicDocuments -ChildPath $fileName
}

function Get-DirectMemberOfGroups {
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    $groups = foreach ($groupDn in @($User.MemberOf)) {
        Get-ADGroup -Identity $groupDn -Properties $script:AdGroupProperties -ErrorAction Stop
    }

    return @($groups | Sort-Object -Property Name)
}

function Get-DomainGroupByRid {
    param (
        [Parameter(Mandatory)]
        [int]$Rid
    )

    $domain = Get-ADDomain -ErrorAction Stop
    $groupSid = "$($domain.DomainSID.Value)-$Rid"

    return Get-ADGroup -Identity $groupSid -Properties $script:AdGroupProperties -ErrorAction Stop
}

function Export-GroupMemberships {
    param (
        [Parameter(Mandatory)]
        [object[]]$DirectGroups,

        [Parameter(Mandatory)]
        [object]$PrimaryGroup,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        throw "The group export file already exists: $Path"
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    [void]$groups.Add($PrimaryGroup)

    foreach ($group in @($DirectGroups)) {
        if ($group.DistinguishedName -ne $PrimaryGroup.DistinguishedName) {
            [void]$groups.Add($group)
        }
    }

    $groupNames = @(
        $groups |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
            ForEach-Object { $_.Name }
    )

    if ($groupNames.Count -eq 0) {
        throw "No group names were available to write: $Path"
    }

    $groupNames | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertFrom-SecureStringToPlainText {
    param (
        [Parameter(Mandatory)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-NewPassword {
    while ($true) {
        $password = Read-Host 'Enter the new password for the disabled user' -AsSecureString
        $confirmation = Read-Host 'Confirm the new password' -AsSecureString

        if ($password.Length -eq 0) {
            Write-Host 'Password cannot be blank.' -ForegroundColor Yellow
            continue
        }

        $passwordText = ConvertFrom-SecureStringToPlainText -SecureString $password
        $confirmationText = ConvertFrom-SecureStringToPlainText -SecureString $confirmation
        $passwordsMatch = $passwordText -ceq $confirmationText
        $passwordText = $null
        $confirmationText = $null

        if ($passwordsMatch) {
            return $password
        }

        Write-Host 'Passwords did not match. Try again.' -ForegroundColor Yellow
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
            -Properties Name, DistinguishedName `
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
        Write-Host ''
        Write-Host "Selected OU: $($selectedOu.DistinguishedName)"

        if (Read-YesNoPrompt -Prompt "Move '$($User.SamAccountName)' to this OU" -DefaultAnswer No) {
            return $selectedOu
        }

        Write-Host 'Move not confirmed. Choose again.'
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
    Write-Section -Message 'Disable Active Directory User'

    if (-not (Test-IsAdministrator)) {
        Write-Warning 'This script must run in an elevated PowerShell window.'
        Write-Output 'No Active Directory changes will be made from this unelevated session.'

        if (Read-YesNoPrompt -Prompt 'Relaunch this script as Administrator now' -DefaultAnswer Yes) {
            Start-ElevatedScript
            exit 0
        }

        Write-Output 'Elevation was declined. Exiting without making changes.'
        exit 1
    }

    Write-Step 'Confirmed this PowerShell window is elevated.'
    Import-ActiveDirectoryModule

    $username = Read-RequiredValue -Prompt 'Enter the username (sAMAccountName or UPN) to disable'
    Write-Step "Looking up Active Directory user '$username'..."
    $user = Resolve-AdUser -Identity $username

    Write-Section -Message 'Confirm Target User'
    Write-Output "DisplayName: $($user.DisplayName)"
    Write-Output "SamAccountName: $($user.SamAccountName)"
    Write-Output "UserPrincipalName: $($user.UserPrincipalName)"
    Write-Output "Enabled: $($user.Enabled)"
    Write-Output "DistinguishedName: $($user.DistinguishedName)"

    if (-not (Read-YesNoPrompt -Prompt 'Continue disabling this user' -DefaultAnswer No)) {
        Write-Output 'Target user was not confirmed. Exiting without making changes.'
        exit 0
    }

    Write-Section -Message 'Document Current Groups'
    Write-Step 'Reading direct memberOf group memberships...'
    $directGroups = @(Get-DirectMemberOfGroups -User $user)
    $primaryGroup = Get-DomainGroupByRid -Rid $user.PrimaryGroupID
    $defaultGroup = Get-DomainGroupByRid -Rid 513
    $groupExportPath = Get-GroupMembershipExportPath -User $user

    Write-Step "Writing group names to '$groupExportPath'..."
    Export-GroupMemberships -DirectGroups $directGroups -PrimaryGroup $primaryGroup -Path $groupExportPath
    Write-Step "Documented the primary group and $($directGroups.Count) direct memberOf group membership(s)."

    Write-Section -Message 'Disable Account'
    $disabledDate = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $disabledDescription = "Disabled $disabledDate"

    Write-Step "Setting description to '$disabledDescription'..."
    Set-ADUser -Identity $user.DistinguishedName -Description $disabledDescription -ErrorAction Stop

    Write-Step 'Disabling the user account...'
    Disable-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop

    Write-Section -Message 'Remove Group Memberships'
    $primaryGroupChanged = $false

    if ($primaryGroup.DistinguishedName -ne $defaultGroup.DistinguishedName) {
        Write-Step "Primary group is '$($primaryGroup.Name)'. Changing primary group to '$($defaultGroup.Name)' first..."

        try {
            Add-ADGroupMember -Identity $defaultGroup.DistinguishedName -Members $user.DistinguishedName -ErrorAction Stop
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

        Set-ADUser -Identity $user.DistinguishedName -Replace @{ primaryGroupID = $defaultPrimaryGroupToken } -ErrorAction Stop
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
    $newPassword = Read-NewPassword

    Write-Step 'Changing the user password...'
    Set-ADAccountPassword -Identity $user.DistinguishedName -Reset -NewPassword $newPassword -ErrorAction Stop

    Write-Step 'Setting password to never expire...'
    Set-ADUser -Identity $user.DistinguishedName -PasswordNeverExpires $true -ErrorAction Stop

    $newPassword = $null

    Write-Section -Message 'Move User'
    $targetOu = Select-TargetOrganizationalUnit -User $user
    $movedToOu = $null

    if ($null -ne $targetOu) {
        Write-Step "Moving user to '$($targetOu.DistinguishedName)'..."
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $targetOu.DistinguishedName -ErrorAction Stop
        $movedToOu = $targetOu.DistinguishedName
        $user = Get-ADUser -Identity $user.ObjectGUID -Properties $script:AdUserProperties -ErrorAction Stop
    }
    else {
        Write-Step 'OU move skipped by operator selection.'
    }

    Write-Section -Message 'Summary'
    Write-Output "User: $($user.SamAccountName)"
    Write-Output "Description set to: $disabledDescription"
    Write-Output 'Account disabled: Yes'
    Write-Output "Group export file: $groupExportPath"
    Write-Output "Non-default groups removed: $($removedGroups.Count)"

    if ($removedGroups.Count -gt 0) {
        foreach ($groupName in $removedGroups) {
            Write-Output "- $groupName"
        }
    }

    Write-Output 'Password changed: Yes'
    Write-Output 'Password never expires: Yes'

    if ($movedToOu) {
        Write-Output "Moved to OU: $movedToOu"
    }
    else {
        Write-Output 'Moved to OU: No move performed'
    }

    Write-Output ''
    Write-Host 'Reminder: verify the account status, description, group memberships, password settings, and OU placement manually.' -ForegroundColor Yellow
}
catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Output ''
    Write-Output 'Review any completed steps in Active Directory before rerunning this script.'
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}
