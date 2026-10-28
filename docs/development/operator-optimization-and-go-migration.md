# Operator Optimization and Go Migration Guide

This document captures architectural analysis, performance tuning recommendations for the current Ansible-based operators, and the roadmap for migrating to native Golang operators.

---

## 1. Executive Summary

The Fusion HCI integration currently runs two Ansible-based operators built with the Operator SDK Ansible plugin:
* [`hci-consumer`](../development/operator-build-deploy.md): Watches `WorkerPool` CRs on the main cluster, scales worker VMs on the HCI cluster, and manages node join operations.
* [`hci-provisioner`](../development/operator-build-deploy.md): Watches `WorkerPoolProvisioning` CRs, orchestrating UDN creation, gateway VM deployment, SSH readiness probes, and ignition generation.

While functional and verified end-to-end, the Ansible implementation exhibits latency during state transitions due to synchronous playbook execution and timer-based reconciliation loops.

---

## 2. Immediate Optimizations for Ansible Operators

The following improvements can be implemented directly within the existing Ansible operator architecture without rewriting the codebase in Go.

### 2.1 Enable Event-Driven Dependent Resource Watches

In [`operator/hci-consumer/watches.yaml`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/watches.yaml) and [`operator/hci-provisioner/watches.yaml`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-provisioner/watches.yaml), `watchDependentResources` is currently set to `false`. Reconcile loops rely almost entirely on the timer tick (`reconcilePeriod: 60s`).

**Recommended Configuration**:
```yaml
- version: v1alpha1
  group: hci-integration.openshift.io
  kind: WorkerPool
  role: hci_consumer
  reconcilePeriod: 30s
  manageStatus: false
  watchDependentResources: true
  watchClusterScopedResources: true
  gatheredFacts: false
```

* **Mechanism**: Because `WorkerPoolProvisioning` CRs carry an `ownerReference` pointing to the owning `WorkerPool`, enabling `watchDependentResources: true` triggers an instant reconcile on `WorkerPool` when provisioning step statuses change (e.g. from `Pending` → `InProgress` → `Complete`).
* **Impact**: Eliminates up to 60 seconds of idle wait time when bootstrap completes.

### 2.2 Disable OS Fact Gathering (`gatheredFacts: false`)

Both operators currently set `gatheredFacts: true` in `watches.yaml` solely to obtain `ansible_date_time` timestamps.

* **Problem**: Ansible executes the complete `setup` module inside the container on **every single reconcile cycle**, gathering host/container hardware, network, and disk metrics. This adds **1 to 3 seconds of CPU overhead** per reconcile pass.
* **Fix**: Set `gatheredFacts: false` in `watches.yaml` and generate timestamps on-demand in tasks:
  ```yaml
  lastTransitionTime: "{{ lookup('pipe', 'date -u +%Y-%m-%dT%H:%M:%SZ') }}"
  ```

### 2.3 Cascade Sequential Steps in `advance_steps.yml`

In `hci-provisioner`, each step transition currently terminates the playbook via `ansible.builtin.meta: end_play`. When Step 1 (`UserDefinedNetwork`) completes, the operator waits for the next 60s timer tick before evaluating Step 2 (`GatewayVM`).

* **Fix**: Allow [`advance_steps.yml`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-provisioner/roles/hci_provisioner/tasks/advance_steps.yml) to evaluate downstream steps whose dependencies are immediately met, executing them in the same reconcile pass if no asynchronous external wait is required.
* **Impact**: Shaves 1 to 2 minutes off the initial bootstrap flow.

### 2.4 Server-Side API Filtering in `observe_world.yml`

In [`observe_world.yml`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/roles/hci_consumer/tasks/observe_world.yml), listing all cluster nodes and iterating through pods on cordoned nodes produces multiple sequential API queries.

* **Fix**: Add `label_selectors` directly to `k8s_info` calls so filtering occurs on the Kubernetes API server rather than across large Jinja2 lists in the Ansible runner:
  ```yaml
  - name: "Observe | List pool worker nodes"
    kubernetes.core.k8s_info:
      api_version: v1
      kind: Node
      label_selectors:
        - "node-role.kubernetes.io/{{ consumer.machine_config_pool }}"
    register: _obs_all_nodes
  ```

### 2.5 Operator Runner Environment Tuning

Configure runtime environment variables in [`operator/deploy/base/`](https://github.com/IBM/fusion-hci-integration/tree/main/operator/deploy/base) deployments:
* `WORKERS: "2"` or `MAX_CONCURRENT_RECONCILES: "2"` — Prevents queue blockages across multiple CR events.
* `ANSIBLE_VERBOSITY: "0"` — Reduces runner JSON parsing and disk I/O in the container during steady state.
* `ANSIBLE_RETRY_FILES_ENABLED: "0"` — Disables retry file creation.

---

## 3. Comparison: Ansible vs. Golang Operators

| Metric / Feature | Ansible Operator | Golang Operator (`controller-runtime`) |
|---|---|---|
| **Event Reaction Time** | Seconds (sequential playbook execution) | Milliseconds (informer work queues & event filters) |
| **Memory Footprint** | ~400 MB – 800 MB per pod (`ose-ansible-operator` + Python) | ~30 MB – 60 MB per pod (single static binary) |
| **Sidecar Containers** | Requires 3 containers (`operator`, `csr-approver`, `node-labeler`) | Single container; approver & labeler run as integrated informers |
| **Type Safety** | Runtime YAML string interpretation; Ansible 2.9 quirks | Compile-time Go type safety for KubeVirt, CDI, and OpenShift APIs |
| **Cross-Cluster Auth** | Writes temporary kubeconfig files to `/tmp` per reconcile | In-memory `client.Client` instances with pooled HTTP/2 connections |
| **External Operations** | Python scripts, shell-outs for SSH/SCP | Native Go packages (`golang.org/x/crypto/ssh`, `crypto/ed25519`) |
| **Testing** | Live cluster or bastion runner (`run-local.sh`) | Fast unit/integration tests with `envtest` (no live cluster required) |
| **Ecosystem Support** | Standalone `ansible-operator` binary deprecated in SDK v1.38+ | First-class, standard Kubernetes & OpenShift operator ecosystem |

---

## 4. Golang Operator Migration Blueprint

When migrating to Go, the architecture simplifies into a single controller binary managing multiple controllers and informers:

```
cmd/main.go
├── WorkerPoolReconciler (replaces hci-consumer role)
│   ├── Remote HCI KubeVirt / CDI Client Manager
│   └── Local Node Lifecycle & Drain Manager
├── WorkerPoolProvisioningReconciler (replaces hci-provisioner role)
│   ├── State Machine Engine (UDN -> GatewayVM -> Ignition -> Bootfiles)
│   └── Native SSH/SFTP Client (gateway file transfer & probes)
├── CSRAutoApproverInformer (replaces node-auto-approver.py sidecar)
└── NodeLabelerInformer (replaces node-labeler.py sidecar)
```

### Key Migration Steps

1. **Scaffold Project**:
   * Initialize using `operator-sdk init --plugins=go/v4 --domain=openshift.io`.
   * Create APIs for `WorkerPool` and `WorkerPoolProvisioning`.
2. **Implement Multi-Cluster Client Cache**:
   * Implement a manager that reads the credentials Secret and instantiates/caches a remote `client.Client` using `clientcmd.RESTConfigFromKubeConfig`.
3. **Port Reconciliation Logic**:
   * Use typed KubeVirt (`kubevirt.io/api/core/v1`) and CDI (`cdi.kubevirt.io/v1beta1`) client packages.
   * Replace manual node drain logic with the standard `k8s.io/kubectl/pkg/drain` package.
4. **Integrate Node Manager Sidecars into Informers**:
   * Add a `CertificateSigningRequest` controller that approves kubelet and bootstrap CSRs matching the pool naming pattern.
   * Add a `Node` controller that applies role labels based on internal IP subnet checks.
5. **Multi-Architecture Builds**:
   * Leverage Go cross-compilation (`GOARCH=s390x go build`) to produce LinuxONE binaries directly from standard CI build pipelines.

---

## 5. Trade-offs and Recommendation

* **Trade-offs**: Rewriting in Go requires Go/controller-runtime expertise and an upfront development investment (~20–25 story points), temporarily diverting focus from upcoming functional epics (such as Epic 3: HCI Provider Operator).
* **Recommendation**:
  1. **Phase 1 (Immediate)**: Apply the Ansible optimizations in Section 2 (`watchDependentResources: true`, `gatheredFacts: false`, cascading step execution) to achieve immediate responsiveness gains with minimal effort (~4 points).
  2. **Phase 2 (Production Hardening)**: Transition to Go when preparing for multi-tenant production deployments or publishing to OperatorHub.
