# hci-consumer operator — development README

## Development Environment

The operator runs on the main (LO) cluster, which is a s390x cluster only reachable
via a SOCKS proxy. The Python `kubernetes` SDK does not reliably honour proxy settings,
which makes running `ansible-runner` from a local x86 workstation impractical.

**Development target: the cluster's bastion host.**

The bastion has direct network access to the cluster API and a native s390x environment,
which also avoids any cross-architecture image build concerns.

## Prerequisites on the Bastion Host

```bash
# Python venv
# Use python3.11 explicitly — it is pre-installed alongside the system python (3.9.x).
# --system-site-packages is required: it makes system-level packages (e.g. the
# pre-installed openshift/kubernetes bindings) visible inside the venv.
python3.11 -m venv --system-site-packages ~/ansible-operator-venv
source ~/ansible-operator-venv/bin/activate

# Core dependencies
pip install ansible-runner kubernetes openshift

# Ansible collections
# Note: install via requirements.yml is preferred (versions are pinned there).
# If installing individually, pin redhat.openshift to a stable release —
# newer versions on Galaxy are pre-releases and are silently skipped otherwise.
# MKS: I am not sure if this is really useful. If I just install the above pips,
# the ansible-runner in the run-local.sh script seems to work.
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install 'redhat.openshift:==2.3.0'
ansible-galaxy collection install operator_sdk.util
```

Verify cluster access from the bastion:

```bash
oc whoami
oc get nodes
```

## Credentials Setup

The operator accesses the HCI cluster via a kubeconfig stored in a Kubernetes Secret.
A helper script is provided to create the ServiceAccount and credentials on the HCI side:

```bash
# On the HCI cluster (cluster-admin required once)
cd hci-cluster/
./setup-consumer-rbac.sh
# Follow the printed instructions to create the Secret on the LO bastion
```

The ServiceAccount is namespace-scoped to the consumer namespace on HCI (e.g.
`main-cluster-workers`). It has write access to VirtualMachines, DataVolumes, PVCs, and
read access to Secrets/ConfigMaps — no cluster-admin.

## Development Workflow

### Getting code to the bastion

The cleanest approach is small, frequent git commits pushed to the feature branch,
pulled on the bastion:

```bash
# On workstation — commit and push after each meaningful change
git add operator/hci-consumer/
git commit -m "hci-consumer: <what changed>"
git push origin feature/operator-architecture

# On bastion — pull and run
git pull origin feature/operator-architecture
```

To reduce friction, keep commits small and focused — one role task change per commit
is fine during active development. The commit message is your change log.

### Running the role with ansible-runner

`ansible-runner` requires a specific project directory layout. A helper script is
provided to set it up and invoke the run:

```bash
cd ~/fusion-hci-integration/operator/hci-consumer
./run-local.sh
```

The script reads the live `HCIConsumer` CR from the cluster and uses its spec as
extravars, so the local run mirrors exactly what the operator would see. If the CR
is not found it falls back to hardcoded defaults.

To simulate CR deletion (test the finalizer / cleanup path):

```bash
./run-local.sh --cleanup
```

> **Namespace**: the operator runs in the `hci-node-manager` namespace — the same
> namespace where the existing `hci-node-manager` Deployment lives. The operator
> is the eventual successor to that Deployment for VM lifecycle management.

### Forcing a re-run

`ansible-runner` caches artifacts. Use `--rotate-artifacts 1` (already the default in
`run-local.sh`) to always get fresh output, or delete the artifacts directory:

```bash
rm -rf ~/tmp/hci-consumer-run/artifacts
./run-local.sh
```

### Watching operator output

When the full operator loop is running (future: via the operator-sdk container),
tail the runner log:

```bash
tail -f ~/tmp/hci-consumer-run/artifacts/*/stdout
```

## Reconciliation Model

The operator follows a strict **observe → diff → act** pattern:

1. **`observe_world.yml`** — all API calls. Produces `existing_vm_names`,
   `existing_node_names`, `nodes_with_workload`, and drift sets. No decisions made.
2. **`diff_desired_actual.yml`** — pure set arithmetic. Zero API calls. Produces
   `vms_to_create`, `vms_to_delete`, `vms_blocked`. Applies `maxPoolSize` clamping.
3. **`scale_up.yml`** / **`scale_down.yml`** — thin loops over the action lists.

Scale-down is gated on the node's Ready condition — VMs whose node is still Ready are
never deleted. LOOps cordons/stops the node; the operator acts when the node goes
NotReady. The `ScaleDownBlocked` condition is set on the CR when a surplus exists but
no NotReady node is available.

The cleanup role (`hci_consumer_cleanup`) reuses `observe_world.yml` directly and
targets zero VMs. It blocks finalizer removal if any node still has workload pods.

## Directory Structure

```
operator/hci-consumer/
├── watches.yaml                          # CR kind → Ansible role mapping
├── requirements.yml                      # Ansible collection dependencies
├── run-local.sh                          # Helper: sets up runner dir, syncs from live CR
├── create-provider-credentials.sh        # Helper: create hci-provider-credentials Secret
├── README.md                             # This file
├── config/
│   ├── crd/
│   │   └── hciconsumer.yaml              # HCIConsumer CRD (LO-01)
│   ├── rbac/
│   │   └── role.yaml                     # ClusterRole + ClusterRoleBinding (LO-08)
│   └── samples/
│       └── hciconsumer-sample.yaml       # Example CR
└── roles/
    ├── hci_consumer/                     # Main reconciliation role
    │   ├── defaults/
    │   │   └── main.yml                  # Default variable values
    │   └── tasks/
    │       ├── main.yml                  # Entry point — observe → diff → act
    │       ├── observe_world.yml         # OBSERVE: all API calls, world-state facts
    │       ├── diff_desired_actual.yml   # DIFF: set arithmetic, action lists
    │       ├── scale_up.yml              # ACT: loop over vms_to_create
    │       ├── scale_down.yml            # ACT: loop over vms_to_delete, set conditions
    │       ├── create_worker_vm.yml      # Create DataVolume + VirtualMachine on HCI
    │       └── remove_worker_vm.yml      # Delete node → VM → DataVolume
    └── hci_consumer_cleanup/             # Deletion / finalizer role
        ├── defaults/
        │   └── main.yml
        └── tasks/
            └── main.yml                  # Observe + delete all owned VMs; block if drained
```

## Story Status

| Story | Description                              | Status      |
|-------|------------------------------------------|-------------|
| LO-01 | HCIConsumer CRD                          | ✅ Done      |
| LO-02 | Operator scaffold + watches              | ✅ Done      |
| LO-03 | Scale-up: create worker VMs on HCI       | ✅ Done      |
| LO-04 | CSR approval                             | ⛔ Descoped  |
| LO-05 | Node labeling                            | ⛔ Descoped  |
| LO-06 | Scale-down: cordon-gate → delete VM      | ✅ Done      |
| LO-07 | Status reporting                         | ⚙️ Partial   |
| LO-08 | RBAC                                     | ✅ Done      |
| LO-09 | Scale-down: suppress during MCP rollout  | 🔲 TODO      |
| LO-10 | Protect nodes with local-storage workload| 🔲 TODO      |

**LO-04/05 descoped**: `hci-node-manager` runs alongside the operator as a permanent
stream-watch Deployment and owns CSR approval and node labeling. The operator's
polling-based reconcile cannot meet the timing window (label must arrive before MCO
renders ignition for the `hci-vm` MachineConfigPool). The two components have
complementary, non-overlapping responsibilities.

## Key Variables (injected by operator runner)

| Variable | Source | Description |
|----------|--------|-------------|
| `ansible_operator_meta.name` | Runner | CR `metadata.name` |
| `ansible_operator_meta.namespace` | Runner | CR `metadata.namespace` |
| `provider.credentials_secret` | CR spec | Name of kubeconfig Secret |
| `provider.namespace` | CR spec | Namespace on HCI cluster |
| `provider.api_endpoint` | CR spec | HCI API server URL |
| `provider.max_pool_size` | CR spec | Maximum allowed VMs |
| `networking.topology` | CR spec | `direct` or `mediated` |
| `networking.mac_prefix` | CR spec | MAC address prefix |
| `networking.internal_subnet` | CR spec | Worker/gateway internal CIDR |
| `gateway.external_ip` | CR spec | Gateway external IP |
| `gateway.resources.{cpu,memory,storage}` | CR spec / defaults | Gateway VM sizing |
| `workers.name_prefix` | CR spec | VM name prefix (`worker-x86`) |
| `workers.count` | CR spec | Desired number of VMs |
| `workers.resources.{cpu,memory,storage}` | CR spec / defaults | Per-VM resource requests |
