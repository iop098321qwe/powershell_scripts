#!/bin/sh

# Script to prompt for PowerShell Invoke-WebRequest parameters and copy the generated command to clipboard

# Function to display usage
show_usage() {
  cat << 'EOF'
Usage: build_powershell_command.sh [OPTIONS]

OPTIONS:
  -h, --help    Show this help message
EOF
}

# Parse command-line options
while getopts "h-:" opt; do
  case $opt in
    h) show_usage
       echo "DEBUG: Displaying usage information and exiting."
       exit 0
       ;;
    -) case $OPTARG in
         help) show_usage
               echo "DEBUG: Displaying usage information for --help and exiting."
               exit 0
               ;;
         *) echo "Unknown option --$OPTARG"
            echo "DEBUG: Unknown option --$OPTARG encountered."
            show_usage
            exit 1
            ;;
       esac
       ;;
    *) show_usage
       echo "DEBUG: Invalid option encountered. Showing usage information and exiting."
       exit 1
       ;;
  esac
done

# Display command choices
cat << 'EOF'
Please select the PowerShell command to build:
1. Change Local Username
2. Download File from GitHub Repository (Invoke-WebRequest)
EOF

# Prompt the user to select a command
read -p "Enter the number of the command you want to build: " command_choice
echo "DEBUG: Command choice entered: $command_choice"

case $command_choice in
  1)
    # Placeholder for "Change Local Username" command implementation
    echo "DEBUG: Change Local Username command selected."
    echo "This feature is not yet implemented."
    exit 0
    ;;
  2)
    # Prompt the user for the command components
    read -p "Enter GitHub username: " username
    echo "DEBUG: GitHub username entered: $username"
    read -p "Enter repository name: " repository
    echo "DEBUG: Repository name entered: $repository"
    read -p "Enter filename (e.g., path/to/file): " filename
    echo "DEBUG: Filename entered: $filename"
    read -p "Enter desired local file path: " local_file_path
    echo "DEBUG: Local file path entered: $local_file_path"

    # Use default branch (main/master) if not provided
    branch="main"
    echo "DEBUG: Default branch set to: $branch"

    # Build the PowerShell command
    powershell_command="Invoke-WebRequest -Uri https://raw.githubusercontent.com/$username/$repository/$branch/$filename -OutFile '$local_file_path'"
    echo "DEBUG: Constructed PowerShell command: $powershell_command"

    # Print the constructed command
    printf "\nConstructed PowerShell Command:\n%s\n" "$powershell_command"

    # Copy the command to the system clipboard
    # Depending on the Linux environment, different tools can be used for copying to clipboard
    if command -v xclip >/dev/null 2>&1; then
      echo "DEBUG: xclip found. Attempting to copy command to clipboard."
      echo "$powershell_command" | xclip -selection clipboard
      echo "\nThe command has been copied to your clipboard using xclip."
    elif command -v xsel >/dev/null 2>&1; then
      echo "DEBUG: xsel found. Attempting to copy command to clipboard."
      echo "$powershell_command" | xsel --clipboard --input
      echo "\nThe command has been copied to your clipboard using xsel."
    elif command -v wl-copy >/dev/null 2>&1; then
      echo "DEBUG: wl-copy found. Attempting to copy command to clipboard."
      echo "$powershell_command" | wl-copy
      echo "\nThe command has been copied to your clipboard using wl-copy."
    else
      echo "DEBUG: No clipboard utility found (xclip, xsel, wl-copy). Unable to copy to clipboard."
      echo "\nUnable to copy to clipboard: please ensure xclip, xsel, or wl-copy is installed."
    fi
    ;;
  *)
    echo "Invalid choice. Please select a valid command number."
    echo "DEBUG: Invalid command choice entered: $command_choice"
    exit 1
    ;;
esac
