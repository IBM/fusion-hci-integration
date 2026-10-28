#!/usr/bin/env bash
# run-local.sh — invoke the hci_consumer role via ansible-runner
#
# Run this on the bastion host where direct cluster API access is available.
# The script sets up a fresh ansible-runner project directory in /tmp and
# invokes the role with variables synced from a live WorkerPool CR.
#
# Usage:
#   ./run-local.sh              # normal reconcile (scale-up + scale-down)
#   ./run-local.sh --cleanup    # simulate CR deletion (hci_consumer_cleanup role)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${HOME}/tmp/hci-consumer-run"

# Parse arguments
CLEANUP_MODE=false
for arg in "$@"; do
  case "${arg}" in
    --cleanup) CLEANUP_MODE=true ;;
    *) echo "Unknown argument: ${arg}"; exit 1 ;;
  esac
done

echo "==> Setting up ansible-runner project directory at ${RUNNER_DIR}"
rm -rf "${RUNNER_DIR}"
mkdir -p "${RUNNER_DIR}"/{project,inventory,env,artifacts}

# ── inventory ────────────────────────────────────────────────────────────────
cat > "${RUNNER_DIR}/inventory/hosts" <<'EOF'
[all]
localhost ansible_connection=local
EOF

# ── extravars — synced from the live WorkerPool CR on the cluster ────────────
# The CR is the single source of truth. Edit the CR, re-run this script.
#
# Requires: oc logged in, WorkerPool CR applied to hci-node-manager namespace.
# Falls back to hardcoded defaults if the CR is not found.

CR_NAME="hci-workers"
CR_NAMESPACE="hci-node-manager"

if oc get workerpool "${CR_NAME}" -n "${CR_NAMESPACE}" &>/dev/null; then
  echo "==> Syncing extravars from live CR ${CR_NAMESPACE}/${CR_NAME}"
  oc get workerpool "${CR_NAME}" -n "${CR_NAMESPACE}" -o json | \
    python3 -c "
import sys, json, yaml

cr = json.load(sys.stdin)
spec = cr['spec']
p   = spec.get('provider', {})
pg  = p.get('gateway', {})
pgr = pg.get('resources', {})
pn  = p.get('networking', {})
c   = spec.get('consumer', {})
cn  = c.get('networking', {})
cw  = c.get('workers', {})
cwr = cw.get('resources', {})

extravars = {
    'ansible_operator_meta': {
        'name':      cr['metadata']['name'],
        'namespace': cr['metadata']['namespace'],
    },
    'provider': {
        'api_endpoint':       p.get('apiEndpoint', ''),
        'namespace':          p.get('namespace', ''),
        'credentials_secret': p.get('credentialsSecret', 'hci-provisioner-credentials'),
        'max_pool_size':      p.get('maxPoolSize', 10),
        'gateway': {
            'ip':             pg.get('ip', ''),
            'prefix_length':  pg.get('prefixLength', 24),
            'default_router': pg.get('defaultRouter', '172.16.0.1'),
            'resources': {
                'cpu':                   pgr.get('cpu', 2),
                'memory':                pgr.get('memory', '4Gi'),
                'storage':               pgr.get('storage', '30Gi'),
                'storage_class':         pgr.get('storageClass', 'ocs-storagecluster-ceph-rbd-virtualization'),
                'data_source_name':      pgr.get('dataSourceName', 'centos-stream9'),
                'data_source_namespace': pgr.get('dataSourceNamespace', 'openshift-virtualization-os-images'),
            },
        },
        'networking': {
            'mac_prefix':      pn.get('macPrefix', '52:54:00'),
            'internal_subnet': pn.get('internalSubnet', '192.168.100.0/24'),
        },
    },
    'consumer': {
        'machine_config_pool': c.get('machineConfigPool', 'hci-vm'),
        'networking': {
            'topology':          cn.get('topology', 'direct'),
            'dns_server':        cn.get('dnsServer', ''),
            'internal_network':  cn.get('internalNetwork', ''),
            'internal_gateway':  cn.get('internalGateway', ''),
        },
        'workers': {
            'count':       cw.get('count', 0),
            'name_prefix': cw.get('namePrefix', 'worker-x86'),
            'resources': {
                'cpu':     cwr.get('cpu', 4),
                'memory':  cwr.get('memory', '8Gi'),
                'storage': cwr.get('storage', '50Gi'),
            },
        },
    },
}
print(yaml.dump(extravars, default_flow_style=False))
" > "${RUNNER_DIR}/env/extravars"
else
  echo "==> WARNING: CR ${CR_NAMESPACE}/${CR_NAME} not found — using hardcoded defaults"
  cat > "${RUNNER_DIR}/env/extravars" <<EOF
---
ansible_operator_meta:
  name: hci-workers
  namespace: hci-node-manager
provider:
  api_endpoint: "https://api.hci.example.com:6443"
  namespace: "main-cluster-workers"
  credentials_secret: hci-provisioner-credentials
  max_pool_size: 10
  gateway:
    ip: "172.16.1.100"
    prefix_length: 16
    default_router: "172.16.0.1"
    resources:
      storage_class: "ocs-storagecluster-ceph-rbd-virtualization"
      data_source_name: "centos-stream9"
      data_source_namespace: "openshift-virtualization-os-images"
  networking:
    mac_prefix: "52:54:00"
    internal_subnet: "192.168.100.0/24"
consumer:
  machine_config_pool: hci-vm
  networking:
    topology: direct
    dns_server: "172.16.0.1"
  workers:
    count: 3
    name_prefix: worker-x86
    resources:
      cpu: 4
      memory: "8Gi"
      storage: "50Gi"
EOF
fi

# ── playbook entrypoint ───────────────────────────────────────────────────────
if "${CLEANUP_MODE}"; then
  echo "==> Cleanup mode: simulating CR deletion (hci_consumer_cleanup role)"
  cat > "${RUNNER_DIR}/project/playbook.yml" <<'EOF'
---
- name: WorkerPool cleanup (finalizer / CR deletion)
  hosts: localhost
  gather_facts: false
  roles:
    - role: hci_consumer_cleanup
EOF
else
  cat > "${RUNNER_DIR}/project/playbook.yml" <<'EOF'
---
- name: WorkerPool reconcile
  hosts: localhost
  gather_facts: false
  roles:
    - role: hci_consumer
EOF
fi

# symlink our roles directory into the project
ln -sfn "${SCRIPT_DIR}/roles" "${RUNNER_DIR}/project/roles"

echo "==> Runner directory ready"
echo ""
echo "==> Running hci_consumer role..."
echo ""

ansible-runner run "${RUNNER_DIR}" \
  --playbook playbook.yml \
  --rotate-artifacts 1 \
  -v
