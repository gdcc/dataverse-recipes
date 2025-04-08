# Shell Script Code Style Guide

This document outlines the coding standards and best practices for shell scripts in the Dataverse repository.

## 1. Script Structure

### 1.1 Header
```bash
#!/bin/bash

# Script Name
# Brief description of what the script does
# Any important notes or dependencies
```

### 1.2 Configuration
- Use `.env` files for configuration when multiple variables are needed
- Create a `sample.env` file with default values and comments
- Load environment variables at the start of the script
- Validate required environment variables before proceeding

Example:
```bash
# Load environment variables from .env file
if [ -f "$(dirname "$0")/.env" ]; then
    log "Loading environment variables from .env file..."
    source "$(dirname "$0")/.env"
else
    log "Error: .env file not found in $(dirname "$0")"
    log "Please copy sample.env to .env and update the values."
    exit 1
fi

# Validate required environment variables
required_vars=("VAR1" "VAR2" "VAR3")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: Required environment variable $var is not set in .env file"
        exit 1
    fi
done
```

## 2. Logging

### 2.1 Logging Configuration
```bash
# Logging configuration
LOGFILE="script_name.log"

# Function to log and print messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to check for errors and exit if found
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1. Exiting."
        exit 1
    fi
}
```

### 2.2 Logging Usage
- Use the `log` function for all output
- Include timestamps with all log messages
- Use descriptive messages that explain what's happening
- Log both successful operations and errors
- Use appropriate log levels (INFO, WARNING, ERROR)

Example:
```bash
log "Starting operation..."
if ! perform_operation; then
    log "ERROR: Operation failed"
    exit 1
fi
log "Operation completed successfully"
```

## 3. Command Dependencies

### 3.1 Required Commands Check
```bash
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "command1" "command2" "command3"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "Error: The following required commands are not installed:"
        printf ' - %s\n' "${missing_commands[@]}" | tee -a "$LOGFILE"
        echo
        log "Please install these commands before running the script."
        log "On Debian/Ubuntu systems, you can install them with:"
        log "sudo apt-get install package1 package2"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install package1 package2"
        exit 1
    fi
}
```

## 4. Function Guidelines

### 4.1 Function Structure
- Each function should have a clear, single purpose
- Include a comment block explaining the function's purpose
- Use descriptive function names that indicate their purpose
- Return appropriate exit codes (0 for success, non-zero for failure)

Example:
```bash
# Function to perform a specific operation
# Handles the operation in a safe and controlled manner
perform_operation() {
    log "Starting operation..."
    
    if ! check_prerequisites; then
        log "ERROR: Prerequisites not met"
        return 1
    fi
    
    if ! execute_operation; then
        log "ERROR: Operation failed"
        return 1
    fi
    
    log "Operation completed successfully"
    return 0
}
```

### 4.2 Error Handling
- Use the `check_error` function after critical operations
- Include descriptive error messages
- Clean up temporary files and resources on failure
- Provide rollback procedures when possible

## 5. Naming Conventions

### 5.1 Variables
- Use uppercase for environment variables and constants
- Use lowercase for local variables
- Use descriptive names that indicate purpose
- Use underscores for word separation

Example:
```bash
# Environment variables
DATAVERSE_USER="dataverse"
SOLR_USER="solr"

# Local variables
local temp_file="/tmp/operation.tmp"
local operation_status="success"
```

### 5.2 Functions
- Use lowercase with underscores
- Start with a verb that describes the action
- Be specific about what the function does

Example:
```bash
check_disk_space()
verify_java_version()
update_service_config()
```

## 6. Security Best Practices

### 6.1 File Permissions
- Check and set appropriate file permissions
- Use `sudo` only when necessary
- Run scripts as non-root user when possible
- Validate file ownership

Example:
```bash
# Security check: Prevent running as root
if [[ $EUID -eq 0 ]]; then
    log "Please do not run this script as root."
    log "This script runs several commands with sudo from within functions."
    exit 1
fi
```

### 6.2 Sensitive Data
- Never hardcode passwords or sensitive information
- Use environment variables or secure configuration files
- Clean up temporary files containing sensitive data
- Use appropriate file permissions for sensitive files

## 7. Testing and Validation

### 7.1 Pre-conditions
- Check system requirements
- Validate environment
- Verify dependencies
- Check disk space and resources

### 7.2 Post-conditions
- Verify operation success
- Check service status
- Validate configurations
- Log completion status

## 8. Documentation

### 8.1 Comments
- Include header comments explaining script purpose
- Document complex operations
- Explain non-obvious code sections
- Keep comments up to date

### 8.2 README Files
- Include usage instructions
- List prerequisites
- Document configuration options
- Provide troubleshooting guidance

## 9. Version Control

### 9.1 File Organization
- Keep related scripts together
- Use consistent file naming
- Include version information in filenames when appropriate
- Maintain clear directory structure

## 10. Maintenance

### 10.1 Code Review
- Follow consistent formatting
- Check for common shell script issues
- Verify error handling
- Ensure proper logging

### 10.2 Updates
- Keep dependencies current
- Update documentation
- Test changes thoroughly
- Maintain backward compatibility