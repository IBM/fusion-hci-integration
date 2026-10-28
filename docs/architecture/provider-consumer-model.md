# Provider/Consumer Model for HCI Integration

## Overview

This document describes the provider/consumer architecture for the Fusion HCI integration,
inspired by the ODF (OpenShift Data Foundation) Storage Provider/Client model. The goal is
secure, operator-driven lifecycle management for multi-architecture worker nodes: x86 VMs
running on a Fusion HCI cluster join an s390x (LinuxONE) OpenShift cluster as worker nodes.

## Three-Actor Model

The architecture separates concerns across three distinct actors, each with a strictly
limited privilege scope:

```
┌─────────────────────────────────────────────────────────────────┐
│ HCI Cluster (provider)                                          │
│                                                                 │
│  [HCI Provider Operator] — Epic 3, planned                     │
│    Manages: ComputeConsumerRequest, namespaces, quotas,         │
│    onboarding tickets                                           │
└─────────────────────────────────────────────────────────────────┘
                  │ one-time ticket (24h, elevated) — Epic 3 future
                  ▼
┌─────────────────────────────────────────────────────────────────┐
│ Main (LO) Cluster                                               │
│                                                                 │
│  [HCI Provisioning Operator] — Epic 2, COMPLETE ✅             │
│    Drives WorkerPoolProvisioning CR steps: UDN, GatewayVM,     │
│    Credentials, Ignition, MachineConfig (bootstrap + teardown). │
│    Bootstrap and teardown confirmed end-to-end on live clusters.│
│                                                                 │
│  [HCI Consumer Operator] — Epic 1, COMPLETE ✅                 │
│    Permanent. Reconciles WorkerPool CR → HCI worker VMs.       │
│    Creates WorkerPoolProvisioning CRs on bootstrap/teardown.   │
│    Worker scale-up/scale-down confirmed on live clusters.       │
└─────────────────────────────────────────────────────────────────┘
```

**Key privilege-separation principle**: the steady-state operator (which runs forever) never
holds the elevated bootstrap credentials. The ticket exists only for the lifetime of the
one-shot Bootstrap Job.

## Implemented: LO Steady-State Operator

### WorkerPool CRD

The `WorkerPool` custom resource is the single control surface for the steady-state
operator. It is installed on the main (LO) cluster.

**API group**: `hci-integration.openshift.io/v1alpha1`
**Short name**: `wp`
**Namespace-scoped**

```yaml
apiVersion: hci-integration.openshift.io/v1alpha1
kind: WorkerPool
metadata:
  name: hci-workers
  namespace: hci-node-manager
spec:
  provider:
    apiEndpoint: "https://api.hci.example.com:6443"
    namespace: "main-cluster-workers"
    credentialsSecret: hci-provisioner-credentials
    maxPoolSize: 10
    gateway:
      ip: "172.16.1.100"
      prefixLength: 16
      defaultRouter: "172.16.0.1"
    networking:
      macPrefix: "52:54:01"
      internalSubnet: "192.168.100.0/24"

  consumer:
    networking:
      topology: direct    # or: mediated
      dnsServer: "172.16.0.1"
    workers:
      namePrefix: worker-x86
      count: 3          # desired number of HCI worker VMs / LO nodes
    machineConfigPool: hci-vm

status:
  phase: Ready          # Provisioning | Ready | Deprovisioning | Failed
  conditions:
    - type: ProviderCredentialsReady
      status: "True"
      reason: SecretFound
      message: "Provider credentials Secret found."
    - type: ScaleDownBlocked
      status: "False"
      reason: NoPendingDrain
      message: "No scale-down blocked."
    - type: CountExceedsMaxPoolSize
      status: "False"
      reason: CountWithinBounds
      message: "workers.count is within maxPoolSize."
```

### Reconciliation Logic

The operator follows a strict **observe → diff → act** pattern:

1. **Observe** (`observe_world.yml`): reads the credentials Secret, lists all
   operator-owned VMs on HCI (by label), lists all matching nodes on the LO cluster,
   determines which nodes are Ready (have kubelet running). Zero decisions.

2. **Diff** (`diff_desired_actual.yml`): pure set arithmetic.
   - Computes `vms_to_create` = indices in `1..count` not covered by an existing VM
   - Computes `vms_to_delete` = existing VMs whose node is NotReady, capped at `surplus`
   - Applies `maxPoolSize` clamping with a `CountExceedsMaxPoolSize` condition

3. **Act** (`scale_up.yml`, `scale_down.yml`):
   - Scale-up: create DataVolume + VirtualMachine on HCI for each missing name
   - Scale-down: delete node object (LO) → delete VM (HCI) → delete DataVolume (HCI)

**Scale-down safety gate**: a VM is only eligible for deletion when its corresponding
node's Ready condition is not `True` (kubelet has stopped). LOOps stops the VM it wants
to remove; the operator observes the NotReady state and acts. No operator-side drain.
The `ScaleDownBlocked` condition is set when `workers.count` is reduced but no NotReady
node is yet available.

### Complementary Component: hci-node-manager

The node manager runs as sidecar containers (`csr-approver`, `node-labeler`) inside the
`hci-consumer-operator` Deployment. Responsibilities are strictly separated:

| Component | Responsibility |
|-----------|----------------|
| **hci-consumer operator** | VM lifecycle: create, delete DataVolume + VM on HCI |
| **hci-node-manager sidecars** | Node join: CSR approval + node labeling (stream-watch, ms reaction time) |

`hci-node-manager` owns the time-critical node-join path. The `hci-vm` role label must
arrive before MCO renders ignition for the node — a polling-based operator cannot meet
this window. The two components have non-overlapping responsibilities.

### RBAC

The operator ServiceAccount (`config/rbac/role.yaml`) has minimal permissions on the
main cluster only:

- **Nodes**: `get`, `list`, `watch`, `patch`, `update` (for labeling and deletion)
- **CertificateSigningRequests**: `get`, `list`, `watch`, `update` (for CSR approval, delegated to hci-node-manager)
- **MachineConfigPools**: `get`, `list`, `watch`
- **Pods**: `get`, `list` (for eviction check, future LO-09/LO-10)

HCI cluster access is via the narrow kubeconfig Secret (namespace-scoped to the consumer
namespace on HCI, VirtualMachine/DataVolume/PVC write + Secret/ConfigMap read only).

---

## Implemented: HCI Provisioning Operator (Epic 2)

A dedicated operator managing the full infrastructure lifecycle via the `WorkerPoolProvisioning`
CRD. Triggered by the `WorkerPool` operator when bootstrap or teardown is needed.
See [`provisioning-model.md`](provisioning-model.md) for the complete design.

**Key design principle**: the credential scope is the discriminant between the two operators.
The steady-state operator holds only a narrow SA token scoped to one HCI namespace.
The provisioning operator holds broader credentials: `MachineConfig` write on LO,
SSH key access, topology awareness. These never cross the operator boundary.

**`WorkerPool` phase state machine**:
- `Provisioning` — `WorkerPoolProvisioning` (mode=bootstrap) in progress; worker reconcile skipped
- `Ready` — all bootstrap steps complete; worker reconcile runs normally
- `Deprovisioning` — `WorkerPoolProvisioning` (mode=teardown) in progress; worker reconcile skipped

**Step execution model**: each bootstrap/teardown step is a Kubernetes Job owned by the
`WorkerPoolProvisioning` CR (via `ownerReference`). The provisioning operator watches Job
termination status and owns all `status.steps` transitions. Jobs are garbage-collected
automatically when the `WorkerPoolProvisioning` CR is deleted.

**Credentials handover**: BS-05 (automated SA/Secret creation) was descoped; credentials are
created with a script. The Secret is referenced by name in
`WorkerPool.spec.provider.credentialsSecret`.

---

## Planned: HCI Provider Operator (Epic 3)

Runs on the HCI cluster. Automates what the HCI admin currently does manually.

**Responsibilities** (not yet implemented):
1. Watch `ComputeConsumerRequest` CRDs — process consumer onboarding requests
2. Provision consumer namespace, CUDN label, ResourceQuota on HCI
3. Generate onboarding ticket: privileged bootstrap ServiceAccount + time-limited token
4. Surface ticket in a Secret for the HCI admin to hand to the LO team
5. Monitor quota usage per consumer

---

## Deferred: Negotiation Flow (Epic 4)

LO-initiated cross-cluster capacity requests. Design open — chicken-and-egg discovery
problem (how does LO know the HCI API endpoint before any credentials exist?). Deferred
to iteration 2. See the project operator backlog for NEG-01/02/03 story descriptions.

---

## Credentials Deployment

The one-time cross-domain credentials handover is done by script, run from the repo root
with `setup_env.sh` sourced. See [Getting Started](../getting-started.md) (steps B.2 and C.8)
for the authoritative procedure.

```bash
# On the HCI cluster (cluster-admin required once)
./hci-cluster/setup-consumer-rbac.sh
# Script prints the oc create secret command to run on the LO bastion

# Or create the operator Secrets directly (both clusters logged in)
./operator/setup-provider-credentials.sh
```

These create, in the consumer namespace on HCI:
- ServiceAccount(s), a namespace-scoped Role (VM, DataVolume, PVC write; Secret/ConfigMap read) and RoleBinding
- A 1-year ServiceAccount token, written as a kubeconfig Secret on the LO cluster

The Secret name is referenced by `WorkerPool.spec.provider.credentialsSecret`
(CRD default: `hci-provisioner-credentials`).

!!! warning "Open inconsistency"
    The two scripts and the operator defaults do not agree on the Secret layout:
    `setup-consumer-rbac.sh` prints `hci-provider-credentials`;
    `setup-provider-credentials.sh` writes two Secrets (`hci-provider-credentials`
    and `hci-provisioner-credentials`); the CRD and role defaults use
    `hci-provisioner-credentials` only. To be resolved as part of the setup rework.

---

## Security Model

### Credential Lifecycle

| Credential | Lifetime | Scope | Holder |
|-----------|---------|-------|--------|
| Onboarding ticket | 24h (planned) | Create ComputeConsumerBinding on HCI | Bootstrap Job only |
| Narrow SA token | 1 year (manual) / 10 years (planned) | Consumer namespace on HCI: VM/DV/PVC write | Steady-state operator |
| Cluster admin | Permanent | HCI admin workstation | HCI admin only — never in-cluster |

### What the Steady-State Operator Can and Cannot Do on HCI

The operator's kubeconfig is scoped to one namespace (e.g. `main-cluster-workers`) and can:
- Create / delete `VirtualMachine` and `VirtualMachineInstance`
- Create / delete `DataVolume` and `PersistentVolumeClaim`
- Read `Secret` and `ConfigMap`

It **cannot**:
- Access any other namespace on HCI
- Create namespaces, RBAC, or network resources
- Approve CSRs or label nodes on HCI

---

## Related Documents

- [Architecture Overview](architecture-overview.md)

---

**Document Version**: 2.2
**Last Updated**: 2026-10-12
**Status**: Updated to current CRD names (`WorkerPool`, `WorkerPoolProvisioning`). Epics 1 and 2 complete. Epics 3–4 described as planned.
