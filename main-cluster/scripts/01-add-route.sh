#!/bin/bash
#
# Script: 01-add-route.sh
# Purpose: Configure static route on LinuxONE bastion to reach router-VM internal network
# Run on: LinuxONE bastion
#
# This script adds a persistent route to the internal worker VM network (192.168.100.0/24)
# via the gateway VM external IP (provider.gateway.ip)
#

set -e

# Get the directory where this script is located
# Determine git repository root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)")"


# Source central configuration
if [ -f "${REPO_ROOT}/setup_env.sh" ]; then
    source "${REPO_ROOT}/setup_env.sh" --silent
else
    echo "Error: setup_env.sh not found in project root"
    exit 1
fi

# Configuration (can be overridden by setup_env.sh)
ROUTE_TABLE="main"

echo "=========================================="
echo "LinuxONE Bastion Route Configuration"
echo "=========================================="
echo ""
echo "This script will configure routing to the HCI worker VM internal network"
echo "  Internal Network: ${INTERNAL_NETWORK}"
echo "  Router VM IP:     ${ROUTER_VM_IP}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Check if route already exists
echo -e "${YELLOW}[1/4] Checking existing routes...${NC}"
ROUTE_EXISTS=false
if ip route show | grep -q "${INTERNAL_NETWORK}"; then
    ROUTE_EXISTS=true
    echo -e "${YELLOW}⚠ Route to ${INTERNAL_NETWORK} already exists:${NC}"
    ip route show | grep "${INTERNAL_NETWORK}"
    read -p "Do you want to replace it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing existing route..."
        ip route del ${INTERNAL_NETWORK} || true
        ROUTE_EXISTS=false
    else
        echo "Keeping existing route."
    fi
else
    echo -e "${GREEN}✓ No conflicting routes found${NC}"
fi

# Add the route if needed
echo -e "${YELLOW}[2/4] Adding route to ${INTERNAL_NETWORK} via ${ROUTER_VM_IP}...${NC}"
if [ "$ROUTE_EXISTS" = true ]; then
    echo -e "${GREEN}✓ Route already exists, skipping${NC}"
else
    if ip route add ${INTERNAL_NETWORK} via ${ROUTER_VM_IP}; then
        echo -e "${GREEN}✓ Route added successfully${NC}"
    else
        echo -e "${RED}✗ Failed to add route${NC}"
        exit 1
    fi
fi

# Configure firewall to allow MCS traffic from the internal network
echo -e "${YELLOW}[3/4] Configuring firewall for internal network...${NC}"
if command -v firewall-cmd &> /dev/null; then
    echo "Adding ${INTERNAL_NETWORK} to internal firewall zone..."
    
    # Check if the source is already in the internal zone
    if firewall-cmd --zone=internal --list-sources | grep -q "${INTERNAL_NETWORK}"; then
        echo -e "${YELLOW}⚠ ${INTERNAL_NETWORK} already in internal zone${NC}"
    else
        # Add the subnet to the internal zone
        if firewall-cmd --zone=internal --add-source=${INTERNAL_NETWORK} --permanent; then
            echo -e "${GREEN}✓ Added ${INTERNAL_NETWORK} to internal zone${NC}"
        else
            echo -e "${RED}✗ Failed to add subnet to internal zone${NC}"
            exit 1
        fi
    fi
    
    # Reload firewall to apply changes
    if firewall-cmd --reload; then
        echo -e "${GREEN}✓ Firewall reloaded successfully${NC}"
    else
        echo -e "${RED}✗ Failed to reload firewall${NC}"
        exit 1
    fi
    
    # Verify the configuration
    echo "Internal zone configuration:"
    firewall-cmd --zone=internal --list-all | grep -E "(sources|ports)" | head -2
else
    echo -e "${YELLOW}⚠ firewall-cmd not found, skipping firewall configuration${NC}"
    echo "Please manually configure your firewall to allow traffic from ${INTERNAL_NETWORK}"
fi

# Make route persistent
echo -e "${YELLOW}[4/4] Making route persistent...${NC}"

if [ "$ROUTE_EXISTS" = true ]; then
    echo -e "${GREEN}✓ Route already exists and should be persistent${NC}"
else
    # Detect the network configuration system
    if command -v nmcli &> /dev/null; then
        # NetworkManager is available
        echo "Using NetworkManager to persist route..."
        
        # Get the connection name for the default route
        DEFAULT_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep -v '^lo:' | head -1 | cut -d: -f1)
        
        if [ -n "$DEFAULT_CONN" ]; then
            # Only store the route in the profile. Do NOT run 'nmcli connection up':
            # the route is already live (ip route add above), and re-activating the
            # connection makes NetworkManager rewrite /etc/resolv.conf, which breaks
            # name resolution if DNS is not fully defined in the connection profile.
            nmcli connection modify "$DEFAULT_CONN" +ipv4.routes "${INTERNAL_NETWORK} ${ROUTER_VM_IP}"
            echo -e "${GREEN}✓ Route persisted via NetworkManager (connection: $DEFAULT_CONN)${NC}"
        else
            echo -e "${YELLOW}⚠ Could not determine active connection${NC}"
            echo "Route added but may not persist across reboots"
        fi
        
    elif [ -d /etc/sysconfig/network-scripts ]; then
        # RHEL/CentOS traditional network scripts
        echo "Using network scripts to persist route..."
        
        ROUTE_FILE="/etc/sysconfig/network-scripts/route-eth0"
        echo "${INTERNAL_NETWORK} via ${ROUTER_VM_IP}" >> ${ROUTE_FILE}
        echo -e "${GREEN}✓ Route persisted in ${ROUTE_FILE}${NC}"
        
    else
        # Fallback: add to rc.local
        echo "Using rc.local to persist route..."
        
        if [ ! -f /etc/rc.d/rc.local ]; then
            touch /etc/rc.d/rc.local
            chmod +x /etc/rc.d/rc.local
        fi
        
        if ! grep -q "ip route add ${INTERNAL_NETWORK}" /etc/rc.d/rc.local; then
            echo "ip route add ${INTERNAL_NETWORK} via ${ROUTER_VM_IP}" >> /etc/rc.d/rc.local
            echo -e "${GREEN}✓ Route persisted in /etc/rc.d/rc.local${NC}"
        fi
    fi
fi

# Verify the route
echo ""
echo "=========================================="
echo "Route Configuration Summary"
echo "=========================================="
echo ""
echo "Current routing table:"
ip route show | grep -E "(default|${INTERNAL_NETWORK})"
echo ""

echo ""
echo -e "${GREEN}=========================================="
echo -e "Route configuration completed successfully!"
echo -e "==========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Run: ./02-firewall-setup.sh"
echo ""

# Made with Bob
