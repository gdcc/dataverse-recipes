#!/bin/bash

# Dataverse 6.6 Upgrade Verification Script
# This script helps verify that your Dataverse 6.5 to 6.6 upgrade completed successfully

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

check_service() {
    local service=$1
    local port=$2
    local name=$3
    
    if systemctl is-active --quiet "$service"; then
        if nc -z localhost "$port" 2>/dev/null; then
            success "$name is running and responding on port $port"
            return 0
        else
            warning "$name service is running but not responding on port $port"
            return 1
        fi
    else
        error "$name service is not running"
        return 1
    fi
}

check_api_endpoint() {
    local endpoint=$1
    local description=$2
    
    local response=$(curl -s --max-time 10 "$endpoint" 2>/dev/null || echo "FAILED")
    if [[ "$response" != "FAILED" ]] && [[ "$response" =~ "status" || "$response" =~ "version" || "$response" =~ "data" ]]; then
        success "$description endpoint is accessible"
        return 0
    else
        error "$description endpoint is not accessible"
        return 1
    fi
}

main() {
    log "🔍 Starting Dataverse 6.6 Upgrade Verification"
    log "=============================================="
    
    local issues=0
    
    echo ""
    log "1️⃣  CHECKING CORE SERVICES"
    echo "----------------------------"
    
    if ! check_service "payara" "8080" "Payara (Dataverse)"; then
        ((issues++))
    fi
    
    if ! check_service "solr" "8983" "Solr (Search)"; then
        ((issues++))
    fi
    
    if ! check_service "postgresql" "5432" "PostgreSQL (Database)"; then
        ((issues++))
    fi
    
    echo ""
    log "2️⃣  CHECKING DATAVERSE API"
    echo "---------------------------"
    
    if ! check_api_endpoint "http://localhost:8080/api/info/version" "Version"; then
        ((issues++))
    else
        local version=$(curl -s "http://localhost:8080/api/info/version" 2>/dev/null | jq -r '.data.version' 2>/dev/null || echo "unknown")
        if [[ "$version" == "6.6" ]]; then
            success "Dataverse version is 6.6 ✓"
        else
            warning "Dataverse version shows as: $version (expected: 6.6)"
            ((issues++))
        fi
    fi
    
    if ! check_api_endpoint "http://localhost:8080/api/info/server" "Server status"; then
        ((issues++))
    fi
    
    echo ""
    log "3️⃣  CHECKING SEARCH INDEX"
    echo "--------------------------"
    
    local solr_status=$(curl -s "http://localhost:8983/solr/admin/cores?action=STATUS&core=collection1" 2>/dev/null || echo "FAILED")
    if [[ "$solr_status" != "FAILED" ]]; then
        success "Solr core is accessible"
        
        local doc_count=$(curl -s "http://localhost:8983/solr/collection1/select?q=*:*&rows=0" 2>/dev/null | jq -r '.response.numFound' 2>/dev/null || echo "unknown")
        info "Indexed documents: $doc_count"
        
        if [[ "$doc_count" =~ ^[0-9]+$ ]] && [[ $doc_count -gt 0 ]]; then
            success "Search index contains data"
        else
            warning "Search index appears empty - indexing may be in progress"
        fi
    else
        error "Cannot connect to Solr"
        ((issues++))
    fi
    
    echo ""
    log "4️⃣  CHECKING NEW 6.6 FEATURES"
    echo "------------------------------"
    
    # Check for new metadata blocks
    local metadata_blocks=$(curl -s "http://localhost:8080/api/metadatablocks" 2>/dev/null | jq -r '.data[].name' 2>/dev/null || echo "")
    if echo "$metadata_blocks" | grep -q "threedimobject"; then
        success "3D Objects metadata block is available"
    else
        warning "3D Objects metadata block not found"
    fi
    
    # Check configuration
    local config_response=$(curl -s "http://localhost:8080/api/admin/settings" 2>/dev/null || echo "FAILED")
    if [[ "$config_response" != "FAILED" ]]; then
        success "Configuration API is accessible"
    else
        warning "Cannot access configuration API"
    fi
    
    echo ""
    log "5️⃣  SYSTEM HEALTH SUMMARY"
    echo "--------------------------"
    
    if [[ $issues -eq 0 ]]; then
        success "All checks passed! Your Dataverse 6.6 upgrade appears successful."
        echo ""
        info "NEXT STEPS:"
        info "• Test creating and uploading to a dataset"  
        info "• Verify search functionality works"
        info "• Check that custom metadata fields are preserved"
        info "• Review logs for any warnings: tail -f /usr/local/payara6/glassfish/domains/domain1/logs/server.log"
    else
        warning "Found $issues potential issues that should be investigated."
        echo ""
        info "TROUBLESHOOTING:"
        info "• Check service logs: journalctl -u payara -u solr -u postgresql --since '1 hour ago'"
        info "• Verify database connectivity"
        info "• Ensure all services are running and ports are accessible"
        info "• Review the upgrade log for any errors"
    fi
    
    echo ""
    log "✅ Verification complete!"
}

# Check if required tools are available
if ! command -v curl >/dev/null 2>&1; then
    error "curl is required but not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    warning "jq is not installed - some checks will be limited"
fi

if ! command -v nc >/dev/null 2>&1; then
    warning "netcat (nc) is not installed - port checks will be limited"
fi

main "$@" 