# Requires Active Directory PowerShell Module
# Load the Active Directory module
Import-Module ActiveDirectory

# Function to get user input for changing a name function
Function Get-UserChoice {
    param (
        [string]$Prompt,
        [ValidateSet("FirstName", "LastName", "Both")]
        [string]$Choices
    )
    
    do {
        $UserInput = Read-Host -Prompt $Prompt
    } while ($UserInput -notin $Choices)

    return $UserInput
}

# Get username to update
$UserName = Read-Host "Enter the username (sAMAccountName) of the Active Directory user to update"

# Check if the user exists
try {
    $ADUser = Get-ADUser -Identity $UserName -Properties GivenName, Surname, EmailAddress, SamAccountName
} catch {
    Write-Host "The user $UserName was not found in Active Directory." -ForegroundColor Red
    exit
}

# Display current logon username
Write-Host "Current Logon Username (sAMAccountName): $($ADUser.SamAccountName)" -ForegroundColor Cyan
$UpdateLogonName = Read-Host "Would you like to update the logon username as well? (Y/N)"

if ($UpdateLogonName.ToUpper() -eq 'Y') {
    $NewSamAccountName = Read-Host "Enter the new logon username (sAMAccountName)"
    try {
        Rename-ADObject -Identity $ADUser.DistinguishedName -NewName $NewSamAccountName
        Set-ADUser -Identity $UserName -SamAccountName $NewSamAccountName
        Write-Host "Logon username updated successfully." -ForegroundColor Green
    } catch {
        Write-Host "An error occurred while updating the logon username: $_" -ForegroundColor Red
        exit
    }
} else {
    Write-Host "Logon username not updated." -ForegroundColor Yellow
}

# Prompt the user to choose what to update
$Choice = Get-UserChoice -Prompt "What would you like to change? (FirstName, LastName, Both)" -Choices "FirstName", "LastName", "Both"

# Initialize variables for the new name
$NewFirstName = $ADUser.GivenName
$NewLastName = $ADUser.Surname

# Based on the choice, prompt for new name(s)
switch ($Choice) {
    "FirstName" {
        $NewFirstName = Read-Host "Enter the new first name"
    }
    "LastName" {
        $NewLastName = Read-Host "Enter the new last name"
    }
    "Both" {
        $NewFirstName = Read-Host "Enter the new first name"
        $NewLastName = Read-Host "Enter the new last name"
    }
}

# Confirm the changes with the user
Write-Host "You are about to change the following information:" -ForegroundColor Yellow
Write-Host "First Name: $($ADUser.GivenName) -> $NewFirstName" -ForegroundColor Cyan
Write-Host "Last Name: $($ADUser.Surname) -> $NewLastName" -ForegroundColor Cyan
$Confirm = Read-Host "Do you want to proceed? (Y/N)"

if ($Confirm.ToUpper() -ne 'Y') {
    Write-Host "Operation cancelled." -ForegroundColor Red
    exit
}

# Perform the update
try {
    Set-ADUser -Identity $UserName -GivenName $NewFirstName -Surname $NewLastName
    Write-Host "User details updated successfully." -ForegroundColor Green
} catch {
    Write-Host "An error occurred while updating the user: $_" -ForegroundColor Red
    exit
}

# Prompt for changing the email
$UpdateEmail = Read-Host "Would you like to update the user's email address as well? (Y/N)"

if ($UpdateEmail.ToUpper() -eq 'Y') {
    $NewEmail = Read-Host "Enter the new email address"
    try {
        Set-ADUser -Identity $UserName -EmailAddress $NewEmail
        Write-Host "Email address updated successfully." -ForegroundColor Green
    } catch {
        Write-Host "An error occurred while updating the email address: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Email address not updated." -ForegroundColor Yellow
}

