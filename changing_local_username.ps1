<#
    .CreationDate
      2024-10-07

    .LastModified
      2024-10-07

    .Version
      1.0

    .Synopsis
    This script renames a local user account on a Windows system.

    .Description
    Renames an existing local user account to a new specified name. The script prompts for the current and new usernames, validates the inputs, and provides confirmation before executing the rename operation. Additionally, it ensures the current username exists and that the new username is not already in use.

    .Parameters
      .current_username
      The current username of the local user account to be renamed.

      .new_username
      The new username that will replace the current username.

    .Inputs
      - Current Username: A string representing the existing username to be renamed.
      - New Username: A string representing the new username.

    .Outputs
      - Confirmation message indicating whether the renaming process was successful or if any errors occurred.

    .Example
      .\Rename-LocalUser.ps1
      Prompts the user for the current and new usernames and proceeds to rename the user.

    .Notes
      - Requires PowerShell 5.1 or later.
      - Must be run with administrative privileges to rename local user accounts.
      - Provides a retry mechanism for incorrect inputs.
      - Logs errors with specific handling for better troubleshooting.

    .Component
      Local User Management

    .Role
      User Account Management

    .Compatibility
      Windows 10, Windows Server 2016 or later.

    .Limitations
      - This script cannot rename user accounts that are currently in use.
      - Only local accounts can be renamed; domain accounts are not supported.

    .Author
      Dallas Elliott
      Contact: dallas.elliott@deeptree.tech
#>

# Function to prompt user and confirm rename action
function Rename-User {
    param (
        [string]$current_username,  # Parameter to hold the current username
        [string]$new_username       # Parameter to hold the new username
    )
    
    # Display the entered usernames for confirmation
    Write-Host "Current Username: $current_username" -ForegroundColor DarkYellow
    Write-Host "New Username: $new_username" -ForegroundColor Green

    # Confirm before proceeding with renaming
    $maxRetries = 3  # Set a maximum retry limit
    $retryCount = 0
    while ($retryCount -lt $maxRetries) {
        $confirmation = Read-Host -Prompt "Are you sure you want to rename the user from '$current_username' to '$new_username'? (y/n)"
        
        # Use an if-else statement to evaluate the user's confirmation input
        if ($confirmation.ToLower() -eq "y") {
            # Check if the current username exists
            if (-not (Get-LocalUser -Name $current_username -ErrorAction SilentlyContinue)) {
                Write-Host "Error: The current username '$current_username' does not exist." -ForegroundColor Red
                return
            }
            
            # Check if the new username meets system requirements (e.g., length, allowed characters)
            if ($new_username.Length -lt 3 -or $new_username.Length -gt 20 -or $new_username -notmatch '^[a-zA-Z0-9]+$') {
                Write-Host "Error: The new username must be between 3 and 20 characters and contain only alphanumeric characters." -ForegroundColor Red
                return
            }
            
            try {
                # Rename the user if confirmed
                Rename-LocalUser -Name $current_username -NewName $new_username
                Write-Host "User renamed successfully from '$current_username' to '$new_username'." -ForegroundColor Green
            }
            catch {
                # Display an error message if the rename operation fails with specific handling
                if ($_.Exception.Message -like '*Access is denied*') {
                    Write-Host "Error: Access is denied. Please run the script with administrative privileges." -ForegroundColor Red
                } else {
                    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            break
        } elseif ($confirmation.ToLower() -eq "n") {
            # User chose not to proceed with renaming, prompt for new usernames
            Write-Host "Operation cancelled by the user." -ForegroundColor Yellow
            $current_username = Read-Host -Prompt "Enter the current username:"  # Prompt for the current username again
            $new_username = Read-Host -Prompt "Enter the new username:"          # Prompt for the new username again
            $retryCount++
        } else {
            # Handle invalid input from the user and prompt again
            Write-Host "Invalid input. Please enter 'y' for yes or 'n' for no." -ForegroundColor Red
            $retryCount++
        }
    }
    
    if ($retryCount -ge $maxRetries) {
        Write-Host "Maximum retry limit reached. Operation cancelled." -ForegroundColor Red
    }
}

# Main script block to gather input and initiate the renaming process
$current_username = Read-Host -Prompt "Enter the current username:"  # Prompt for the current username
$new_username = Read-Host -Prompt "Enter the new username:"          # Prompt for the new username

# Validate input to ensure neither username is null or whitespace and check if the new username already exists
if ([string]::IsNullOrWhiteSpace($current_username)) {
    # Display an error message if the current username is missing
    Write-Host "Error: The current username must be provided." -ForegroundColor Red
} elseif ([string]::IsNullOrWhiteSpace($new_username)) {
    # Display an error message if the new username is missing
    Write-Host "Error: The new username must be provided." -ForegroundColor Red
} elseif (Get-LocalUser -Name $new_username -ErrorAction SilentlyContinue) {
    # Display an error message if the new username already exists
    Write-Host "Error: The new username '$new_username' already exists. Please choose a different username." -ForegroundColor Red
} else {
    # Call the Rename-User function with the provided usernames
    Rename-User -current_username $current_username -new_username $new_username
}
