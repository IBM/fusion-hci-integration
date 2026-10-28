# Operator Roadmap

This document describes the vision and implementation plan for the Kubernetes Operator that
manages the Fusion HCI multi-architecture integration. For the three-actor model see
[provider-consumer-model.md](../architecture/provider-consumer-model.md).

## Current State

**Implementation**: Ansible Operator (operator-sdk Ansible plugin)  
**Language**: Ansible (roles, tasks) + Jinja2  
**Operator directories**: `operator/hci-consumer/`, `operator/hci-provisioner/`

### What Is Implemented

#### Epic 1 — Worker Steady-State Operator (`hci-consumer`)

The core reconcile loop is **fully implemented and confirmed e2e on a live test cluster pair**:

| Component | File | Status |
|-----------|------|--------|
| `WorkerPool` CRD (`hci-integration.openshift.io/v1alpha1`) | `config/crd/workerpool.yaml` | ✅ Done |
| Operator scaffold: `watches.yaml`, `requirements.yml` | `operator/hci-consumer/` | ✅ Done |
| RBAC: minimal-permission ServiceAccount | `config/rbac/role.yaml` | ✅ Done |
| Observe phase: world-state fact gathering | `roles/hci_consumer/tasks/observe_world.yml` | ✅ Done |
| Diff phase: set arithmetic, action lists | `roles/hci_consumer/tasks/diff_desired_actual.yml` | ✅ Done |
| Scale-up: create DataVolume + VM on HCI | `roles/hci_consumer/tasks/create_worker_vm.yml` | ✅ Done |
| Scale-down: cordon + drain gate → delete node → delete VM | `roles/hci_consumer/tasks/scale_down.yml` | ✅ Done |
| Scale-down: protect nodes with local-storage annotation | `roles/hci_consumer/tasks/observe_world.yml` | ✅ Done |
| Cleanup / finalizer role | `roles/hci_consumer_cleanup/tasks/main.yml` | ✅ Done |
| `maxPoolSize` CEL admission rule on CRD | `config/crd/workerpool.yaml` | ✅ Done |
| Status conditions: `ProviderCredentialsReady`, `ScaleDownBlocked`, `CountExceedsMaxPoolSize` | `roles/hci_consumer/tasks/` | ✅ Done |
| Status counts: `deployedWorkers`, `readyWorkers`, `pendingWorkers` | `roles/hci_consumer/tasks/main.yml` | ✅ Done |
| Phase sub-states: `ScalingUp`, `ScalingDown`, `ScalingDownBlocked`, `Ready`, `Deprovisioned` | `roles/hci_consumer/tasks/main.yml` | ✅ Done |
| Bootfiles version gate (`sync_bootfiles_version.yml`) | `roles/hci_consumer/tasks/sync_bootfiles_version.yml` | ✅ Done |
| Development helper: `run-local.sh` | `operator/hci-consumer/run-local.sh` | ✅ Done |

#### Epic 2 — HCI Provisioning Operator (`hci-provisioner`)

Full bootstrap and teardown lifecycle via `WorkerPoolProvisioning` CRD:

| Component | File | Status |
|-----------|------|--------|
| `WorkerPoolProvisioning` CRD (`wpp`) | `config/crd/workerpoolprovisioning.yaml` | ✅ Done |
| Operator scaffold: `watches.yaml`, `requirements.yml` | `operator/hci-provisioner/` | ✅ Done |
| Step: validate MachineConfigPool on consumer cluster | `roles/hci_provisioner/tasks/step_machineconfig.yml` | ✅ Done |
| Step: create `UserDefinedNetwork` on HCI (+ teardown) | `roles/hci_provisioner/tasks/step_udn.yml` | ✅ Done |
| Step: deploy gateway VM + DataVolume on HCI (+ teardown) | `roles/hci_provisioner/tasks/step_gateway_vm.yml` | ✅ Done |
| Gateway VM readiness probe (SSH) | `roles/hci_provisioner/tasks/step_gateway_vm_readiness.yml` | ✅ Done |
| Step: generate + SCP ignition to gateway | `roles/hci_provisioner/tasks/step_ignition.yml` | ✅ Done |
| Step: teardown all consumer worker VMs before UDN teardown | `roles/hci_provisioner/tasks/step_workers_teardown.yml` | ✅ Done |
| Provisioner SSH key management | `roles/hci_provisioner/tasks/ensure_provisioner_ssh_key.yml` | ✅ Done |
| Gateway VM cloud-init template | `roles/hci_provisioner/templates/gateway-vm-cloudinit.j2` | ✅ Done |
| Cleanup / finalizer role | `roles/hci_provisioner_cleanup/tasks/main.yml` | ✅ Done |
| SA credential setup script (manual) | `operator/setup-provider-credentials.sh` | ✅ Done |
| Development helper: `run-local.sh` | `operator/hci-provisioner/run-local.sh` | ✅ Done |

### What Is Not Yet Implemented

| Epic | What | Stories |
|------|------|---------|
| Epic 2 remaining | MachineConfig setup scripting for LinuxONE admin | BS-02b |
| Epic 2 remaining | Optional: image registry mirror configuration | BS-07 |
| Epic 3 | HCI Provider Operator | HCI-01 to HCI-05 |
| Epic 4 | Negotiation flow (LO-initiated requests) | NEG-01 to NEG-03 |

---

## Vision

**Goal**: Fully automated, declarative lifecycle management of multi-architecture worker nodes.

An operator administrator applies one `WorkerPool` CR; the system:
1. Provisions UDN, gateway VM, and ignition via the `hci-provisioner` operator (Bootstrap)
2. Continuously reconciles `workers.count` → VMs on HCI and nodes on the LO cluster (Steady-state)
3. Handles scale-up and scale-down safely, with drain timing controlled by LOOps
4. Tears down all infrastructure cleanly on CR deletion

HCI-side provisioning (namespace, network, quota, ticket generation) will be automated by
the HCI Provider Operator (Epic 3, future work).

**Target Users**: Platform administrators, SREs, DevOps teams  
**Key Principles**: Declarative, self-healing, observable, privilege-minimal

---

## Framework and Technology Choices

### Operator Framework

**Choice**: Ansible Operator (operator-sdk Ansible plugin)

**Rationale**:
- Most of the existing integration work already uses Ansible and `kubernetes.core` modules
- Ansible roles map directly to the observe/diff/act reconcile structure
- Low barrier to contribution from the existing team
- Excellent `kubernetes.core.k8s` and `k8s_info` modules for both clusters
- No Go cross-compilation concern for s390x (runs on bastion natively)

**`ansible-operator` binary**: standalone download removed in operator-sdk v1.38+.
Development uses `ansible-runner` directly on the cluster bastion.

*Note*: For performance tuning recommendations and the planned roadmap to migrate to native Golang operators, see [Operator Optimization and Go Migration Guide](operator-optimization-and-go-migration.md).

### Cross-Cluster Communication

**Choice**: Direct API calls with kubeconfig (stored as Kubernetes Secret)

**Rationale**: Simple, standard, no additional infrastructure. The kubeconfig is written
to a temp file per reconcile and cleaned up after. The namespace-scoped SA limits blast radius.

### CRD API Group

**Choice**: `hci-integration.openshift.io`

Used for `WorkerPool`, `WorkerPoolProvisioning`, and all future CRDs in this project.

---

## Implementation Phases

### Phase 1 — Steady-State Core ✅ COMPLETE

**Delivered**:
- `WorkerPool` CRD with CEL admission validation
- Observe/diff/act reconcile loop
- Scale-up and scale-down with set-difference logic (gap-fill correct)
- `ScaleDownBlocked` + `CountExceedsMaxPoolSize` + `ProviderCredentialsReady` conditions
- Status counts: `deployedWorkers`, `readyWorkers`, `pendingWorkers`
- Phase sub-states: `ScalingUp`, `ScalingDown`, `ScalingDownBlocked`, `Ready`, `Deprovisioned`
- Drain gate: cordon + no non-system pods before VM deletion
- Local-storage node protection via annotation
- Finalizer/cleanup role with workload-safety gate
- Minimal RBAC ServiceAccount
- Bastion-based dev workflow with `run-local.sh`

**Confirmed e2e on a live test cluster pair:** full lifecycle
(create → scale-up → scale-down → delete) verified including status counts and phase transitions.

### Phase 2 — Bootstrap Operator (Epic 2) ✅ LARGELY COMPLETE

**Delivered**:
- `WorkerPoolProvisioning` CRD with step-based state machine (`wpp`)
- `WorkerPool` CRD split into `spec.provider` + `spec.consumer` (BS-00b refactor)
- UDN step: create/delete `UserDefinedNetwork router-internal-network` on HCI (BS-03)
- Gateway VM step: full cloud-init stack (DHCP, PXE/iPXE, nginx, ignition, RHCOS sync) (BS-04)
- Ignition step: generate worker-hci.ign, SCP to gateway nginx root (BS-06a)
- Bootfiles version gate: `desired-version.txt` drift detection, scale-up gate (BS-06b)
- MachineConfig step: validate MachineConfigPool exists and is healthy (BS-02)
- Workers teardown step: delete all consumer VMs before UDN teardown (BS-08)
- Single credential secret (`hci-provisioner-credentials`) via `setup-provider-credentials.sh`
- BS-05 deliberately descoped: manual script remains the documented handover tool

**Confirmed e2e**: apply one `WorkerPool` CR → gateway provisions → workers PXE-boot and
join cluster → scale up/down → delete CR → full teardown. See `CURRENT-STATUS.md`.

**Remaining**:
- [ ] BS-02b: Parameterised MachineConfig setup script for LinuxONE admin
- [ ] BS-07: Optional image registry mirror (`ImageContentSourcePolicy`)

### Phase 3 — HCI Provider Operator (Epic 3)

**Goal**: Remove the last manual step — HCI admin no longer needs to run scripts.

**Deliverables**:
- [ ] HCI-01: `ComputeConsumerRequest` + `ComputeConsumerOrder` CRDs on HCI
- [ ] HCI-02: HCI Provider Operator scaffold + watches
- [ ] HCI-03: Process Order: namespace + CUDN label + ResourceQuota
- [ ] HCI-04: Generate onboarding ticket (privileged bootstrap SA + time-limited token)
- [ ] HCI-05: Quota enforcement and usage monitoring

### Phase 4 — Negotiation Flow (Epic 4, Deferred)

**Goal**: LO-initiated requests — no out-of-band communication needed.

Design open. Requires a solution to the bootstrap discovery problem before stories can
start. Deferred to iteration 2.

---

## Demo Milestones

| Milestone | Status | What it shows |
|-----------|--------|---------------|
| **Demo 1 — Core loop** | ✅ DONE | Change `workers.count` → VMs appear/disappear on HCI, nodes join/leave LO cluster. Credentials placed manually. |
| **Demo 1b — Provisioned MVP** | ✅ DONE | Apply one `WorkerPool` CR → gateway VM boots with full PXE stack, bootfiles version gate, workers PXE-boot and join cluster. Scale up/down works end-to-end. |
| **Demo 3 — Both operators** | 🔲 Phase 3 | HCI admin approves request → full two-cluster automated provisioning. |
| **Demo 4 — Self-service** | 🔲 Phase 4 | LOOps submits request, no out-of-band communication. |

---

## Contributing

### Development Setup (Bastion-Based)

```bash
# On the cluster bastion
git clone https://github.com/IBM/fusion-hci-integration
cd fusion-hci-integration

python3.11 -m venv --system-site-packages ~/ansible-operator-venv
source ~/ansible-operator-venv/bin/activate
pip install ansible-runner kubernetes openshift
ansible-galaxy collection install kubernetes.core redhat.openshift operator_sdk.util

# Consumer operator
cd operator/hci-consumer
./run-local.sh          # normal reconcile
./run-local.sh --cleanup  # simulate CR deletion

# Provisioner operator
cd operator/hci-provisioner
./run-local.sh          # normal reconcile
./run-local.sh --cleanup  # simulate CR deletion
```

See `operator/hci-consumer/README.md` for the full development guide.

### Code Standards

- Ansible tasks: one logical step per task, descriptive `name:` field
- All API calls in `observe_world.yml` — zero API calls in diff or act files
- Conditions set/cleared symmetrically — every `True` has a paired `False` path
- Use `set_fact` for computed values; never compute inline in `when:` guards
- YAML strings: avoid backslash in `>-` blocks (use character classes like `([.]|$)`)

---

## References

- [Provider/Consumer Model](../architecture/provider-consumer-model.md)
- [operator-sdk Ansible plugin](https://sdk.operatorframework.io/docs/building-operators/ansible/)
- [kubernetes.core collection](https://docs.ansible.com/ansible/latest/collections/kubernetes/core/)
