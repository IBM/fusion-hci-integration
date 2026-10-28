#!/usr/bin/env bash
# setup-provider-credentials.sh
#
# Creates the HCI-side ServiceAccounts, Roles, and RoleBindings for both
# operators, then writes the resulting kubeconfig Secrets to the LO cluster.
#
# Two Secrets are created:
#
#   hci-provider-credentials   (consumed by hci-consumer operator)
#     — narrow SA: VirtualMachine + DataVolume CRUD in the consumer namespace
#     — permanent; used by the steady-state worker reconcile loop
#
#   hci-provisioner-credentials  (consumed by hci-provisioner operator)
#     — broader SA: gateway VM, UDN, ServiceAccount/token management (BS-05)
#     — used only during bootstrap and teardown phases
#
# The two SAs are deliberately separate:
#   The provisioner SA can create the consumer SA token (BS-05). If they shared
#   credentials the consumer would hold the power to mint its own replacements —
#   a privilege escalation path. Separation enforces least privilege.
#
# Prerequisites:
#   - oc logged in to the LO cluster   (oc --context $MAIN_CLUSTER_CONTEXT)
#   - oc logged in to the HCI cluster  (oc --context $HCI_CLUSTER_CONTEXT)
#   - setup_env.sh sourced or present at repo root
#
# Usage:
#   ./setup-provider-credentials.sh               # create/update both
#   ./setup-provider-credentials.sh --consumer    # consumer only
#   ./setup-provider-credentials.sh --provisioner # provisioner only
#   ./setup-provider-credentials.sh --delete      # delete both
#   ./setup-provider-credentials.sh --delete --consumer    # delete consumer only
#   ./setup-provider-credentials.sh --delete --provisioner # delete provisioner only
#
# Environment overrides:
#   HCI_NAMESPACE=my-ns ./setup-provider-credentials.sh
#   TOKEN_DURATION=720h ./setup-provider-credentials.sh

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── Locate repo root and source setup_env.sh ─────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null \
  || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"

if [[ -f "${REPO_ROOT}/setup_env.sh" ]]; then
  # shellcheck source=../setup_env.sh
  source "${REPO_ROOT}/setup_env.sh" --silent
else
  echo -e "${RED}Error: setup_env.sh not found in repo root (${REPO_ROOT})${NC}"
  exit 1
fi

# ── Defaults (can be overridden via environment) ──────────────────────────────
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-hci-node-manager}"
HCI_NAMESPACE="${HCI_NAMESPACE:-${HCI_INTEGRATION_NAMESPACE}}"
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"   # 1 year

CONSUMER_SA="hci-consumer-operator"
CONSUMER_SECRET="hci-provider-credentials"

PROVISIONER_SA="hci-provisioner-operator"
PROVISIONER_SECRET="hci-provisioner-credentials"

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_CONSUMER=true
DO_PROVISIONER=true
DELETE_MODE=false

for arg in "$@"; do
  case "${arg}" in
    --consumer)    DO_PROVISIONER=false ;;
    --provisioner) DO_CONSUMER=false ;;
    --delete)      DELETE_MODE=true ;;
    --help|-h)
      sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: $0 [--consumer|--provisioner] [--delete]"
      exit 1
      ;;
  esac
done

# ── Validate cluster connectivity ─────────────────────────────────────────────
echo ""
echo "=========================================="
echo " HCI Provider Credentials Setup"
echo "=========================================="
echo ""
echo "  LO  context : ${MAIN_CLUSTER_CONTEXT}"
echo "  HCI context : ${HCI_CLUSTER_CONTEXT}"
echo "  HCI ns      : ${HCI_NAMESPACE}"
echo "  LO  ns      : ${OPERATOR_NAMESPACE}"
echo "  Token TTL   : ${TOKEN_DURATION}"
echo "  Consumer    : ${DO_CONSUMER}"
echo "  Provisioner : ${DO_PROVISIONER}"
echo ""

if ! oc --context "${MAIN_CLUSTER_CONTEXT}" whoami &>/dev/null; then
  echo -e "${RED}✗ Not logged in to LO cluster (context: ${MAIN_CLUSTER_CONTEXT})${NC}"
  exit 1
fi
if ! oc --context "${HCI_CLUSTER_CONTEXT}" whoami &>/dev/null; then
  echo -e "${RED}✗ Not logged in to HCI cluster (context: ${HCI_CLUSTER_CONTEXT})${NC}"
  exit 1
fi

HCI_SERVER="$(oc --context "${HCI_CLUSTER_CONTEXT}" config view \
  --minify -o jsonpath='{.clusters[0].cluster.server}')"

# ── Helper: write a kubeconfig Secret to the LO cluster ──────────────────────
# Usage: write_lo_secret <secret-name> <sa-name> <token>
write_lo_secret() {
  local secret_name="$1" sa_name="$2" token="$3"

  local kubeconfig
  kubeconfig=$(cat <<EOF
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
    namespace: ${HCI_NAMESPACE}
    user: ${sa_name}
  name: hci-provider
current-context: hci-provider
users:
- name: ${sa_name}
  user:
    token: ${token}
EOF
)

  oc --context "${MAIN_CLUSTER_CONTEXT}" create secret generic "${secret_name}" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --from-literal=kubeconfig="${kubeconfig}" \
    --dry-run=client -o yaml \
  | oc --context "${MAIN_CLUSTER_CONTEXT}" apply -f -
}

# ── Helper: ensure namespace exists on HCI ───────────────────────────────────
ensure_hci_namespace() {
  if ! oc --context "${HCI_CLUSTER_CONTEXT}" get namespace "${HCI_NAMESPACE}" &>/dev/null; then
    echo -e "${RED}✗ Namespace '${HCI_NAMESPACE}' not found on ${HCI_CLUSTER_CONTEXT}${NC}"
    echo ""
    echo "Create it first:"
    echo "  oc --context ${HCI_CLUSTER_CONTEXT} create namespace ${HCI_NAMESPACE}"
    echo "  oc --context ${HCI_CLUSTER_CONTEXT} label namespace ${HCI_NAMESPACE} hci-gateway-enabled=true"
    exit 1
  fi
  echo -e "${GREEN}✓ Namespace ${HCI_NAMESPACE} exists${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
# DELETE MODE
# ═════════════════════════════════════════════════════════════════════════════

if "${DELETE_MODE}"; then
  echo -e "${YELLOW}── Delete mode ──${NC}"
  echo ""

  if "${DO_CONSUMER}"; then
    echo "Deleting consumer RBAC and Secret..."
    oc --context "${HCI_CLUSTER_CONTEXT}" delete rolebinding "${CONSUMER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete role "${CONSUMER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete serviceaccount "${CONSUMER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${MAIN_CLUSTER_CONTEXT}" delete secret "${CONSUMER_SECRET}" \
      -n "${OPERATOR_NAMESPACE}" --ignore-not-found
    echo -e "${GREEN}✓ Consumer RBAC and Secret deleted${NC}"
  fi

  if "${DO_PROVISIONER}"; then
    echo "Deleting provisioner RBAC and Secret..."
    oc --context "${HCI_CLUSTER_CONTEXT}" delete rolebinding "${PROVISIONER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete role "${PROVISIONER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${HCI_CLUSTER_CONTEXT}" delete serviceaccount "${PROVISIONER_SA}" \
      -n "${HCI_NAMESPACE}" --ignore-not-found
    oc --context "${MAIN_CLUSTER_CONTEXT}" delete secret "${PROVISIONER_SECRET}" \
      -n "${OPERATOR_NAMESPACE}" --ignore-not-found
    echo -e "${GREEN}✓ Provisioner RBAC and Secret deleted${NC}"
  fi

  echo ""
  echo -e "${GREEN}✓ Done${NC}"
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# CREATE / UPDATE MODE
# ═════════════════════════════════════════════════════════════════════════════

ensure_hci_namespace

# ─────────────────────────────────────────────────────────────────────────────
# CONSUMER credentials
# SA: hci-consumer-operator
# Scope: VirtualMachine + DataVolume CRUD in the consumer namespace only.
# ─────────────────────────────────────────────────────────────────────────────

if "${DO_CONSUMER}"; then
  echo ""
  echo -e "${YELLOW}── Consumer credentials (${CONSUMER_SA}) ──${NC}"
  echo ""

  echo "[1/3] ServiceAccount..."
  oc --context "${HCI_CLUSTER_CONTEXT}" create serviceaccount "${CONSUMER_SA}" \
    -n "${HCI_NAMESPACE}" \
    --dry-run=client -o yaml \
  | oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -

  echo "[2/3] Role + RoleBinding..."
  oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${CONSUMER_SA}
  namespace: ${HCI_NAMESPACE}
  annotations:
    description: >-
      Permissions for the hci-consumer operator (steady-state worker reconcile).
      Scoped to the consumer namespace — no cluster-wide access on HCI.
rules:
  # Worker VirtualMachine lifecycle
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "patch"]

  # DataVolume lifecycle (worker root disks)
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]

  # PVC cleanup (DataVolume deletion may leave PVC behind)
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "delete"]

  # Read-only Secrets and ConfigMaps in the namespace
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch"]
EOF

  oc --context "${HCI_CLUSTER_CONTEXT}" create rolebinding "${CONSUMER_SA}" \
    --role="${CONSUMER_SA}" \
    --serviceaccount="${HCI_NAMESPACE}:${CONSUMER_SA}" \
    -n "${HCI_NAMESPACE}" \
    --dry-run=client -o yaml \
  | oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
  echo -e "${GREEN}✓ Role and RoleBinding ready${NC}"

  echo "[3/3] Token + Secret..."
  CONSUMER_TOKEN="$(oc --context "${HCI_CLUSTER_CONTEXT}" create token "${CONSUMER_SA}" \
    -n "${HCI_NAMESPACE}" --duration="${TOKEN_DURATION}")"
  write_lo_secret "${CONSUMER_SECRET}" "${CONSUMER_SA}" "${CONSUMER_TOKEN}"
  echo -e "${GREEN}✓ Secret ${CONSUMER_SECRET} written to ${OPERATOR_NAMESPACE}${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PROVISIONER credentials
# SA: hci-provisioner-operator
# Scope: gateway VM + DataVolume, UDN, SA/token management (BS-05).
#        Deliberately broader than consumer; used only during bootstrap/teardown.
# ─────────────────────────────────────────────────────────────────────────────

if "${DO_PROVISIONER}"; then
  echo ""
  echo -e "${YELLOW}── Provisioner credentials (${PROVISIONER_SA}) ──${NC}"
  echo ""

  echo "[1/3] ServiceAccount..."
  oc --context "${HCI_CLUSTER_CONTEXT}" create serviceaccount "${PROVISIONER_SA}" \
    -n "${HCI_NAMESPACE}" \
    --dry-run=client -o yaml \
  | oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -

  echo "[2/3] Role + RoleBinding..."
  oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${PROVISIONER_SA}
  namespace: ${HCI_NAMESPACE}
  annotations:
    description: >-
      Permissions for the hci-provisioner operator (bootstrap and teardown).
      Broader than consumer SA: includes gateway VM, UDN, and the ability to
      create/revoke the consumer SA token (BS-05 Credentials step).
      Scoped to the consumer namespace — no cluster-wide access on HCI.
rules:
  # Gateway VirtualMachine + all worker VMs (bootstrap creates, teardown deletes)
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]

  # DataVolume lifecycle (gateway root disk)
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]

  # PVC cleanup
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "delete"]

  # UserDefinedNetwork — create internal L2 network (BS-03)
  - apiGroups: ["k8s.ovn.org"]
    resources: ["userdefinednetworks"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]

  # Secrets — read cloud-init + SSH key; create/delete consumer SA token (BS-05)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "delete", "patch"]

  # ConfigMaps — read/write for provisioning state
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  # ServiceAccount management — create/delete consumer SA (BS-05)
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "delete"]

  # ServiceAccount token creation — mint narrow consumer token (BS-05)
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]

  # RoleBinding management — bind consumer SA to its Role (BS-05)
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "watch", "create", "delete", "patch"]
EOF

  oc --context "${HCI_CLUSTER_CONTEXT}" create rolebinding "${PROVISIONER_SA}" \
    --role="${PROVISIONER_SA}" \
    --serviceaccount="${HCI_NAMESPACE}:${PROVISIONER_SA}" \
    -n "${HCI_NAMESPACE}" \
    --dry-run=client -o yaml \
  | oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
  echo -e "${GREEN}✓ Role and RoleBinding ready${NC}"

  echo "[2b/3] ClusterRole + ClusterRoleBinding (ClusterUserDefinedNetwork pre-flight check)..."
  oc --context "${HCI_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${PROVISIONER_SA}-cluster
  annotations:
    description: >-
      Cluster-scoped read permissions for the hci-provisioner operator SA on HCI.
      Allows BS-03 pre-flight check of ClusterUserDefinedNetwork.
rules:
  - apiGroups: ["k8s.ovn.org"]
    resources: ["clusteruserdefinednetworks"]
    verbs: ["get", "list", "watch"]
EOF
  oc --context "${HCI_CLUSTER_CONTEXT}" create clusterrolebinding "${PROVISIONER_SA}-cluster" \
    --clusterrole="${PROVISIONER_SA}-cluster" \
    --serviceaccount="${HCI_NAMESPACE}:${PROVISIONER_SA}" \
    --dry-run=client -o yaml \
  | oc --context "${HCI_CLUSTER_CONTEXT}" apply -f -
  echo -e "${GREEN}✓ ClusterRole and ClusterRoleBinding ready${NC}"

  echo "[3/3] Token + Secret..."
  PROVISIONER_TOKEN="$(oc --context "${HCI_CLUSTER_CONTEXT}" create token "${PROVISIONER_SA}" \
    -n "${HCI_NAMESPACE}" --duration="${TOKEN_DURATION}")"
  write_lo_secret "${PROVISIONER_SECRET}" "${PROVISIONER_SA}" "${PROVISIONER_TOKEN}"
  echo -e "${GREEN}✓ Secret ${PROVISIONER_SECRET} written to ${OPERATOR_NAMESPACE}${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo " Done"
echo "=========================================="
echo ""

if "${DO_CONSUMER}"; then
  echo -e "${GREEN}✓ ${CONSUMER_SECRET}${NC}   → ${OPERATOR_NAMESPACE} (worker VM reconcile)"
fi
if "${DO_PROVISIONER}"; then
  echo -e "${GREEN}✓ ${PROVISIONER_SECRET}${NC} → ${OPERATOR_NAMESPACE} (bootstrap/teardown)"
fi

echo ""
echo "Verify:"
echo "  oc --context ${MAIN_CLUSTER_CONTEXT} get secret -n ${OPERATOR_NAMESPACE} \\"
echo "     ${CONSUMER_SECRET} ${PROVISIONER_SECRET}"
echo ""
echo "HCI RBAC:"
echo "  oc --context ${HCI_CLUSTER_CONTEXT} get sa,role,rolebinding \\"
echo "     -n ${HCI_NAMESPACE} | grep -E '${CONSUMER_SA}|${PROVISIONER_SA}'"
echo ""
echo "Token TTL: ${TOKEN_DURATION}. Re-run this script to rotate."
echo ""
echo "NOTE: ${PROVISIONER_SECRET} is used only during bootstrap/teardown."
echo "      The BS-05 Credentials step will automate its own token rotation."
