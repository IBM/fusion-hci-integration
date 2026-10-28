#!/bin/bash
# Configure bastion registry proxy infrastructure
# This script configures the complete infrastructure for cross-cluster registry access:
#   1. HAProxy on bastion host to proxy HCI registry
#   2. Cluster-wide insecure registry configuration (required for self-signed cert)
#
# This is infrastructure-level setup that enables ANY application to build and
# push images through the bastion proxy to the HCI registry.
#
# Privilege model: run this script as your NORMAL user (NOT with sudo).
#   - HAProxy / certificate / firewall commands are wrapped in sudo individually.
#   - All 'oc' commands run unprivileged, using your own kubeconfig and the
#     explicit ${MAIN_CLUSTER_CONTEXT} context.

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

echo "=========================================="
echo "Configure Bastion Registry Proxy Infrastructure"
echo "=========================================="
echo ""
echo "This script configures infrastructure for cross-cluster registry access:"
echo ""
echo "Part 1: Bastion HAProxy Configuration"
echo "  1. Generate SSL certificate for bastion"
echo "  2. Backup current HAProxy configuration"
echo "  3. Add HCI registry proxy configuration with header rewrites"
echo "  4. Configure firewall"
echo "  5. Validate and reload HAProxy"
echo ""
echo "Part 2: Cluster Configuration"
echo "  6. Configure insecure registry for bastion proxy"
echo "  7. Wait for MachineConfigPool rollout"
echo ""
echo "Note: This is infrastructure setup, not application-specific."
echo "      After this runs, any application can use the bastion proxy."
echo ""

# Must NOT run as root: the oc commands (Step 7) need the invoking user's
# kubeconfig. Root-only commands are wrapped in sudo individually.
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}ERROR: Do not run this script as root or with sudo.${NC}"
    echo "Run it as your normal user; privileged commands use sudo internally."
    exit 1
fi

echo "Requesting sudo access for HAProxy / certificate / firewall changes..."
sudo -v
echo ""

# Configuration variables
BASTION_HOST="${BASTION_HOST:?BASTION_HOST is not set - run generate-setup and source setup_env.sh}"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
BACKUP_DIR="/etc/haproxy/backups"
REGISTRY_PORT="${REGISTRY_PROXY_PORT:-5443}"  # Use 5443 to avoid conflict with port 5000
HCI_REGISTRY_HOST="${HCI_REGISTRY%%/*}"  # Extract host from full registry URL

# Resolve HCI registry hostname to IP (HAProxy runs in chroot without DNS)
echo "Resolving HCI registry hostname to IP address..."
HCI_REGISTRY_IP=$(getent hosts "${HCI_REGISTRY_HOST}" | awk '{ print $1 }' | head -1)
if [ -z "${HCI_REGISTRY_IP}" ]; then
    echo -e "${RED}Error: Could not resolve ${HCI_REGISTRY_HOST}${NC}"
    exit 1
fi
echo "  ${HCI_REGISTRY_HOST} resolves to ${HCI_REGISTRY_IP}"

echo "Configuration:"
echo "  Bastion Host: ${BASTION_HOST}"
echo "  HAProxy Config: ${HAPROXY_CFG}"
echo "  Registry Proxy Port: ${REGISTRY_PORT}"
echo "  HCI Registry: ${HCI_REGISTRY_HOST}"
echo ""

echo "=========================================="
echo "Step 0: Generate SSL Certificate"
echo "=========================================="
echo ""

# Generate self-signed certificate for bastion if it doesn't exist
echo "Checking for SSL certificate..."
CERT_FILE="/etc/pki/tls/certs/bastion.pem"
CERT_CRT="/etc/pki/tls/certs/bastion.crt"
CERT_KEY="/etc/pki/tls/private/bastion.key"

if sudo test -f "${CERT_FILE}"; then
    echo "✓ Certificate already exists: ${CERT_FILE}"
else
    echo "Generating self-signed certificate..."
    sudo mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
    
    # Generate certificate and key
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${CERT_KEY}" \
      -out "${CERT_CRT}" \
      -subj "/CN=${BASTION_HOST}" 2>/dev/null
    
    # Combine into PEM file for HAProxy (redirection must happen as root)
    sudo bash -c "cat '${CERT_CRT}' '${CERT_KEY}' > '${CERT_FILE}'"
    
    # Set permissions
    sudo chmod 600 "${CERT_FILE}" "${CERT_KEY}"
    sudo chown haproxy:haproxy "${CERT_FILE}" 2>/dev/null || true
    
    echo "✓ Certificate generated: ${CERT_FILE}"
fi

echo ""

# Create the registry proxy configuration snippet with working header rewrites
REGISTRY_CONFIG=$(cat <<'EOF'

#---------------------------------------------------------------------
# HCI Registry Proxy Configuration
# Added by infrastructure setup scripts
# Provides local access to HCI registry for all cluster workers
#---------------------------------------------------------------------

# Frontend for HCI registry proxy
# Listens on port 5443 to avoid conflict with existing port 5000
# Uses HTTP mode to rewrite Host header and response headers
frontend hci-registry-proxy
    bind *:5443 ssl crt /etc/pki/tls/certs/bastion.pem
    mode http
    option httplog
    log global
    
    # Connection timeouts for registry operations
    timeout client 5m
    
    # Rewrite Host header to match the registry route
    # This allows the OpenShift router to route correctly
    http-request set-header Host HCI_REGISTRY_HOST
    
    # CRITICAL: Rewrite all response headers that contain the real registry hostname
    # This prevents clients from trying to connect directly to the backend
    # Without these rewrites, authentication will fail for amd64 workers
    http-response replace-header Location ^https://HCI_REGISTRY_HOST(.*) https://BASTION_HOST:REGISTRY_PORT\1
    http-response replace-header WWW-Authenticate (.*https://)HCI_REGISTRY_HOST(.*) \1BASTION_HOST:REGISTRY_PORT\2
    http-response replace-header Docker-Distribution-Api-Version (.*https://)HCI_REGISTRY_HOST(.*) \1BASTION_HOST:REGISTRY_PORT\2
    
    default_backend hci-registry-backend

# Backend connecting to actual HCI registry
# Connects via HTTPS with correct SNI to OpenShift router
backend hci-registry-backend
    mode http
    log global
    
    # Load balancing (must come before server definitions)
    balance roundrobin
    
    # Connection timeouts
    timeout connect 10s
    timeout server 5m
    
    # Forward to HCI registry route via OpenShift router
    # Using IP address instead of hostname (HAProxy runs in chroot without DNS)
    # HCI_REGISTRY_HOST resolves to HCI_REGISTRY_IP
    # ssl: initiate HTTPS connection
    # verify none: don't verify backend certificate
    # sni str(...): send correct SNI for OpenShift router
    server hci-registry HCI_REGISTRY_IP:443 ssl verify none sni str(HCI_REGISTRY_HOST)

# Optional: Stats endpoint for monitoring registry traffic
# Uncomment to enable HAProxy statistics page
# listen registry-stats
#     bind *:8405
#     mode http
#     stats enable
#     stats uri /registry-stats
#     stats refresh 30s
#     stats show-legends
#     stats show-node
#     stats realm HAProxy\ Registry\ Statistics
#     stats auth admin:changeme

EOF
)

# Replace placeholders with actual values
REGISTRY_CONFIG="${REGISTRY_CONFIG//HCI_REGISTRY_HOST/${HCI_REGISTRY_HOST}}"
REGISTRY_CONFIG="${REGISTRY_CONFIG//HCI_REGISTRY_IP/${HCI_REGISTRY_IP}}"
REGISTRY_CONFIG="${REGISTRY_CONFIG//BASTION_HOST/${BASTION_HOST}}"
REGISTRY_CONFIG="${REGISTRY_CONFIG//REGISTRY_PORT/${REGISTRY_PORT}}"

echo "=========================================="
echo "Step 1: Backup Current Configuration"
echo "=========================================="
echo ""

# Create backup on bastion
sudo mkdir -p "${BACKUP_DIR}"

# Create timestamped backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/haproxy.cfg.${TIMESTAMP}"

echo "Creating backup: ${BACKUP_FILE}"
sudo cp "${HAPROXY_CFG}" "${BACKUP_FILE}"

# Keep only last 10 backups
sudo bash -c "cd '${BACKUP_DIR}' && ls -t haproxy.cfg.* 2>/dev/null | tail -n +11 | xargs -r rm -f"

echo "✓ Backup created: ${BACKUP_FILE}"
sudo ls -lh "${BACKUP_FILE}"

echo ""

echo "=========================================="
echo "Step 2: Add Registry Proxy Configuration"
echo "=========================================="
echo ""

# Check if registry config already exists
if sudo grep -q 'hci-registry-proxy' "${HAPROXY_CFG}" 2>/dev/null; then
    echo -e "${YELLOW}⚠ Registry proxy configuration already exists${NC}"
    echo ""
    read -p "Do you want to replace it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        exit 0
    fi
    
    # Remove existing registry configuration
    echo "Removing existing registry configuration..."
    sudo sed -i '/^# HCI Registry Proxy Configuration$/,/^# Optional: Stats endpoint for monitoring registry traffic$/d' "${HAPROXY_CFG}"
    echo "✓ Existing configuration removed"
    echo ""
fi

# Add new registry configuration
echo "Adding registry proxy configuration..."
echo "${REGISTRY_CONFIG}" | sudo tee -a "${HAPROXY_CFG}" > /dev/null
echo "✓ Registry configuration appended to end of ${HAPROXY_CFG}"

echo ""

echo "=========================================="
echo "Step 3: Configure Firewall"
echo "=========================================="
echo ""

echo "Opening port ${REGISTRY_PORT} in firewall..."

# Check if firewalld is active
if systemctl is-active --quiet firewalld; then
    echo "Configuring firewalld..."
    
    # Add port to public zone (for x86 workers on 192.168.100.0/24)
    echo "  Adding port ${REGISTRY_PORT}/tcp to public zone..."
    sudo firewall-cmd --permanent --zone=public --add-port=${REGISTRY_PORT}/tcp
    
    # Add port to internal zone (for s390x workers on 10.0.0.0/24)
    echo "  Adding port ${REGISTRY_PORT}/tcp to internal zone..."
    sudo firewall-cmd --permanent --zone=internal --add-port=${REGISTRY_PORT}/tcp
    
    # Reload firewall to apply changes
    echo "  Reloading firewall..."
    sudo firewall-cmd --reload
    
    echo "✓ Firewall configured successfully"
    echo ""
    echo "Active zones and ports:"
    sudo firewall-cmd --get-active-zones
    echo ""
    echo "Public zone ports:"
    sudo firewall-cmd --zone=public --list-ports
    echo ""
    echo "Internal zone ports:"
    sudo firewall-cmd --zone=internal --list-ports
else
    echo "⚠ firewalld is not active, skipping firewall configuration"
    echo "  If using iptables, you may need to configure it manually"
fi

echo ""

echo "=========================================="
echo "Step 4: Validate Configuration"
echo "=========================================="
echo ""

# Test the configuration
echo "Testing HAProxy configuration..."
if sudo haproxy -c -f "${HAPROXY_CFG}" 2>&1; then
    echo -e "${GREEN}✓ Configuration is valid${NC}"
else
    echo -e "${RED}✗ Configuration validation failed${NC}"
    echo ""
    echo "Restoring from backup..."
    LATEST_BACKUP=$(sudo bash -c "ls -t '${BACKUP_DIR}'/haproxy.cfg.* 2>/dev/null | head -1")
    if [ -n "${LATEST_BACKUP}" ]; then
        sudo cp "${LATEST_BACKUP}" "${HAPROXY_CFG}"
        echo "✓ Configuration restored from backup: ${LATEST_BACKUP}"
    fi
    exit 1
fi

echo ""

echo "=========================================="
echo "Step 5: Reload HAProxy"
echo "=========================================="
echo ""

echo "Reloading HAProxy (no downtime)..."
if sudo systemctl reload haproxy; then
    echo -e "${GREEN}✓ HAProxy reloaded successfully${NC}"
else
    echo -e "${RED}✗ HAProxy reload failed${NC}"
    echo "Check HAProxy status: systemctl status haproxy"
    exit 1
fi

echo ""

echo "=========================================="
echo "Step 6: Verify Registry Proxy"
echo "=========================================="
echo ""

# Wait a moment for HAProxy to fully reload
sleep 2

echo "Checking if registry proxy is listening..."
if ss -tlnp | grep -q ":${REGISTRY_PORT}"; then
    echo -e "${GREEN}✓ Registry proxy is listening on port ${REGISTRY_PORT}${NC}"
else
    echo -e "${YELLOW}⚠ Port ${REGISTRY_PORT} not found in listening ports${NC}"
    echo "This might be normal if HAProxy binds to specific IPs"
fi

echo ""

# Test connectivity from bastion to HCI registry
echo "Testing connectivity to HCI registry..."
if curl -k -m 5 "https://${HCI_REGISTRY_HOST}/v2/" 2>/dev/null | grep -q "errors"; then
    echo -e "${GREEN}✓ HCI registry is reachable from bastion${NC}"
else
    echo -e "${YELLOW}⚠ Could not verify HCI registry connectivity${NC}"
    echo "This is normal if authentication is required"
fi

echo ""

echo "=========================================="
echo "Step 7: Configure Cluster Insecure Registry"
echo "=========================================="
echo ""

echo "The bastion proxy uses a self-signed certificate, which requires"
echo "configuring it as an insecure registry in the cluster."
echo ""
echo "This is a HARD REQUIREMENT for OpenShift to accept the self-signed cert."
echo ""

# All oc commands run as the invoking (unprivileged) user against the main cluster
OC=(oc --context "${MAIN_CLUSTER_CONTEXT}")

# Check if oc is available and authenticated
echo "Checking cluster authentication (context: ${MAIN_CLUSTER_CONTEXT})..."
SKIP_CLUSTER_CONFIG=false

if ! command -v oc &> /dev/null; then
    echo -e "${YELLOW}⚠ oc command not found${NC}"
    SKIP_CLUSTER_CONFIG=true
elif [ -z "${MAIN_CLUSTER_CONTEXT}" ] || ! oc config get-contexts -o name | grep -qx "${MAIN_CLUSTER_CONTEXT}"; then
    echo -e "${YELLOW}⚠ oc context '${MAIN_CLUSTER_CONTEXT}' not found (run oc login and rename the context)${NC}"
    SKIP_CLUSTER_CONFIG=true
elif ! "${OC[@]}" auth can-i patch image.config.openshift.io/cluster &> /dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Not authenticated or insufficient permissions${NC}"
    SKIP_CLUSTER_CONFIG=true
fi

if [ "${SKIP_CLUSTER_CONFIG}" = "true" ]; then
    echo ""
    echo "The cluster configuration step requires 'oc' CLI with cluster-admin access"
    echo "on context '${MAIN_CLUSTER_CONTEXT}' for the current user (${USER})."
    echo ""
    echo -e "${YELLOW}ACTION REQUIRED:${NC}"
    echo "Please run the following commands manually from a system with cluster-admin access:"
    echo ""
    echo "# 1. Check current insecure registry configuration:"
    echo "oc --context ${MAIN_CLUSTER_CONTEXT} get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries[*]}'"
    echo ""
    echo "# 2. If ${BASTION_HOST}:${REGISTRY_PORT} is not listed, add it:"
    echo "oc --context ${MAIN_CLUSTER_CONTEXT} patch image.config.openshift.io/cluster --type=merge --patch '"
    echo "spec:"
    echo "  registrySources:"
    echo "    insecureRegistries:"
    echo "    - ${BASTION_HOST}:${REGISTRY_PORT}"
    echo "'"
    echo ""
    echo "# 3. Monitor the MachineConfigPool rollout (worker nodes will restart):"
    echo "oc --context ${MAIN_CLUSTER_CONTEXT} get mcp -w"
    echo ""
    echo "# 4. Wait until all nodes show UPDATED=True, UPDATING=False, DEGRADED=False"
    echo ""
else
    # Check if we need to configure insecure registries
    echo "Checking current insecure registry configuration..."
    CURRENT_INSECURE=$("${OC[@]}" get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries[*]}' 2>/dev/null || echo "")
    
    if echo "${CURRENT_INSECURE}" | grep -q "${BASTION_HOST}:${REGISTRY_PORT}"; then
        echo -e "${GREEN}✓ Bastion registry already configured as insecure${NC}"
        echo ""
    else
        echo "Adding ${BASTION_HOST}:${REGISTRY_PORT} to insecure registries..."
        echo ""
        
        # Get current insecure registries as JSON array
        CURRENT_ARRAY=$("${OC[@]}" get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries}' 2>/dev/null || echo "[]")
        
        # Add bastion registry to the array
        if [ "${CURRENT_ARRAY}" = "[]" ] || [ -z "${CURRENT_ARRAY}" ]; then
            # No existing insecure registries
            NEW_ARRAY="[\"${BASTION_HOST}:${REGISTRY_PORT}\"]"
        else
            # Append to existing array (remove trailing ] and add new entry)
            NEW_ARRAY="${CURRENT_ARRAY%]},\"${BASTION_HOST}:${REGISTRY_PORT}\"]"
        fi
        
        # Patch the cluster configuration
        cat <<EOF | "${OC[@]}" patch image.config.openshift.io/cluster --type=merge --patch-file=/dev/stdin
spec:
  registrySources:
    insecureRegistries:
$(echo "${NEW_ARRAY}" | jq -r '.[]' | sed 's/^/    - /')
EOF
        
        echo -e "${GREEN}✓ Insecure registry configuration updated${NC}"
        echo ""
        
        echo "Waiting for MachineConfigPool to start updating..."
        echo "This will cause worker nodes to restart with the new configuration."
        echo ""
        
        # Wait a moment for the change to propagate
        sleep 10
        
        # Check MachineConfigPool status
        echo "MachineConfigPool status:"
        "${OC[@]}" get mcp
        echo ""
        
        echo -e "${YELLOW}⚠ Worker nodes will restart to apply the configuration${NC}"
        echo ""
        echo "Monitor the rollout with:"
        echo "  oc --context ${MAIN_CLUSTER_CONTEXT} get mcp -w"
        echo ""
        echo "Wait for all nodes to be updated before proceeding with builds."
        echo ""
    fi
fi

echo "=========================================="
echo -e "${GREEN}Infrastructure Configuration Complete!${NC}"
echo "=========================================="
echo ""
echo "Bastion Registry Proxy:"
echo "  Endpoint: ${BASTION_HOST}:${REGISTRY_PORT}"
echo "  Protocol: HTTPS (self-signed certificate)"
echo "  Backend: ${HCI_REGISTRY_HOST}"
echo ""
echo "Cluster Configuration:"
echo "  Insecure Registry: ${BASTION_HOST}:${REGISTRY_PORT}"
echo "  Status: Configured (workers may be restarting)"
echo ""
echo "Next Steps:"
echo ""
echo "1. Wait for MachineConfigPool rollout to complete:"
echo "   oc --context ${MAIN_CLUSTER_CONTEXT} get mcp -w"
echo "   (Wait until all nodes show UPDATED=True)"
echo ""
echo "2. Verify registry access from a worker node:"
echo "   oc --context ${MAIN_CLUSTER_CONTEXT} debug node/<worker-node>"
echo "   curl -k https://${BASTION_HOST}:${REGISTRY_PORT}/v2/"
echo ""
echo "3. Create the registry access secret for workloads pulling through the proxy:"
echo "   ./main-cluster/bastion-registry/setup-registry-access.sh"
echo ""
echo "Configuration Files:"
echo "  HAProxy config: ${HAPROXY_CFG}"
echo "  Backup location: ${BACKUP_DIR}"
echo ""
echo "To rollback HAProxy:"
echo "  ssh ${BASTION_USER}@${BASTION_HOST}"
echo "  sudo cp ${BACKUP_DIR}/haproxy.cfg.<timestamp> ${HAPROXY_CFG}"
echo "  sudo systemctl reload haproxy"
echo ""
echo "To rollback insecure registry config:"
echo "  oc --context ${MAIN_CLUSTER_CONTEXT} patch image.config.openshift.io/cluster --type=json \\"
echo "    -p='[{\"op\":\"remove\",\"path\":\"/spec/registrySources/insecureRegistries\"}]'"
echo ""

# Made with Bob
