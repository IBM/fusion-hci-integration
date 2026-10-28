#!/usr/bin/env bash
# run-local.sh — invoke the hci_provisioner role via ansible-runner
#
# Run this on the bastion host where direct cluster API access is available.
# The script sets up a fresh ansible-runner project directory in /tmp and
# invokes the role with variables synced from a live WorkerPoolProvisioning CR.
#
# Usage:
#   ./run-local.sh                         # reconcile using live CR
#   ./run-local.sh --cleanup               # simulate CR deletion (cleanup role)
#   ./run-local.sh --cr <name>             # target a specific WorkerPoolProvisioning CR
#   ./run-local.sh --mode bootstrap        # override mode (with hardcoded fallback)
#   ./run-local.sh --mode teardown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${HOME}/tmp/hci-provisioner-run"

# ── Argument parsing ──────────────────────────────────────────────────────────

CLEANUP_MODE=false
CR_NAME="hci-workers-provisioning"
CR_NAMESPACE="hci-node-manager"
MODE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)
      CLEANUP_MODE=true
      shift
      ;;
    --cr)
      CR_NAME="$2"
      shift 2
      ;;
    --mode)
      MODE_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--cleanup] [--cr <name>] [--mode bootstrap|teardown]"
      exit 1
      ;;
  esac
done

echo "==> Setting up ansible-runner project directory at ${RUNNER_DIR}"
rm -rf "${RUNNER_DIR}"
mkdir -p "${RUNNER_DIR}"/{project,inventory,env,artifacts}

# ── Inventory ─────────────────────────────────────────────────────────────────

cat > "${RUNNER_DIR}/inventory/hosts" <<'EOF'
[all]
localhost ansible_connection=local
EOF

# ── Extravars — synced from the live WorkerPoolProvisioning CR ────────────────
# The CR is the single source of truth. Edit the CR, re-run this script.
#
# Requires: oc logged in, WorkerPoolProvisioning CR in hci-node-manager namespace.
# Falls back to hardcoded defaults if the CR is not found.

if oc get workerpoolprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" &>/dev/null; then
  echo "==> Syncing extravars from live CR ${CR_NAMESPACE}/${CR_NAME}"
  oc get workerpoolprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" -o json | \
    python3 -c "
import sys, json, yaml

cr = json.load(sys.stdin)
spec = cr['spec']

pa  = spec.get('providerAccess', {})
inf = spec.get('infrastructure', {})
gw  = inf.get('gateway', {})
gwr = gw.get('resources', {})
net = inf.get('network', {})
cap = inf.get('capacity', {})

extravars = {
    'ansible_operator_meta': {
        'name':      cr['metadata']['name'],
        'namespace': cr['metadata']['namespace'],
    },
    'worker_pool_ref': spec.get('workerPoolRef', 'hci-workers'),
    'mode':            '${MODE_OVERRIDE}' or spec.get('mode', 'bootstrap'),
    'provider_access': {
        'api_endpoint':       pa.get('apiEndpoint', ''),
        'namespace':          pa.get('namespace', ''),
        'credentials_secret': pa.get('credentialsSecret', 'hci-provisioner-credentials'),
    },
    'infrastructure': {
        'gateway': {
            'ip':             gw.get('ip', ''),
            'prefix_length':  gw.get('prefixLength', 24),
            'default_router': gw.get('defaultRouter', '172.16.0.1'),
            'resources': {
                'cpu':                   gwr.get('cpu', 2),
                'memory':                gwr.get('memory', '4Gi'),
                'storage':               gwr.get('storage', '30Gi'),
                'storage_class':         gwr.get('storageClass', 'ocs-storagecluster-ceph-rbd-virtualization'),
                'data_source_name':      gwr.get('dataSourceName', 'centos-stream9'),
                'data_source_namespace': gwr.get('dataSourceNamespace', 'openshift-virtualization-os-images'),
            },
        },
        'network': {
            'machine_config_pool': net.get('machineConfigPool', 'hci-vm'),
            'topology':            net.get('topology', 'direct'),
            'mac_prefix':          net.get('macPrefix', '52:54:00'),
            'internal_subnet':     net.get('internalSubnet', '192.168.100.0/24'),
            'dns_server':          net.get('dnsServer', ''),
            'internal_network':    net.get('internalNetwork', ''),
            'internal_gateway':    net.get('internalGateway', ''),
        },
        'capacity': {
            'max_pool_size': cap.get('maxPoolSize', 10),
        },
    },
}
print(yaml.dump(extravars, default_flow_style=False))
" > "${RUNNER_DIR}/env/extravars"
else
  echo "==> WARNING: CR ${CR_NAMESPACE}/${CR_NAME} not found — using hardcoded defaults"
  MODE="${MODE_OVERRIDE:-bootstrap}"
  cat > "${RUNNER_DIR}/env/extravars" <<EOF
---
ansible_operator_meta:
  name: hci-workers-provisioning
  namespace: hci-node-manager
worker_pool_ref: hci-workers
mode: ${MODE}
provider_access:
  api_endpoint: "https://api.hci.example.com:6443"
  namespace: "main-cluster-workers"
  credentials_secret: "hci-provisioner-credentials"
infrastructure:
  gateway:
    ip: "172.16.1.100"
    prefix_length: 16
    default_router: "172.16.0.1"
    resources:
      storage_class: "ocs-storagecluster-ceph-rbd-virtualization"
      data_source_name: "centos-stream9"
      data_source_namespace: "openshift-virtualization-os-images"
  network:
    machine_config_pool: hci-vm
    topology: direct
    mac_prefix: "52:54:00"
    internal_subnet: "192.168.100.0/24"
    dns_server: "172.16.0.1"
  capacity:
    max_pool_size: 10
EOF
fi

# ── Playbook entrypoint ───────────────────────────────────────────────────────

if "${CLEANUP_MODE}"; then
  echo "==> Cleanup mode: simulating CR deletion (hci_provisioner_cleanup role)"
  cat > "${RUNNER_DIR}/project/playbook.yml" <<'EOF'
---
- name: WorkerPoolProvisioning cleanup (finalizer / CR deletion)
  hosts: localhost
  gather_facts: false
  roles:
    - role: hci_provisioner_cleanup
EOF
else
  cat > "${RUNNER_DIR}/project/playbook.yml" <<'EOF'
---
- name: WorkerPoolProvisioning reconcile
  hosts: localhost
  gather_facts: true   # needed for ansible_date_time.iso8601 in advance_steps.yml
  roles:
    - role: hci_provisioner
EOF
fi

# Symlink our roles directory into the runner project
ln -sfn "${SCRIPT_DIR}/roles" "${RUNNER_DIR}/project/roles"

echo "==> Runner directory ready at ${RUNNER_DIR}"
echo ""
echo "==> Running hci_provisioner role..."
echo ""

ansible-runner run "${RUNNER_DIR}" \
  --playbook playbook.yml \
  --rotate-artifacts 1 \
  -v
