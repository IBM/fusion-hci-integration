#!/bin/bash
#
# Script: 02-firewall-setup.sh
# Purpose: Verify and complete basic firewall configuration for HCI gateway
# Run on: LinuxONE bastion
#
# This script verifies the firewall configuration established by 01-add-route.sh
# and ensures all required zones and policies are properly configured.
#
# Note: Port-specific configurations (like registry proxy port 5443) are handled
# by their respective setup scripts (e.g., bastion-registry/setup-registry-proxy.sh)
#
# Prerequisites:
# - 01-add-route.sh should be run first (adds routing and internal zone source)
# - firewalld must be installed and running
#

set -eo pipefail

# Get the directory where this script is located
# Determine git repository root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)")"


# Source central configuration
if [ -f "${REPO_ROOT}/setup_env.sh" ]; then
    # Temporarily disable -u flag for sourcing setup_env.sh
    set +u
    source "${REPO_ROOT}/setup_env.sh" --silent
    set -u
else
    echo "Error: setup_env.sh not found in project root"
    exit 1
fi

# ============================================
# Configuration
# ============================================

# Backup directory
BACKUP_DIR="/root/firewall-backup-$(date +%Y%m%d-%H%M%S)"

# ============================================
# Functions
# ============================================

print_header() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}"
        echo "Please run: sudo $0"
        exit 1
    fi
}

validate_firewalld() {
    echo -e "${YELLOW}[1/4] Validating firewalld configuration...${NC}"
    
    local errors=0
    local warnings=0
    
    # Check if firewalld is running
    if ! systemctl is-active --quiet firewalld; then
        echo -e "${RED}✗ firewalld is not running${NC}"
        ((errors++))
    else
        echo -e "${GREEN}✓ firewalld is running${NC}"
    fi
    
    # Check if internal zone exists and is active
    if ! firewall-cmd --get-active-zones | grep -q "internal"; then
        echo -e "${RED}✗ Internal zone is not active${NC}"
        echo "  Run 01-add-route.sh first to configure internal zone"
        ((errors++))
    else
        echo -e "${GREEN}✓ Internal zone is active${NC}"
    fi
    
    # Check if public zone exists and is active
    if ! firewall-cmd --get-active-zones | grep -q "public"; then
        echo -e "${RED}✗ Public zone is not active${NC}"
        ((errors++))
    else
        echo -e "${GREEN}✓ Public zone is active${NC}"
    fi
    
    # Check if internal-to-public policy exists
    if ! firewall-cmd --get-policies | grep -q "internal-to-public"; then
        echo -e "${YELLOW}⚠ internal-to-public policy does not exist${NC}"
        echo "  This is usually created automatically by firewalld"
        ((warnings++))
    else
        echo -e "${GREEN}✓ internal-to-public policy exists${NC}"
    fi
    
    # Check if internal network source is configured
    if ! firewall-cmd --zone=internal --list-sources | grep -q "${INTERNAL_NETWORK}"; then
        echo -e "${YELLOW}⚠ Internal network ${INTERNAL_NETWORK} not in internal zone${NC}"
        echo "  This will be configured automatically"
        ((warnings++))
    else
        echo -e "${GREEN}✓ Internal network ${INTERNAL_NETWORK} configured in internal zone${NC}"
    fi
    
    # Check if IP forwarding is enabled
    if [[ $(sysctl -n net.ipv4.ip_forward) -ne 1 ]]; then
        echo -e "${YELLOW}⚠ IP forwarding is not enabled${NC}"
        echo "  Consider enabling: sysctl -w net.ipv4.ip_forward=1"
        ((warnings++))
    else
        echo -e "${GREEN}✓ IP forwarding is enabled${NC}"
    fi
    
    # Check if masquerading is enabled on public zone
    if ! firewall-cmd --zone=public --query-masquerade &>/dev/null; then
        echo -e "${YELLOW}⚠ Masquerading not enabled on public zone${NC}"
        echo "  This may be needed for NAT functionality"
        ((warnings++))
    else
        echo -e "${GREEN}✓ Masquerading enabled on public zone${NC}"
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo ""
        echo -e "${RED}Validation failed with $errors error(s)${NC}"
        if [[ $warnings -gt 0 ]]; then
            echo -e "${YELLOW}Also found $warnings warning(s)${NC}"
        fi
        return 1
    fi
    
    if [[ $warnings -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Validation passed with $warnings warning(s)${NC}"
    else
        echo ""
        echo -e "${GREEN}✓ All validations passed${NC}"
    fi
    return 0
}

backup_firewall() {
    echo -e "${YELLOW}[2/4] Creating backup...${NC}"
    mkdir -p "$BACKUP_DIR"
    
    # Backup firewalld configuration
    firewall-cmd --list-all-zones > "$BACKUP_DIR/zones.txt"
    firewall-cmd --get-active-zones > "$BACKUP_DIR/active-zones.txt"
    firewall-cmd --get-policies > "$BACKUP_DIR/policies.txt"
    firewall-cmd --info-policy=internal-to-public > "$BACKUP_DIR/policy-internal-to-public.txt" 2>/dev/null || true
    
    # Backup permanent configuration
    if [[ -d /etc/firewalld ]]; then
        tar -czf "$BACKUP_DIR/firewalld-etc.tar.gz" /etc/firewalld/ 2>/dev/null || true
    fi
    
    # Save configuration values
    cat > "$BACKUP_DIR/config.txt" << EOF
Configuration verified:
  Internal Network: ${INTERNAL_NETWORK}
  Backup Date:      $(date)
EOF
    
    echo -e "${GREEN}✓ Backup created in $BACKUP_DIR${NC}"
}

configure_firewall() {
    echo -e "${YELLOW}[3/4] Configuring firewall...${NC}"
    
    local changes_made=false
    
    # Add internal network to internal zone if missing
    if ! firewall-cmd --zone=internal --list-sources | grep -q "${INTERNAL_NETWORK}"; then
        echo "Adding ${INTERNAL_NETWORK} to internal firewall zone..."
        
        if firewall-cmd --zone=internal --add-source=${INTERNAL_NETWORK} --permanent; then
            echo -e "${GREEN}✓ Added ${INTERNAL_NETWORK} to internal zone${NC}"
            changes_made=true
        else
            echo -e "${RED}✗ Failed to add subnet to internal zone${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✓ Internal network ${INTERNAL_NETWORK} already in internal zone${NC}"
    fi
    
    # Reload firewall if changes were made
    if [ "$changes_made" = true ]; then
        echo "Reloading firewall to apply changes..."
        if firewall-cmd --reload; then
            echo -e "${GREEN}✓ Firewall reloaded successfully${NC}"
        else
            echo -e "${RED}✗ Failed to reload firewall${NC}"
            return 1
        fi
    fi
    
    echo ""
    echo -e "${GREEN}✓ Firewall configuration complete${NC}"
    return 0
}

verify_configuration() {
    echo -e "${YELLOW}[4/4] Verifying configuration...${NC}"
    
    local errors=0
    
    # Verify internal zone has the source
    if ! firewall-cmd --zone=internal --list-sources | grep -q "${INTERNAL_NETWORK}"; then
        echo -e "${RED}✗ Internal network ${INTERNAL_NETWORK} not in internal zone${NC}"
        echo "  Run 01-add-route.sh to add it"
        ((errors++))
    else
        echo -e "${GREEN}✓ Internal network ${INTERNAL_NETWORK} in internal zone${NC}"
    fi
    
    # Verify masquerading on public zone
    if ! firewall-cmd --zone=public --query-masquerade &>/dev/null; then
        echo -e "${YELLOW}⚠ Masquerading not enabled on public zone${NC}"
        echo "  This may be needed for NAT functionality"
    else
        echo -e "${GREEN}✓ Masquerading enabled on public zone${NC}"
    fi
    
    # Verify forwarding is enabled
    if ! firewall-cmd --zone=internal --query-forward &>/dev/null; then
        echo -e "${YELLOW}⚠ Forwarding not enabled on internal zone${NC}"
    else
        echo -e "${GREEN}✓ Forwarding enabled on internal zone${NC}"
    fi
    
    if ! firewall-cmd --zone=public --query-forward &>/dev/null; then
        echo -e "${YELLOW}⚠ Forwarding not enabled on public zone${NC}"
    else
        echo -e "${GREEN}✓ Forwarding enabled on public zone${NC}"
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo ""
        echo -e "${RED}Verification failed with $errors error(s)${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ All verifications passed${NC}"
    return 0
}

display_summary() {
    echo -e "${YELLOW}[5/5] Configuration summary...${NC}"
    echo ""
    echo "=== Active Zones ==="
    firewall-cmd --get-active-zones
    echo ""
    echo "=== Internal Zone ==="
    firewall-cmd --zone=internal --list-all | grep -E "(sources|services|forward|masquerade)" | head -5
    echo ""
    echo "=== Public Zone ==="
    firewall-cmd --zone=public --list-all | grep -E "(interfaces|services|forward|masquerade)" | head -6
    echo ""
    echo "=== Policies ==="
    firewall-cmd --get-policies
    echo ""
}

# ============================================
# Main Execution
# ============================================

main() {
    print_header "LinuxONE Bastion Firewall Verification"
    
    echo "This script verifies the basic firewall configuration for HCI gateway"
    echo "  Internal Network: ${INTERNAL_NETWORK}"
    echo ""
    echo "Note: Service-specific ports (like registry proxy) are configured"
    echo "      by their respective setup scripts."
    echo ""
    
    # Check if running as root
    check_root
    
    # Validate firewalld (warnings are OK, we'll fix them)
    validate_firewalld || true
    
    echo ""
    
    # Create backup
    backup_firewall
    echo ""
    
    # Configure firewall (add missing settings)
    if ! configure_firewall; then
        echo ""
        echo -e "${RED}Configuration failed. Please check the errors above.${NC}"
        echo "Backup available at: $BACKUP_DIR"
        exit 1
    fi
    
    echo ""
    
    # Verify final configuration
    if ! verify_configuration; then
        echo ""
        echo -e "${RED}Verification failed. Please check the configuration.${NC}"
        echo "Backup available at: $BACKUP_DIR"
        exit 1
    fi
    
    echo ""
    
    # Display summary
    display_summary
    
    echo ""
    print_header "Firewall Configuration Completed Successfully!"
    
    echo "Backup available at: $BACKUP_DIR"
    echo ""
    echo "Main cluster networking is now configured."
    echo ""
    echo "Next steps:"
    echo "  Continue with the Setup Guide (docs/getting-started.md), step C.3."
    echo ""
    echo "For service-specific configurations:"
    echo "  - Registry proxy: ../bastion-registry/setup-registry-proxy.sh"
    echo ""
}

# Run main function
main

# Made with Bob
