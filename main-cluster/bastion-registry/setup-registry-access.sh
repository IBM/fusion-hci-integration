#!/bin/bash
# Setup cross-cluster registry access for a new main cluster connecting to an
# already-prepared HCI registry.
#
# Prerequisites (Tier A / Tier B — done once per HCI cluster, not per main cluster):
#   - HCI image registry exposed with disableRedirect=true
#     (hci-cluster/enable-image-registry-s3.sh)
#   - SA and token Secret exist on the HCI cluster in ${HCI_INTEGRATION_NAMESPACE}
#     (hci-cluster/setup-consumer-rbac.sh)
#   - ImageStream exists on the HCI cluster
#
# This script only does main-cluster-side work:
#   1. Verify the bastion proxy is registered as an insecure registry
#   2. Read the existing token from the HCI cluster integration namespace (read-only)
#   3. Create/refresh the docker-registry push secret on the main cluster

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

# Use variables from setup_env.sh
SA_NAME="${REGISTRY_SA_NAME}"          # SA lives in HCI_INTEGRATION_NAMESPACE (Tier B)
SECRET_NAME="${REGISTRY_SECRET_NAME}"

echo "=========================================="
echo "Cross-Cluster Registry Access Setup"
echo "=========================================="
echo "Main Cluster: ${MAIN_CLUSTER_CONTEXT}"
echo "HCI Cluster: ${HCI_CLUSTER_CONTEXT}"
echo "Main Namespace: hci-node-manager"
echo "HCI Integration Namespace: ${HCI_INTEGRATION_NAMESPACE}"
echo ""

# Step 1: Use bastion registry proxy
echo "Step 1: Using bastion registry proxy..."
REGISTRY_ROUTE="${BASTION_HOST}:${REGISTRY_PROXY_PORT}"
echo "✓ Registry proxy: ${REGISTRY_ROUTE}"
echo "  (Bastion HAProxy proxies to HCI registry: ${HCI_REGISTRY})"

# Step 2: Verify insecure registry configuration on main cluster
echo ""
echo "Step 2: Verifying insecure registry configuration on main cluster..."
echo "  The bastion proxy must be configured as insecure registry"
echo "  (Required for self-signed certificate)"

oc config use-context ${MAIN_CLUSTER_CONTEXT}

# Check if bastion proxy is configured as insecure
CURRENT_INSECURE=$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources.insecureRegistries[*]}' 2>/dev/null || echo "")

if echo "${CURRENT_INSECURE}" | grep -q "${REGISTRY_ROUTE}"; then
    echo "✓ Bastion proxy (${REGISTRY_ROUTE}) is configured as insecure registry"
else
    echo ""
    echo -e "${RED}✗ ERROR: Bastion proxy is NOT configured as insecure registry!${NC}"
    echo ""
    echo "The bastion proxy (${REGISTRY_ROUTE}) must be configured before running this script."
    echo "Please run the bastion registry proxy setup first:"
    echo ""
    echo "  cd ${REPO_ROOT}/main-cluster/bastion-registry"
    echo "  ./setup-registry-proxy.sh"
    echo ""
    echo "This will configure HAProxy on the bastion and add it to insecure registries."
    exit 1
fi

# Verify registry is reachable through bastion proxy
echo ""
echo "Step 2a: Testing registry connectivity through bastion proxy..."
if curl -k -m 5 "https://${REGISTRY_ROUTE}/v2/" 2>/dev/null | grep -q "errors"; then
    echo "✓ Registry is reachable through bastion proxy"
else
    echo -e "${YELLOW}⚠ Could not verify registry connectivity${NC}"
    echo "  This is normal if authentication is required"
    echo "  Connectivity will be verified during the build process"
fi

# Step 3: Read token from HCI cluster (read-only — SA and token must already exist)
# The SA and its token Secret are created by setup-consumer-rbac.sh (Tier B, step B.2),
# scoped to the per-main-cluster integration namespace.
echo ""
echo "Step 3: Reading registry token from HCI cluster..."
oc config use-context ${HCI_CLUSTER_CONTEXT}

TOKEN_SECRET_NAME="${SA_NAME}-token"
if ! oc get secret "${TOKEN_SECRET_NAME}" -n "${HCI_INTEGRATION_NAMESPACE}" &>/dev/null; then
    echo "✗ Token secret ${TOKEN_SECRET_NAME} not found in ${HCI_INTEGRATION_NAMESPACE} on ${HCI_CLUSTER_CONTEXT}"
    echo "  Run hci-cluster/setup-consumer-rbac.sh first (Tier B step B.2)"
    exit 1
fi

REGISTRY_TOKEN=$(oc get secret "${TOKEN_SECRET_NAME}" -n "${HCI_INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.data.token}' | base64 -d)
if [ -z "${REGISTRY_TOKEN}" ]; then
    echo "✗ Token is empty — the Secret exists but has no token data yet"
    echo "  Wait a few seconds for the token controller and retry"
    exit 1
fi
echo "✓ Token retrieved (${#REGISTRY_TOKEN} characters)"

# Step 4: Create/refresh push secret on main cluster
echo ""
echo "Step 4: Creating push secret on main cluster..."
oc config use-context ${MAIN_CLUSTER_CONTEXT}

# Create namespace if it doesn't exist
if ! oc get namespace hci-node-manager &>/dev/null; then
    echo "  Creating namespace hci-node-manager..."
    oc create namespace hci-node-manager
fi

# Always replace — token may have been refreshed
if oc get secret ${SECRET_NAME} -n hci-node-manager &>/dev/null; then
    echo "  Replacing existing secret with fresh token..."
    oc delete secret ${SECRET_NAME} -n hci-node-manager
fi

oc create secret docker-registry ${SECRET_NAME} \
  --docker-server=${REGISTRY_ROUTE} \
  --docker-username=serviceaccount \
  --docker-password="${REGISTRY_TOKEN}" \
  -n hci-node-manager
echo "✓ Push secret ${SECRET_NAME} created in hci-node-manager"

echo ""
echo "=========================================="
echo "✓ Registry access setup complete"
echo "=========================================="
echo ""
echo "  Registry proxy:  ${REGISTRY_ROUTE} (via bastion HAProxy)"
echo "  Backend registry: ${HCI_REGISTRY}"
echo "  Push secret:     hci-node-manager/${SECRET_NAME}"
echo ""

# Made with Bob
