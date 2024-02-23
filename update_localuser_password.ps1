# PowerShell Script to Change Password of a Local Account

function ConvertTo-PlainText {
    param (
        [System.Security.SecureString]$secureString
    )

    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($secureString)
        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr)
    }
}

# Prompt for the username
$username = Read-Host -Prompt 'Enter the username for which you want to set a password'

# Validate if the user account exists
if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
    Write-Host "User account does not exist. Please try again with a valid username." -ForegroundColor Red
    exit
}

# Prompt for the password
$password = Read-Host -Prompt 'Enter the new password' -AsSecureString

# Convert the password to plain text (necessary for net user command)
$plainPassword = ConvertTo-PlainText -secureString $password

# Confirm password
$confirmPassword = Read-Host -Prompt 'Confirm the new password' -AsSecureString

# Convert the confirm password to plain text
$plainConfirmPassword = ConvertTo-PlainText -secureString $confirmPassword

# Check if passwords match
if ($plainPassword -eq $plainConfirmPassword) {
    # Execute the command to change the password
    try {
        net user $username $plainPassword
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Password changed successfully for user $username." -ForegroundColor Green
        }
        else {
            Write-Host "Failed to change password. Please ensure your password meets the system's policy requirements." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "An error occurred: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Passwords do not match. Please try again." -ForegroundColor Red
}

# Prompt the user to press any key to dismiss the message
Write-Host "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
