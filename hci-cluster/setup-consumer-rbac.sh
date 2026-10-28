#!/bin/bash
#
# Script: setup-consumer-rbac.sh
# Purpose: Create the ServiceAccount, Role, and RoleBinding on the HCI cluster
#          that the hci-consumer operator uses to manage VMs in the consumer namespace.
#          Also generates a long-lived token and prints the kubeconfig to be stored
#          as the hci-provider-credentials Secret on the LO cluster.
#
# Run on: any host with oc access to the HCI cluster (HCI_CLUSTER_CONTEXT)
#
# Usage:
#   source ../setup_env.sh   (or source workspace/setup_env.sh)
#   ./setup-consumer-rbac.sh
#
# To tear down and recreate:
#   ./setup-consumer-rbac.sh --delete
#   ./setup-consumer-rbac.sh
#

set -eo pipefail

# ── Locate repo root and source configuration ─────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"

if [ -f "${REPO_ROOT}/setup_env.sh" ]; then
    set +u
    source "${REPO_ROOT}/setup_env.sh" --silent
    set -u
else
    echo "Error: setup_env.sh not found in repo root (${REPO_ROOT})"
    exit 1
fi

# ── Configuration (from setup_env.sh) ─────────────────────────────────────────
SA_NAME="hci-consumer-operator"
ROLE_NAME="hci-consumer-operator"
TOKEN_DURATION="8760h"   # 1 year

REGISTRY_SA_NAME="${REGISTRY_SA_NAME:-registry-pusher}"   # SA used for bastion-proxy image push
REGISTRY_SA_TOKEN_SECRET="${REGISTRY_SA_NAME}-token"

echo "=========================================="
echo "HCI Consumer RBAC Setup"
echo "=========================================="
echo ""
echo "  HCI context:   ${HCI_CLUSTER_CONTEXT}"
echo "  Namespace:     ${HCI_INTEGRATION_NAMESPACE}"
echo "  ServiceAccount: ${SA_NAME}"
echo ""

# ── Teardown mode ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--delete" ]]; then
    echo "Deleting consumer RBAC in ${HCI_INTEGRATION_NAMESPACE}..."
    oc --context "${HCI_CLUSTER_CONTEXT}" delete clusterrolebinding "${ROLE_NAME}-cluster" \
        --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete clusterrole "${ROLE_NAME}-cluster" \
        --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete rolebinding "${ROLE_NAME}" \
        -n "${HCI_INTEGRATION_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete role "${ROLE_NAME}" \
        -n "${HCI_INTEGRATION_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete serviceaccount "${SA_NAME}" \
        -n "${HCI_INTEGRATION_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete secret "${REGISTRY_SA_TOKEN_SECRET}" \
        -n "${HCI_INTEGRATION_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete serviceaccount "${REGISTRY_SA_NAME}" \
        -n "${HCI_INTEGRATION_NAMESPACE}" --ignore-not-found
    echo ""
    echo -e "${GREEN}✓ Consumer RBAC deleted${NC}"
    exit 0
fi

# ── Namespace must exist ──────────────────────────────────────────────────────
echo -e "${YELLOW}[1/4] Checking namespace ${HCI_INTEGRATION_NAMESPACE}...${NC}"
if ! oc --context "${HCI_CLUSTER_CONTEXT}" get namespace "${HCI_INTEGRATION_NAMESPACE}" &>/dev/null; then
    echo -e "${RED}✗ Namespace '${HCI_INTEGRATION_NAMESPACE}' not found on ${HCI_CLUSTER_CONTEXT}${NC}"
    echo ""
    echo "Create it first:"
    echo "  oc --context ${HCI_CLUSTER_CONTEXT} create namespace ${HCI_INTEGRATION_NAMESPACE}"
    echo "  oc --context ${HCI_CLUSTER_CONTEXT} label namespace ${HCI_INTEGRATION_NAMESPACE} hci-gateway-enabled=true"
    exit 1
fi
echo -e "${GREEN}✓ Namespace exists${NC}"

# ── ServiceAccount ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/4] Creating ServiceAccount ${SA_NAME}...${NC}"
oc --context "${HCI_CLUSTER_CONTEXT}" create serviceaccount "${SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" \
    --dry-run=client -o yaml | \
    oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
echo -e "${GREEN}✓ ServiceAccount ready${NC}"

# ── Role ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/4] Creating Role ${ROLE_NAME}...${NC}"
oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${HCI_INTEGRATION_NAMESPACE}
  annotations:
    description: >-
      Permissions for the hci-consumer operator running on the LO cluster.
      Scoped to the consumer namespace only — no cluster-wide access on HCI.
rules:
  # VirtualMachine lifecycle — create on scale-up, delete on scale-down
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "patch"]

  # DataVolume lifecycle — rootdisk management
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]

  # PVC cleanup on scale-down (DataVolume deletion may leave PVC behind)
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "delete"]

  # Secrets — full lifecycle: consumer operator reads credentials; provisioner
  # operator creates/patches/deletes the cloud-init Secret during bootstrap/teardown.
  # One SA, one namespace — the namespace boundary is the privilege boundary.
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  # ConfigMaps — read only
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]

  # UserDefinedNetwork — BS-03: provisioner creates/deletes the internal Layer2 UDN
  # (namespace-scoped resource — belongs in this Role)
  - apiGroups: ["k8s.ovn.org"]
    resources: ["userdefinednetworks", "userdefinednetworks/status"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]
EOF

# ── RoleBinding ───────────────────────────────────────────────────────────────
oc --context "${HCI_CLUSTER_CONTEXT}" create rolebinding "${ROLE_NAME}" \
    --role="${ROLE_NAME}" \
    --serviceaccount="${HCI_INTEGRATION_NAMESPACE}:${SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" \
    --dry-run=client -o yaml | \
    oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
echo -e "${GREEN}✓ Role and RoleBinding ready${NC}"

# ── ClusterRole + ClusterRoleBinding for cluster-scoped resources ─────────────
# ClusterUserDefinedNetwork is cluster-scoped — cannot go in a namespace Role.
# Read-only: provisioner only does a pre-flight existence check (BS-03).
CLUSTER_ROLE_NAME="${ROLE_NAME}-cluster"
echo ""
echo -e "${YELLOW}[3b/4] Creating ClusterRole ${CLUSTER_ROLE_NAME}...${NC}"
oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
  annotations:
    description: >-
      Cluster-scoped read permissions for the hci-consumer operator SA on HCI.
      Allows pre-flight check of ClusterUserDefinedNetwork in BS-03.
rules:
  # ClusterUserDefinedNetwork — read only (BS-03 pre-flight existence check)
  - apiGroups: ["k8s.ovn.org"]
    resources: ["clusteruserdefinednetworks"]
    verbs: ["get", "list", "watch"]
EOF
oc --context "${HCI_CLUSTER_CONTEXT}" create clusterrolebinding "${CLUSTER_ROLE_NAME}" \
    --clusterrole="${CLUSTER_ROLE_NAME}" \
    --serviceaccount="${HCI_INTEGRATION_NAMESPACE}:${SA_NAME}" \
    --dry-run=client -o yaml | \
    oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
echo -e "${GREEN}✓ ClusterRole and ClusterRoleBinding ready${NC}"

# ── Registry SA for bastion-proxy image push ─────────────────────────────────
# Scoped to this integration namespace — one SA per main-cluster connection.
# setup-registry-access.sh (Tier C) reads the token from here; it never
# creates or modifies anything on the HCI cluster.
echo ""
echo -e "${YELLOW}[4/5] Setting up registry SA ${REGISTRY_SA_NAME} in ${HCI_INTEGRATION_NAMESPACE}...${NC}"

oc --context "${HCI_CLUSTER_CONTEXT}" create serviceaccount "${REGISTRY_SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" \
    --dry-run=client -o yaml | \
    oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -

oc --context "${HCI_CLUSTER_CONTEXT}" policy add-role-to-user system:image-builder \
    "system:serviceaccount:${HCI_INTEGRATION_NAMESPACE}:${REGISTRY_SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" 2>/dev/null \
    || true
oc --context "${HCI_CLUSTER_CONTEXT}" policy add-role-to-user system:image-pusher \
    "system:serviceaccount:${HCI_INTEGRATION_NAMESPACE}:${REGISTRY_SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" 2>/dev/null \
    || true

if oc --context "${HCI_CLUSTER_CONTEXT}" get secret "${REGISTRY_SA_TOKEN_SECRET}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓ Token secret ${REGISTRY_SA_TOKEN_SECRET} already exists${NC}"
else
    oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${REGISTRY_SA_TOKEN_SECRET}
  namespace: ${HCI_INTEGRATION_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${REGISTRY_SA_NAME}
type: kubernetes.io/service-account-token
EOF
    echo "  Waiting for token to be populated..."
    for i in {1..10}; do
        TOKEN_VAL=$(oc --context "${HCI_CLUSTER_CONTEXT}" get secret "${REGISTRY_SA_TOKEN_SECRET}" \
            -n "${HCI_INTEGRATION_NAMESPACE}" \
            -o jsonpath='{.data.token}' 2>/dev/null || echo "")
        [ -n "${TOKEN_VAL}" ] && break
        sleep 2
    done
fi
echo -e "${GREEN}✓ Registry SA and token ready (${REGISTRY_SA_NAME})${NC}"

# ── Generate token ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[5/5] Generating ServiceAccount token (duration: ${TOKEN_DURATION})...${NC}"
TOKEN=$(oc --context "${HCI_CLUSTER_CONTEXT}" create token "${SA_NAME}" \
    -n "${HCI_INTEGRATION_NAMESPACE}" \
    --duration="${TOKEN_DURATION}")

HCI_SERVER=$(oc --context "${HCI_CLUSTER_CONTEXT}" config view \
    --minify -o jsonpath='{.clusters[0].cluster.server}')

echo -e "${GREEN}✓ Token generated${NC}"

# ── Output kubeconfig ─────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "NEXT STEP: store credentials on LO cluster"
echo "=========================================="
echo ""
echo "Run the following on the LO cluster bastion to create the Secret:"
echo ""
echo "oc --context ${MAIN_CLUSTER_CONTEXT} create secret generic hci-provider-credentials \\"
echo "  --namespace hci-node-manager \\"
echo "  --from-literal=kubeconfig=\"\$(cat <<'KUBECFG'"
cat <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: ${HCI_SERVER}
  name: hci-provider
contexts:
- context:
    cluster: hci-provider
    namespace: ${HCI_INTEGRATION_NAMESPACE}
    user: ${SA_NAME}
  name: hci-provider
current-context: hci-provider
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF
echo "KUBECFG"
echo ")\" --dry-run=client -o yaml | oc apply -f -"
echo ""
echo "=========================================="
echo ""
echo -e "${GREEN}✓ Consumer RBAC setup complete${NC}"
echo ""
echo "Verify:"
echo "  oc --context ${HCI_CLUSTER_CONTEXT} get sa,role,rolebinding,secret \\"
echo "    -n ${HCI_INTEGRATION_NAMESPACE} | grep -E '${SA_NAME}|${REGISTRY_SA_NAME}'"
echo "  oc --context ${HCI_CLUSTER_CONTEXT} get clusterrole,clusterrolebinding \\"
echo "    | grep ${SA_NAME}"
echo ""
echo "Operator token valid for 1 year. Renew by re-running this script."
echo "Registry SA token (${REGISTRY_SA_TOKEN_SECRET}) does not expire."
