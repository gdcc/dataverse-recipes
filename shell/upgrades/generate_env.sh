#!/bin/bash

# Generate .env file for Dataverse 6.5 to 6.6 upgrade
# This script creates a .env file from the example template

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

# Check if .env already exists
if [ -f "${SCRIPT_DIR}/.env" ]; then
    print_warning ".env file already exists!"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled. Existing .env file preserved."
        exit 0
    fi
fi

# Check if env.example exists
if [ ! -f "${SCRIPT_DIR}/env.example" ]; then
    print_error "env.example file not found!"
    print_error "Please ensure env.example exists in the same directory as this script."
    exit 1
fi

# Copy the example file
cp "${SCRIPT_DIR}/env.example" "${SCRIPT_DIR}/.env"

if [ $? -eq 0 ]; then
    print_status "Successfully created .env file from env.example"
    print_status "You can now edit .env to customize your configuration:"
    echo
    echo -e "${BLUE}  nano ${SCRIPT_DIR}/.env${NC}"
    echo
    print_status "The .env file contains configuration for all software metadata fields."
    print_status "You can set each field to:"
    echo "  - true (multi-valued)"
    echo "  - false (single-valued)" 
    echo "  - disabled (skip entirely)"
    echo
    print_status "If you don't create a .env file, the upgrade script will use default values."
else
    print_error "Failed to create .env file!"
    exit 1
fi 