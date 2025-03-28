#!/bin/bash

# Dataverse Java Upgrade Script
# This script automates the process of upgrading Java for Dataverse installations
# It handles the installation of the target Java version, configuration updates,
# and service management to ensure a smooth upgrade process

# Configurable variables
# Default Java version if not specified - Dataverse 6.0 requires Java 11 or higher
TARGET_JAVA_VERSION="${2:-11}"

# Help function
# Displays usage information and available options for the script
show_help() {
    echo "Usage: $0 [options] <java_version>"
    echo "Options:"
    echo "  --help    Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 11     # Upgrade to Java 11"
    echo "  $0 17     # Upgrade to Java 17"
    exit 0
}

# Check for help flag
if [[ "$1" == "--help" ]]; then
    show_help
fi

# Logging configuration
# Creates a log file to track the upgrade process and any potential issues
LOGFILE="java_upgrade.log"

# Function to log and print messages
# Ensures all operations are logged with timestamps for troubleshooting
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to check for errors and exit if found
# Provides consistent error handling throughout the script
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1. Exiting."
        exit 1
    fi
}

# Function to check for required commands
# Verifies that all necessary system commands are available before proceeding
check_required_commands() {
    local missing_commands=()
    local required_commands=(
        "java" "alternatives" "systemctl" "sudo" "grep" "sed" "tee" "readlink"
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
        log "sudo apt-get install default-jdk alternatives systemd sudo grep sed coreutils"
        log "On RHEL/CentOS systems, you can install them with:"
        log "sudo yum install java-11-openjdk alternatives systemd sudo grep sed coreutils"
        exit 1
    fi
}

# Check for required commands before proceeding
check_required_commands

# Function to check Java version for the dataverse user
# Extracts the current Java version from the dataverse user's environment
check_java_version() {
    local version=$(sudo -u dataverse java -version 2>&1 | grep -oP '(?<=version ")([0-9]+)')
    echo "$version"
}

# Function to check if JAVA_HOME is set correctly for the dataverse user
# Verifies and updates JAVA_HOME if necessary to point to the correct Java installation
verify_java_home() {
    JAVA_HOME_PATH="/usr/lib/jvm/java-${TARGET_JAVA_VERSION}-openjdk"
    JAVA_HOME_CURRENT=$(sudo -u dataverse bash -c 'echo $JAVA_HOME')

    if [[ "$JAVA_HOME_CURRENT" != *"${JAVA_HOME_PATH}"* ]]; then
        log "WARNING: JAVA_HOME is not set correctly for the dataverse user. It's currently: $JAVA_HOME_CURRENT"
        log "Attempting to set JAVA_HOME to Java ${TARGET_JAVA_VERSION}."
        sudo -u dataverse bash -c "export JAVA_HOME='$JAVA_HOME_PATH'; export PATH=\$JAVA_HOME/bin:\$PATH"
        check_error "Failed to set JAVA_HOME for the dataverse user"
        log "JAVA_HOME set to: $JAVA_HOME_PATH"
    else
        log "JAVA_HOME is set correctly for the dataverse user: $JAVA_HOME_CURRENT"
    fi
}

# Function to install the target Java version if it's not already installed
# Handles the installation of the specified Java version using the system package manager
install_java() {
    installed_java_version=$(check_java_version)
    if [ "$installed_java_version" = "$TARGET_JAVA_VERSION" ]; then
        log "Java ${TARGET_JAVA_VERSION} is already installed. Skipping installation."
    else
        log "Java ${TARGET_JAVA_VERSION} is not installed. Proceeding with installation."
        sudo yum install -y java-${TARGET_JAVA_VERSION}-openjdk java-${TARGET_JAVA_VERSION}-openjdk-devel 2>&1 | tee -a "$LOGFILE"
        check_error "Failed to install Java ${TARGET_JAVA_VERSION}"
        log "Java ${TARGET_JAVA_VERSION} installation completed."
    fi
}

# Function to set the target Java version as the default version using alternatives
# Configures the system to use the newly installed Java version as the default
set_java_default() {
    log "Setting Java ${TARGET_JAVA_VERSION} as the default version using alternatives..."

    # Get the correct path for the target Java version
    JAVA_TARGET_PATH=$(update-alternatives --list java | grep "java-${TARGET_JAVA_VERSION}-openjdk")

    if [ -n "$JAVA_TARGET_PATH" ]; then
        # Set the target Java version as default
        sudo alternatives --set java "$JAVA_TARGET_PATH" 2>&1 | tee -a "$LOGFILE"
        check_error "Failed to set Java ${TARGET_JAVA_VERSION} as the default version"
    else
        # If the target Java version is not found in alternatives, add it manually
        log "Java ${TARGET_JAVA_VERSION} path not found in alternatives. Adding it manually..."
        JAVA_TARGET_BIN="/usr/lib/jvm/java-${TARGET_JAVA_VERSION}-openjdk/bin/java"
        if [ -f "$JAVA_TARGET_BIN" ]; then
            sudo alternatives --install /usr/bin/java java "$JAVA_TARGET_BIN" 1700
            check_error "Failed to add Java ${TARGET_JAVA_VERSION} to alternatives"
            log "Java ${TARGET_JAVA_VERSION} added to alternatives."
            sudo alternatives --set java "$JAVA_TARGET_BIN" 2>&1 | tee -a "$LOGFILE"
            check_error "Failed to set Java ${TARGET_JAVA_VERSION} as the default version after adding"
        else
            log "ERROR: Java ${TARGET_JAVA_VERSION} binary not found at $JAVA_TARGET_BIN. Exiting."
            exit 1
        fi
    fi

    # Verify if alternatives was used to set the target Java version as the default version
    default_java=$(readlink -f /usr/bin/java)
    if [[ "$default_java" != *"java-${TARGET_JAVA_VERSION}-openjdk"* ]]; then
        log "ERROR: Java ${TARGET_JAVA_VERSION} is not the default version. Please check alternatives settings."
        exit 1
    else
        log "Java ${TARGET_JAVA_VERSION} is now the default version."
    fi
}

# Function to check if Payara and Dataverse services are running and stop them if they are
# Ensures all dependent services are stopped before proceeding with the Java upgrade
check_and_stop_services() {
    # Check if Solr is running and stop it if necessary
    if systemctl is-active --quiet Solr; then
        log "Solr is running. Stopping Solr service..."
        sudo systemctl stop Solr
        check_error "Failed to stop Solr service"
        log "Solr service stopped successfully."
    else
        log "Solr service is not running."
    fi

    # Check if Payara is running and stop it if necessary
    if systemctl is-active --quiet payara; then
        log "Payara is running. Stopping Payara service..."
        sudo systemctl stop payara
        check_error "Failed to stop Payara service"
        log "Payara service stopped successfully."
    else
        log "Payara service is not running."
    fi

    # Check if Dataverse is running and stop it if necessary
    if systemctl is-active --quiet dataverse; then
        log "Dataverse is running. Stopping Dataverse service..."
        sudo systemctl stop dataverse
        check_error "Failed to stop Dataverse service"
        log "Dataverse service stopped successfully."
    else
        log "Dataverse service is not running."
    fi
}

# Function to check if Payara and Dataverse services are running and start them if they are not
# Restarts all dependent services after the Java upgrade is complete
check_and_start_services() {
    # Check if Solr is not running and start it if necessary
    if systemctl is-active --quiet Solr; then
        log "Solr is not running. Starting Solr service..."
        sudo systemctl stop Solr
        check_error "Failed to stop Solr service"
        log "Solr service started successfully."
    else
        log "Solr service was already running."
    fi

    # Check if Payara is not running and start it if necessary
    if systemctl is-active --quiet payara; then
        log "Payara is not running. Starting Payara service..."
        sudo systemctl stop payara
        check_error "Failed to stop Payara service"
        log "Payara service started successfully."
    else
        log "Payara service was already running."
    fi

    # Check if Dataverse is not running and start it if necessary
    if systemctl is-active --quiet dataverse; then
        log "Dataverse is not running. Starting Dataverse service..."
        sudo systemctl stop dataverse
        check_error "Failed to stop Dataverse service"
        log "Dataverse service started successfully."
    else
        log "Dataverse service was already running."
    fi
}

# Function to verify JAVA_HOME and PATH for the dataverse user
# Ensures the Java environment is properly configured for the dataverse user
verify_java_configuration() {
    log "Verifying JAVA_HOME and PATH for the dataverse user..."
    verify_java_home
}

# Function to start the upgrade process
# Orchestrates the entire Java upgrade process in the correct order
upgrade_java() {
    # Step 1: Stop Payara and Dataverse services
    check_and_stop_services

    # Step 2: Install Java 17 if necessary
    install_java

    # Step 3: Set Java 17 as default
    set_java_default

    # Step 4: Verify JAVA_HOME configuration
    verify_java_configuration

    log "Java ${TARGET_JAVA_VERSION} upgrade completed successfully."
    log "Upgrade process complete. Log file saved to $LOGFILE."
}

# Run the upgrade process
upgrade_java