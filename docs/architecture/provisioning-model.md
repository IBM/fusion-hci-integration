# HCI Provisioning Model — Lifecycle Operator Design

## Overview

This document describes the architecture of the **HCI Provisioning Operator** (Epic 2),
which manages the full lifecycle of a consumer relationship: bootstrap (create
infrastructure) and teardown (remove infrastructure) triggered by the `WorkerPool` CR.

The steady-state operator (Epic 1) handles only the continuous worker VM reconcile loop.
It deliberately knows nothing about how the infrastructure was set up. The provisioning
operator is responsible for everything that must exist *before* the steady-state operator
can function, and for removing it when the consumer relationship ends.

---

## Separation of Concerns

The credential scope is the clean discriminant between the two operators:

| Operator | Credential | Scope | Runs |
|----------|-----------|-------|------|
| **HCI Consumer Operator** (Epic 1) | Narrow SA token on HCI — permanent | HCI: `VirtualMachine` + `DataVolume` CRUD in one namespace. LO (in-cluster RBAC): `Node` patch/delete, CSR approve, `MachineConfigPool` + `MachineConfig` get/list/watch/**create** (create-if-absent, BS-02b); SSH key Secret read (for `desired-version.txt` management) | Continuously |
| **HCI Provisioning Operator** (Epic 2) | Broader SA on HCI — permanent for lifecycle ops | HCI: gateway VM + DataVolume, `UserDefinedNetwork`. LO (in-cluster RBAC): `MachineConfig` **read-only** (to read the `99-worker-ssh` key); SSH key Secret create/read | On CR create / delete |

The steady-state operator **never** holds:
- Topology-aware gateway configuration (direct vs mediated branching in cloud-init)
- Knowledge of the gateway VM spec
- `UserDefinedNetwork` or gateway VM permissions on the provider

These belong exclusively to the provisioning operator. `MachineConfigPool` / `MachineConfig`
creation was moved to the consumer operator in BS-02b, because those are consumer-cluster
resources the provisioner has no business owning. Source of truth for permissions:
`operator/deploy/base/rbac.yaml`.

**Design decision — bootfiles version management (BS-06b):**
The `hci_consumer` role owns `desired-version.txt` on the gateway and the
scale-up gate, **not** the provisioning operator. Rationale:
- The consumer runs every reconcile and is the actor that suffers if bootfiles
  are wrong — it is the natural owner of the "are workers bootable?" question.
- The provisioner's responsibility ends when infrastructure is set up. Tracking
  OCP versions post-bootstrap is outside its scope.
- The consumer reads `WorkerPoolProvisioning.status.sshKeySecret` to obtain the SSH
  key name, then uses the provisioner keypair to write `desired-version.txt`
  via SSH. The gateway's `rhcos-sync.timer` handles the download autonomously.
- Scale-up gate: `GET /rhcos/current-version.txt == ClusterVersion.status.desired.version`.
  Non-200 or mismatch → defer scale-up to next reconcile (safe default).
- There is **no `Bootfiles` step in `WorkerPoolProvisioning`** — the provisioner step
  list covers only one-time infrastructure setup.

---

## The `WorkerPoolProvisioning` CRD

The provisioning operator introduces a new CRD: `WorkerPoolProvisioning`. This resource is
created by the `WorkerPool` operator when it detects that provisioning is needed
(gateway VM absent, phase `Pending`). It is the coordination board for all bootstrap
and teardown steps.

```yaml
apiVersion: hci-integration.openshift.io/v1alpha1
kind: WorkerPoolProvisioning
metadata:
  name: hci-workers-bootstrap
  namespace: hci-node-manager
  ownerReferences:
    - apiVersion: hci-integration.openshift.io/v1alpha1
      kind: WorkerPool
      name: hci-workers
      # ownerReference ensures GC when WorkerPool is deleted
spec:
  workerPoolRef: hci-workers
  mode: bootstrap         # bootstrap | teardown
  # providerAccess and infrastructure.{gateway,network,capacity} are copied
  # from WorkerPool.spec.provider / spec.consumer at creation time
status:
  phase: InProgress       # Pending | InProgress | Complete | Failed
  steps:
    - name: GatewayVM
      status: InProgress  # Pending | InProgress | Complete | Failed
      message: "Creating gateway VM and DataVolume on HCI."
    - name: UDN
      status: Pending
    - name: Ignition
      status: Pending
    - name: Credentials
      status: Pending
```

The `ownerReference` to `WorkerPool` means Kubernetes garbage-collects the
`WorkerPoolProvisioning` CR automatically when the `WorkerPool` is deleted.

---

## Step Execution Model

All steps currently run **directly in the Ansible reconcile loop** (`advance_steps.yml`
dispatches to `step_<name>.yml` task files). Each step is idempotent and re-checked on
every reconcile until it reaches a terminal state. The provisioning operator is the
**sole owner of step status**.

!!! note "Job-based steps: designed, not used"
    The original design ran each step as a Kubernetes `Job` owned by the
    `WorkerPoolProvisioning` CR (with ownerReference garbage collection and
    exit-code-driven status). `advance_steps.yml` still contains the Job launcher, but
    its input list is an empty placeholder — no step uses it today. Steps are cheap
    synchronous API calls (or SSH/TCP probes), so the extra Job indirection was not needed.

### Ownership Chain

```
WorkerPool  →owns→  WorkerPoolProvisioning
```

Deleting `WorkerPool` removes `WorkerPoolProvisioning` via Kubernetes garbage collection.

### Status Protocol

| Actor | Transition | Trigger |
|-------|-----------|---------|
| **Provisioning operator** | `Pending → InProgress` | When the step's resources are created (or step re-check starts) |
| **Provisioning operator** | `InProgress → Complete` | Step's completion condition confirmed (e.g. TCP reachability for GatewayVM, resource absent for teardown) |
| **Provisioning operator** | `InProgress → Failed` | Step error, or timeout exceeded (GatewayVM) |
| **Provisioning operator** | `Failed → propagate` | Patches `WorkerPool` phase to `Failed` with message |
| **Provisioning operator** | all `Complete → phase Complete` | Patches `WorkerPool` phase to `Ready` (bootstrap) / `Deprovisioned` (teardown) |

Step results are collected during the reconcile and written to `status.steps` **once**
(consolidated write), because the operator-sdk proxy caches reads for the duration of a
reconcile and per-step writes would clobber each other.

### GatewayVM Step Design

The GatewayVM step is handled directly by the Ansible reconcile loop, **not a Job**.
Rationale: creating three Kubernetes resources on HCI (Secret, DataVolume, VirtualMachine)
is fast and synchronous. The slow part — waiting for the VM to boot and become reachable —
must not block a single reconcile; it is re-observed on every subsequent reconcile until
the VM is up or the timeout expires.

**State machine:**

| State | Condition | Action |
|-------|-----------|--------|
| `Pending` | No gateway VM exists on HCI | Apply cloud-init Secret + DataVolume + VirtualMachine; set step `InProgress` + record `lastTransitionTime` |
| `InProgress` | Resources exist; VM not yet reachable | Check TCP `gateway.external_ip:22`; if open → set `Complete`; if `lastTransitionTime` elapsed > `gateway_vm_timeout_seconds` → set `Failed` |
| `Complete` | SSH port reachable | No-op (terminal) |
| `Failed` | Timeout reached | No-op (terminal); `WorkerPoolProvisioning` phase → `Failed`; `WorkerPool` phase → `Failed` |

**Topology-dependent cloud-init (direct vs mediated):**

| Element | Direct | Mediated |
|---------|--------|----------|
| `route1=` in external nmconnection | absent | `networking.linuxone_network`, `networking.linuxone_gateway` |
| Masquerade exception rules | none | ACCEPT for `linuxone_network` and `gateway.external_subnet` before the catch-all MASQUERADE rule |
| Catch-all MASQUERADE rule | present (all outbound eth1) | present (catches everything not matched by exceptions) |

In direct topology the gateway simply masquerades all outbound traffic from `internal_subnet`
via eth1. In mediated topology worker VM traffic to the s390x cluster network must appear
with its original source IP (transparent routing) — masquerading is suppressed only for
those specific destinations. Both cases use firewalld direct rules with priority 0 (exceptions)
and priority 1 (catch-all MASQUERADE).

**Teardown:** delete VirtualMachine, wait for VMI to disappear (async), delete DataVolume,
delete cloud-init Secret. Set step `Complete` once all three resources are absent.

**Idempotency:** all `kubernetes.core.k8s state: present/absent` calls are idempotent.
If the operator restarts mid-step the resources already exist; re-applying is a no-op.
TCP check resumes on the next reconcile.

**Timeout default:** `gateway_vm_timeout_seconds: 600` (10 minutes). Configurable in
`roles/hci_provisioner/defaults/main.yml`.

### Dependency Graph (bootstrap)

The active bootstrap steps and their dependencies are defined in
`roles/hci_provisioner/defaults/main.yml` (`bootstrap_steps`):

```
UDN ───────────────┐ (parallel, no deps)
GatewayVM ─────────┤
Credentials ───────┘ (no-op, auto-Complete)
        │
        └─ GatewayVM Complete ──→ Ignition
                                       │
                                       ▼  (all Complete)
                               WorkerPool phase = Ready
                                       │
                       (hci_consumer reconcile, every cycle)
                                       ▼
                      desired-version.txt written if drift
                      gateway rhcos-sync.timer downloads
                      scale-up gate: current-version.txt
```

`UDN`, `GatewayVM` and `Credentials` have no dependencies and run in the same reconcile.
`Ignition` waits only on `GatewayVM` (SSH port must be open to distribute the file).
`Credentials` is a placeholder that completes immediately — credential creation is done
by script (BS-05 was descoped). There is no `Bootfiles` step in the provisioner —
bootfiles version management is owned by `hci_consumer` (see design decision above).

!!! info "MachineConfig is a consumer concern"
    The `MachineConfigPool` and `MachineConfig`s are created (if absent) by the
    **`hci_consumer`** role (`ensure_machineconfig.yml`, BS-02b) and the consumer
    gates creation of the `WorkerPoolProvisioning` on the pool being present and not
    `Degraded` (`MachineConfigPoolReady` condition on the `WorkerPool`). The provisioner
    has no visibility into consumer-cluster resources and has no `MachineConfig` step.
    The CRD enum still lists `MachineConfig` and `Bootfiles`, but neither is used.

**GatewayVM does not depend on UDN:** KubeVirt accepts the VirtualMachine object immediately; the NAD is resolved at VMI scheduling time, not at VM object creation time.

**Key insight:** `worker-hci.ign` is generated by rewriting the MCS endpoint in the base `worker-user-data-managed` Secret — that Secret always exists. The `hci-vm` MachineConfig is **not** consulted at ignition generation time; the node only contacts MCS at second boot. The target MCS path `/config/<machineConfigPool>` is taken from `infrastructure.network.machineConfigPool`.

### Dependency Graph (teardown)

```
Ignition, Credentials   →  no deps (no-op, auto-Complete)
GatewayVM               →  no deps  (parallel with Workers)
Workers                 →  no deps  (parallel with GatewayVM)
UDN                     →  GatewayVM + Workers
```

`Workers` (BS-08) lists and deletes all consumer-labelled worker VMs and DataVolumes on
the provider, and confirms them absent before `Complete`. `UDN` must wait for both
`GatewayVM` and `Workers` because worker VMs hold UDN attachments and the UDN controller
finalizer will not complete deletion while any VMI is still attached.
`GatewayVM` and `Workers` teardown each use a re-check loop (`InProgress` → confirmed
absent → `Complete`).

**Consumer cleanup after teardown:** `hci_consumer_cleanup` runs once the
`WorkerPoolProvisioning` teardown is `Complete`. By then all VMs are gone, so it deletes
the corresponding node objects directly (ownership fingerprint: name prefix + MCP role
label) instead of requiring cordon+drain first. This avoids the deadlock that would
otherwise occur because the gateway VM is gone and the nodes go `NotReady`.

### Reconcile Loop (provisioning operator)

```
observe  (observe_world.yml):
  - WorkerPoolProvisioning spec (mode, step list)
  - current step statuses on WorkerPoolProvisioning.status.steps

diff  (diff_steps.yml):
  step Pending + all depends_on Complete           → launch (run the step task file)
  step Pending + dependencies not met              → no-op, wait
  step InProgress                                  → re-check (readiness / absence probe)

act  (advance_steps.yml):
  step results merged into steps[]                 → single consolidated status write
  step probe succeeded                             → set step Complete
  step error / timeout                             → set step Failed, set phase Failed
  all steps Complete                               → set phase Complete
                                                      patch WorkerPool phase Ready
  phase Failed                                     → patch WorkerPool phase Failed
                                                      surface failure message
```

This is a fully stateless, re-entrant reconcile. Every decision is derivable from
observed Kubernetes state — the operator can restart at any point and resume correctly.

---

## WorkerPool Phase State Machine

The `WorkerPool` operator has a top-level phase gate. The worker reconcile loop
only runs when `phase == Ready`.

```
                  CR created
                  credentials Secret present
                  gateway VM absent
                         │
                         ▼
                   [Provisioning]
              operator creates WorkerPoolProvisioning
              (mode=bootstrap)
              worker reconcile: SKIP
                         │
               WorkerPoolProvisioning phase=Complete
                         │
                         ▼
                     [Ready]  ◄──── normal worker reconcile loop
                  (workers.count reconciled continuously)
                         │
                  CR deletion requested
                         │
                         ▼
                  [Deprovisioning]
              operator creates WorkerPoolProvisioning
              (mode=teardown)
              worker reconcile: SKIP
                         │
               WorkerPoolProvisioning phase=Complete
                         │
                         ▼
               finalizer released → CR deleted
```

`Provisioning` and `Deprovisioning` are observable via `oc get workerpool` (or `oc get wp`) — LOOps
and administrators can see exactly where the consumer is in its lifecycle.

---

## Step Implementations

| Step | Mode | Task file | Responsibility | Key assets used |
|------|------|-----------|----------------|-----------------|
| **UDN** | bootstrap / teardown | `step_udn.yml`, `step_udn_teardown.yml` | Pre-flight check that `ClusterUserDefinedNetwork router-external-network` exists; create / delete `UserDefinedNetwork router-internal-network` | `providerAccess.credentialsSecret` kubeconfig |
| **GatewayVM** | bootstrap / teardown | `step_gateway_vm.yml`, `step_gateway_vm_readiness.yml`, `step_gateway_vm_teardown.yml` | Create cloud-init Secret + DataVolume + VirtualMachine; probe SSH; on teardown delete all three | Provider kubeconfig, rendered cloud-init, provisioner SSH key Secret |
| **Ignition** | bootstrap only | `step_ignition.yml` | Rewrite MCS URL in `worker-user-data-managed`, SCP to gateway nginx root | Provisioner SSH key, gateway internal IP |
| **Workers** | teardown only | `step_workers_teardown.yml` | Delete all consumer-labelled worker VMs + DataVolumes on the provider | Provider kubeconfig |
| **Credentials** | both | — | No-op placeholder (auto-Complete) | — |

> **Note:** There is no `Bootfiles` provisioning step. The consumer operator
> owns `desired-version.txt` management and the scale-up gate. See the
> separation of concerns decision above.

---

## Testing Strategy

The per-step design makes isolated testing natural:

1. **Unit test a single step**: create a `WorkerPoolProvisioning` CR with only one step in
   `Pending` and all others `Complete`. Verify the step transitions correctly.
2. **Full bootstrap cycle**: apply `WorkerPool` CR with credentials absent (or gateway
   absent) → observe `WorkerPoolProvisioning` created → observe each step advance → observe
   `WorkerPool` phase reach `Ready` → verify gateway VM running on HCI.
3. **Full teardown cycle**: delete `WorkerPool` CR → observe teardown `WorkerPoolProvisioning`
   created → observe all assets removed → finalizer released.
4. **Create → delete → create**: the canonical idempotency test. Validates that teardown
   leaves the cluster clean enough for a fresh bootstrap.

---

## Implementation Language

The provisioning operator controller is implemented as an **Ansible operator** —
consistent with the steady-state operator and the rest of the project. The reconcile
loop observes the step statuses, runs every step whose dependencies are satisfied, and
writes the merged result once. Steps with no dependency between them run in the same
reconcile pass; long waits (VM boot, resource deletion) are handled by re-checking on
subsequent reconciles rather than blocking.

A migration to native Go operators (which would replace this loop with controller-runtime
reconcilers) is tracked in Epic 6 — see
[Operator Optimization and Go Migration](../development/operator-optimization-and-go-migration.md).

---

## Related Documents

- [Provider/Consumer Model](provider-consumer-model.md)
- [Architecture Overview](architecture-overview.md)

---

**Document Version**: 2.0
**Last Updated**: 2026-10-12
**Status**: Aligned with the implemented operator (verified against `roles/hci_provisioner/defaults/main.yml`, `advance_steps.yml` and the CRDs). Steps run inline in the reconcile loop; MachineConfig handling lives in `hci_consumer`; `Bootfiles` and `Credentials` are not active provisioner steps.
