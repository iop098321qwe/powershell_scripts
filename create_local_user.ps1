# Interactive script to create a new user with multiple configuration options


# Variables to hold user input
$username = ""
$password = $null
$description = ""
$groups = New-Object System.Collections.Generic.List[System.String]
$userExpirationDate = ""
$accountDisabled = $false
$passwordExpires = $false
$emailAddress = ""

# Function to display main menu
function Show-Menu {
    Clear-Host
    Write-Output "User Creation Menu:\n"
    Write-Output "1. Set Username"
    Write-Output "2. Set Password"
    Write-Output "3. Set Description"
    Write-Output "4. Set Groups"
    Write-Output "5. Set User Expiration Date"
    Write-Output "6. Disable Account"
    Write-Output "7. Set Password Expiry"
    Write-Output "8. Set Email Address"
    Write-Output "0. Submit (Create User)\n"
    Write-Output "Please enter your choice:"
}

# Function to set username
function Set-Username {
    while ($true) {
        $usernameInput = Read-Host "Enter the username"
        if (-not $usernameInput) {
            Write-Output "Username cannot be empty. Please try again."
        } elseif ($usernameInput.Length -lt 3) {
            Write-Output "Username must be at least 3 characters long. Please try again."
        } else {
            $username = $usernameInput
            break
        }
    }
}

# Function to set password with confirmation and retry limit
function Set-Password {
    $maxRetries = 3
    $retryCount = 0
    while ($retryCount -lt $maxRetries) {
        $password1 = Read-Host "Enter password" -AsSecureString
        $password2 = Read-Host "Re-enter password for confirmation" -AsSecureString
        if ($password1 -eq $password2) {
            if ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)).Length -lt 8) {
                Write-Output "Password must be at least 8 characters long. Please try again."
            } else {
                $password = $password1
                return
            }
        } else {
            Write-Output "Passwords do not match. Please try again."
        }
        $retryCount++
    }
    Write-Output "Maximum retry attempts reached. Returning to main menu."
}

# Function to set description
function Set-Description {
    $description = Read-Host "Enter description for the new user"
}

# Function to set groups
function Set-Groups {
    while ($true) {
        Write-Output "Select Groups:\n"
        Write-Output "1. Enter custom group"
        Write-Output "2. Users"
        Write-Output "3. Administrators"
        Write-Output "Please enter the numbers corresponding to the groups (e.g., 1,3):"
        $groupSelection = Read-Host
        $validSelection = $true
        $groupSelection.Split(",") | ForEach-Object {
            switch ($_.Trim()) {
                "1" { 
                    $customGroup = Read-Host "Enter custom group name"
                    if (Get-LocalGroup -Name $customGroup -ErrorAction SilentlyContinue) {
                        $groups.Add($customGroup)
                    } else {
                        Write-Output "Group '$customGroup' does not exist. Please enter a valid group name."
                        $validSelection = $false
                    }
                }
                "2" { $groups.Add("Users") }
                "3" { $groups.Add("Administrators") }
                default { Write-Output "Invalid selection: $_"; $validSelection = $false }
            }
        }
        if ($validSelection) {
            break
        }
    }
}

# Function to set user expiration date
function Set-ExpirationDate {
    while ($true) {
        $expirationInput = Read-Host "Enter user expiration date (yyyy-mm-dd)"
        if ($expirationInput -match '^(\d{4})-(\d{2})-(\d{2})$') {
            try {
                $date = [datetime]::ParseExact($expirationInput, 'yyyy-MM-dd', $null)
                $userExpirationDate = $date.ToString('yyyy-MM-dd')
                break
            } catch {
                Write-Output "Invalid date format or value. Please enter a valid date in yyyy-mm-dd format."
            }
        } else {
            Write-Output "Invalid date format. Please enter the date in yyyy-mm-dd format."
        }
    }
}

# Function to disable account
function Set-AccountDisabled {
    $response = Read-Host "Do you want to disable the account? (y/n)"
    if ($response -eq "y") {
        $accountDisabled = $true
    } else {
        $accountDisabled = $false
    }
}

# Function to set password expiry
function Set-PasswordExpiry {
    $response = Read-Host "Should the password expire? (y/n)"
    if ($response -eq "y") {
        $passwordExpires = $true
    } else {
        $passwordExpires = $false
    }
}

# Function to set email address
function Set-EmailAddress {
    $emailAddress = Read-Host "Enter email address for the new user"
}

# Function to display current configuration
function Display-Configuration {
    Clear-Host
    Write-Output "Current Configuration:\n"
    Write-Output "Username: $username"
    Write-Output "Password: $(if ($password) { "[Set]" } else { "[Not Set]" })"
    Write-Output "Description: $description"
    Write-Output "Groups: $($groups -join ", ")"
    Write-Output "Expiration Date: $userExpirationDate"
    Write-Output "Account Disabled: $accountDisabled"
    Write-Output "Password Expires: $passwordExpires"
    Write-Output "Email Address: $emailAddress\n"
}

# Function to create the user
function Create-User {
    try {
        if (-not $username) {
            Write-Output "Username is required. User creation failed."
            return
        }
        if (-not $password) {
            Write-Output "Password is required. User creation failed."
            return
        }
        $userParams = @{Name = $username; Password = $password; Description = $description}
        if ($userExpirationDate) {
            $userParams["AccountExpires"] = (Get-Date $userExpirationDate)
        }
        if ($accountDisabled) {
            $userParams["Enabled"] = $false
        }
        New-LocalUser @userParams
        foreach ($group in $groups) {
            if (Get-LocalGroup -Name $group -ErrorAction SilentlyContinue) {
                Add-LocalGroupMember -Group $group -Member $username
            } else {
                Write-Output "Group '$group' does not exist. Skipping group addition."
            }
        }
        Write-Output "User '$username' created successfully."
    } catch {
        Write-Output "An error occurred: $_"
    }
}

# Main script loop
while ($true) {
    Display-Configuration
    Show-Menu
    $choice = Read-Host
    if ($choice -notmatch '^[0-8]$') {
        Write-Output "Invalid choice. Please enter a number between 0 and 8."
        continue
    }
    switch ($choice) {
        "1" { Set-Username }
        "2" { Set-Password }
        "3" { Set-Description }
        "4" { Set-Groups }
        "5" { Set-ExpirationDate }
        "6" { Set-AccountDisabled }
        "7" { Set-PasswordExpiry }
        "8" { Set-EmailAddress }
        "0" {
            Display-Configuration
            $confirmation = Read-Host "Are you sure you want to create the user with the above configuration? (y/n)"
            if ($confirmation -eq "y") {
                Create-User
                break
            }
        }
    }
}
