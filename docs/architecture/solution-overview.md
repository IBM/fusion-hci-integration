# Solution Overview

A generic, architecture-level map of the core concepts and components.
No cluster names, IP addresses, or low-level configuration details.

---

## 1 · Problem This Solves

Two independently managed OpenShift clusters — each running a different CPU architecture — are combined into a single, unified cluster. Worker nodes are sourced as virtual machines from one cluster and automatically joined to the other as fully managed, architecture-aware workers.

The integration is fully **declarative**: an administrator describes the desired number of workers in a single Custom Resource; all infrastructure provisioning and lifecycle management flows from that intent.

---

## 2 · The Two Clusters

| | Main Cluster | HCI Cluster |
|---|---|---|
| **Role** | Destination cluster. Runs the control plane and native worker nodes. Extended with additional architecture workers sourced from the HCI cluster. | Infrastructure source cluster. Runs OpenShift Virtualization and hosts the Gateway VM and all Worker VMs. |
| **Requirements** | OpenShift 4.20+ with multi-architecture enabled. Separate **MachineConfigPool** for HCI-sourced workers. | OpenShift 4.20+ with OpenShift Virtualization. Shared storage for VM boot volumes. |

---

## 3 · Core Infrastructure Components

### Gateway VM

A dedicated virtual machine that acts as the network bridge between the two clusters. It is automatically created and managed by the provisioning operator and provides:

- **IP routing** — forwards traffic between the isolated worker network and the main cluster
- **Selective NAT** — masquerades traffic depending on destination (topology-dependent)
- **DHCP** — static reservations (MAC, IP, hostname) for the worker VMs
- **Network boot** — iPXE: loader via TFTP, boot script, RHCOS files and ignition via HTTP
- **DNS forwarding** — resolves main-cluster hostnames for workers

### Worker VMs

RHCOS virtual machines created on the HCI cluster. They boot via iPXE from the gateway VM, install RHCOS from an ignition configuration, then join the main cluster as worker nodes. Fully managed by the consumer operator (scale up / scale down).

### Dual OVN Networks

Two logical networks back the integration. They differ in scope:

- **External network** (localnet) — maps to the physical underlay and carries the gateway VM's external interface. It is a cluster-scoped `ClusterUserDefinedNetwork` that exists **once per HCI cluster** and is shared by all integrations. It is created by the HCI cluster admin as part of the one-time cluster setup; each integration namespace gets access to it through the label `hci-gateway-enabled=true`.
- **Internal network** (Layer 2 OVN overlay) — the isolated worker network. It is a namespace-scoped `UserDefinedNetwork` created **per main-cluster integration**, in that integration's namespace, with its own subnet (`provider.networking.internalSubnet`). The provisioning operator creates it during bootstrap and removes it on teardown.

---

## 4 · The Three-Operator Model

The solution is decomposed into three operators with separate responsibilities. Each operator handles one phase of the lifecycle.

| Operator | Runs on | Responsibility | Status |
|---|---|---|---|
| **HCI Consumer Operator** | Main cluster | Steady-state worker lifecycle: scale VMs up/down, cordon/drain before removal. | ✅ Complete |
| **HCI Provisioning Operator** | Main cluster | Infrastructure bootstrap & teardown: creates the UDN and Gateway VM, generates the provisioner SSH key and distributes ignition to the gateway. | ✅ Complete |
| **HCI Provider Operator** | HCI cluster | HCI-side namespace & quota provisioning; generates time-limited onboarding tickets for new consumers. | 🗓 Planned |

!!! note "Supporting Component: HCI Node Manager"
    A lightweight permanent process (not an operator) running on the main cluster. Uses a stream-watch (millisecond reaction time) to handle two time-sensitive operations that cannot wait for an operator reconcile cycle:

    - Automatic CSR approval for joining worker nodes
    - Immediate node labeling (assigns to the HCI MachineConfigPool)

---

## 5 · Key Custom Resources

### WorkerPool

The primary control surface. An administrator applies one CR specifying:

- Desired worker count
- Network topology variant
- Target namespace on the HCI cluster

All provisioning and scaling flows from this single declaration.

### WorkerPoolProvisioning

An internal coordination board, auto-created by the `WorkerPool` operator. Tracks per-step status for each bootstrap or teardown step (UDN, Gateway VM, MachineConfig, Ignition). Not managed by the administrator; short name `wpp`.

---

## 6 · Two Deployment Topologies

The topology choice is driven by how the main cluster is attached to the network — not by CPU architecture. It is set once at cluster-pair setup time.

=== "Mediated Topology"

    For main clusters on a **private network**. A bastion node acts as an additional routing hop between the main cluster and the gateway VM.

    - No changes to master or worker node routing tables
    - Bastion provides routing and DNS for the main cluster side
    - Simpler main-cluster configuration

    ```
    Main Cluster → Bastion Node → Gateway VM → Worker VMs
    ```

=== "Direct Topology"

    For main clusters on a **routable (public) network**. Master and worker nodes have static routes applied via MachineConfig to reach the worker VM network directly through the gateway.

    - No bastion required as a routing middleman
    - Static routes pushed via MachineConfig (managed in Git)
    - Required on both master nodes and same-arch worker nodes

    ```
    Main Cluster → Gateway VM → Worker VMs
    ```

---

## 7 · Key Lifecycle Flows

### Bootstrap Flow (one-time per consumer)

```
WorkerPool CR applied
  → WorkerPoolProvisioning CR created
  → MachineConfig (MCP and routes) validated on the main cluster
  → Provisioner creates internal UDN
  → Gateway VM created & SSH-verified
  → Ignition distributed
  → Consumer phase → Ready
```

### VM Provisioning Flow (per worker node)

```
DataVolume created
  → VirtualMachine created
  → iPXE boot via Gateway DHCP/TFTP/HTTP
  → RHCOS install via Ignition
  → Kubelet starts, bootstrap + serving CSRs generated
  → csr-approver sidecar approves both CSRs
  → Node labeled → joins MachineConfigPool
  → MachineConfig applied → Ready  (~20–30 min)
```

### Scale-Down Flow

```
WorkerPool count reduced
  → Node cordoned & drained
  → Operator waits for NotReady
  → VM & DataVolume deleted
```

---

## 8 · Privilege & Credential Model

The operators on the main cluster reach the HCI cluster with a single ServiceAccount token. A setup script creates the ServiceAccount, its Role and RoleBinding on the HCI cluster and mints a token once per integration; the token is stored as a kubeconfig Secret on the main cluster. The script needs administrative access to the HCI integration namespace, which is why the operators never create credentials themselves.

| Credential | Scope | Lifecycle |
|---|---|---|
| HCI operator ServiceAccount token (Secret `hci-provisioner-credentials`) | Namespace-scoped Role in the integration namespace on HCI: VMs, DataVolumes, PVCs, UDN, Secrets, ConfigMaps. Read-only access to the cluster-scoped `ClusterUserDefinedNetwork`. The Role also allows ServiceAccount, Role and RoleBinding management, reserved for a credentials step that is not implemented yet. | Valid for 1 year, rotated by re-running the script. Stored in the operator namespace on the main cluster and used by both operators. |
| *Optional:* registry push token (`registry-pusher` ServiceAccount) | Push images to the HCI image registry from the integration namespace. Needed only for the bastion registry proxy (`registry.model: cross-cluster`). | Non-expiring token created with the integration RBAC, read once and stored as a docker-registry Secret on the main cluster. |
| HCI cluster-admin | Full HCI admin: one-time cluster setup (network, registry), integration namespace, RBAC and token creation | Human/admin only, never stored in-cluster |

!!! note "One Secret for both operators"
    `WorkerPool.spec.provider.credentialsSecret` is a single field, passed on to the `WorkerPoolProvisioning` CR, so the consumer and the provisioning operator read the same Secret. The setup script can also create a second, narrower consumer-only ServiceAccount and Secret (`hci-provider-credentials`), but the operators do not use it in the default configuration.

!!! info "Planned: onboarding tickets"
    Short-lived, elevated onboarding tickets generated by the HCI Provider Operator are part of the planned design (backlog item HCI-04). They are not implemented.

---

## 9 · Configuration & Variant Management

### Kustomize Overlays

Main-cluster MachineConfigs are managed as a **base + overlay** set. The base contains configuration common to all variants. Each topology overlay adds only what differs. New topologies can be added without touching the base.

### Cluster-Pair Setup File (`integration-setup.yaml`)

A single YAML input file captures all cluster-pair decisions once: the two clusters, network topology, MachineConfigPool and image registry model. The `generate-setup` script derives all deployment artifacts from it — shell environment, build configuration, MachineConfigs, DNS zones and an initial WorkerPool skeleton — eliminating scattered hard-coded values. See [Setup Concept](setup-concept.md) for the design rationale.

---

## 10 · Guiding Design Principles

- **Declarative intent** — a single WorkerPool CR is the sole operational control surface.
- **Idempotent reconciliation** — the operator can be restarted at any point and resume correctly; all state is derived from Kubernetes resources.
- **Least privilege on HCI** — the operators reach the HCI cluster only through a namespace-scoped ServiceAccount; no HCI cluster-admin credential is ever stored in-cluster.
- **Observe → Diff → Act** — the standard Kubernetes controller pattern applied consistently across all operator roles.
- **Topology abstraction** — the same operator code handles mediated and direct deployments via configuration, not branching code paths.
- **Safe scale-down** — a node must reach `NotReady` before its VM is deleted; no data loss or abrupt eviction.
- **Namespace isolation** — each consumer gets a dedicated namespace and network on the HCI cluster; resources cannot leak across tenants.

---

## Closest Analogy in the OpenShift Ecosystem

The solution mirrors the **ODF Storage Provider / Consumer model**: one cluster contributes a resource (storage / compute), another cluster consumes it, mediated by a pair of operators that manage the cross-cluster lifecycle. The difference here is that the resource is *compute* (virtual machines as worker nodes) rather than storage.
