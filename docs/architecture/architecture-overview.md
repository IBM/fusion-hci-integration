# Architecture Overview

This document provides a comprehensive overview of the Fusion HCI multi-architecture integration architecture, explaining how x86 worker nodes running on a Fusion HCI cluster can be integrated into a main OpenShift cluster running on a different architecture (s390x, ARM, or Power).

## Executive Summary

The Fusion HCI multi-architecture integration enables:

- **Main cluster** runs on one architecture (e.g., s390x/LinuxONE, ARM, or Power)
- **Additional x86 worker nodes** provided as VMs from Fusion HCI via OpenShift Virtualization
- **VMs created** in the HCI management cluster within a dedicated namespace
- **Single unified cluster** with mixed architecture worker nodes

This architecture enables workloads requiring x86 architecture to run alongside the main cluster's native architecture workloads, with unified management and orchestration.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│              Multi-Architecture OpenShift Cluster                │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Control Plane (Main Architecture)                        │   │
│  │ ├── master-1                                             │   │
│  │ ├── master-2                                             │   │
│  │ └── master-3                                             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Worker Nodes (Main Architecture)                         │   │
│  │ ├── worker-main-1                                        │   │
│  │ ├── worker-main-2                                        │   │
│  │ └── worker-main-3                                        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Worker Nodes (x86) ← FROM FUSION HCI                     │   │
│  │ ├── worker-x86-1 (VM on Fusion HCI OpenShift Virt)      │   │
│  │ ├── worker-x86-2 (VM on Fusion HCI OpenShift Virt)      │   │
│  │ └── worker-x86-3 (VM on Fusion HCI OpenShift Virt)      │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Network Connectivity
                              │ (API, Node Registration, Pod Network)
                              │
┌─────────────────────────────┴───────────────────────────────────┐
│              Fusion HCI Infrastructure (x86)                     │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ HCI Management Cluster                                     │ │
│  │ ├── Fusion Platform Services                              │ │
│  │ └── Integration Namespace                                 │ │
│  │     ├── OpenShift Virtualization (KubeVirt)               │ │
│  │     ├── Gateway VM (routing + DHCP/iPXE)                  │ │
│  │     └── Worker VMs (RHCOS)                                │ │
│  │         ├── VM: worker-x86-1 (4 vCPU, 8GB RAM)            │ │
│  │         ├── VM: worker-x86-2 (4 vCPU, 8GB RAM)            │ │
│  │         └── VM: worker-x86-3 (4 vCPU, 8GB RAM)            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Physical Resources:                                             │
│  ├── Compute: x86 servers                                       │
│  ├── Storage: Fusion HCI storage pools                          │
│  └── Network: Connectivity to main cluster network              │
└──────────────────────────────────────────────────────────────────┘
```

## Key Concepts

### Multi-Architecture Cluster

OpenShift supports running worker nodes with different CPU architectures in the same cluster:

- **Control plane** must be single architecture (e.g., s390x, ARM, or Power)
- **Worker nodes** can be mixed architectures (main + x86)
- **Container images** must be multi-arch manifests or architecture-specific
- **Workload scheduling** uses node selectors and tolerations for architecture targeting

### Why This Architecture?

**Benefits:**

1. **Unified Management**: Single cluster for all workloads
2. **Resource Optimization**: Use x86 hardware for x86-specific workloads
3. **Flexibility**: Run workloads on optimal architecture
4. **Cost Efficiency**: Leverage existing Fusion HCI investment
5. **Simplified Operations**: One cluster to manage, monitor, and secure

**Use Cases:**

- Legacy x86 applications that can't be recompiled for other architectures
- Third-party software only available for x86
- Development/testing of multi-arch applications
- Gradual migration strategies
- Workload-specific performance optimization

## Network Architecture

### Network Topology

The integration uses a dual-network approach:

```
┌─────────────────────────────────────────────────────────────┐
│ Main Cluster Network                                        │
│ (e.g., 10.0.0.0/24 mediated, or 172.16.0.0/16 direct)      │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Control Plane│  │ Main Workers │  │ Main Workers │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ Routing (via bastion or direct)
                         │
                ┌────────▼─────────┐
                │   Gateway VM     │
                │ External: Main cluster network              │
                │ Internal: 192.168.100.1/24                  │
                └────────┬─────────┘
                         │
              ┌──────────┴──────────┐
              │                     │
      ┌───────▼────────┐    ┌───────▼────────┐
      │  x86 Worker 1  │    │  x86 Worker 2  │
      │ 192.168.100.10 │    │ 192.168.100.11 │
      └────────────────┘    └────────────────┘
```

### Network Components

#### 1. External Network (Localnet)

- **Purpose**: Connects gateway VM to main cluster network
- **Technology**: OVN-Kubernetes ClusterUserDefinedNetwork with localnet topology
- **Configuration**: Maps to physical network interface on HCI nodes
- **IP Assignment**: Static IP on the gateway VM, set via cloud-init

#### 2. Internal Network (Layer2)

- **Purpose**: Isolated network for HCI worker VMs
- **Technology**: OVN-Kubernetes UserDefinedNetwork with Layer2 topology
- **Network**: 192.168.100.0/24 (set by `provider.networking.internalSubnet`)
- **Gateway**: 192.168.100.1 (network address + `.1`, the gateway VM)
- **IP Assignment**: Gateway VM static (cloud-init); workers via static DHCP reservations on the gateway

#### 3. Gateway VM

The gateway VM provides critical services:

- **Routing**: Forwards traffic between internal and external networks
- **DHCP**: Static reservations (MAC, IP, hostname) for the worker VMs
- **Network boot**: iPXE (TFTP + HTTP) for RHCOS installation
- **DNS Forwarding**: Resolves main cluster hostnames
- **NAT**: Selective masquerading for internet traffic

**Gateway VM Specifications** (defaults; override with `provider.gateway.resources`):
- OS: CentOS Stream 9 (or similar)
- vCPU: 2
- Memory: 4GB
- Storage: 30GB
- Network Interfaces: 2 (external + internal)

### Routing Strategies

The integration supports two routing variants based on main cluster network topology:

#### Mediated Topology (Private Network)

- Main cluster nodes in a private network (e.g., 10.0.0.0/24, `consumer.networking.internalNetwork`)
- Bastion host routes all traffic
- Gateway VM connects to bastion's external IP
- No changes to main cluster nodes

#### Direct Topology (Public Network)

- Main cluster nodes on a public/shared network (e.g., 172.16.0.0/16)
- Direct connectivity between nodes and gateway VM
- Static routes added to master and worker nodes
- More flexible but requires node configuration

See [Deployment Variants](../deployment-variants.md) for detailed comparison.

## Component Architecture

### HCI Cluster Components

#### 1. Cluster-Admin Resources (Cluster-Scoped)

Applied once by cluster administrator:

- **ClusterUserDefinedNetwork**: External network definition
- **Namespace Labels**: Enable network access per namespace

#### 2. Integration Namespace Resources

Deployed per integration namespace:

- **UserDefinedNetwork**: Internal worker network
- **Gateway VM**: Routing and services
- **Worker VMs**: x86 worker nodes
- **Secrets**: Gateway cloud-init data, SSH keys
- **ConfigMaps**: Network configuration

### Main Cluster Components

#### 1. MachineConfigPool

Separate pool for HCI workers:

- **Name**: `hci-vm`
- **Selector**: `node-role.kubernetes.io/hci-vm: ""`
- **Purpose**: Isolate HCI worker configuration

#### 2. MachineConfigs

Configuration for HCI workers:

- **Kernel Arguments**: Boot parameters, multipath settings
- **Network Configuration**: Interface management (variant-specific)
- **Kernel arguments**: x86 VM-specific boot parameters (disable multipath, configure interfaces)

#### 3. HCI Node Manager (sidecars)

Deployed as sidecar containers inside the `hci-consumer-operator` pod:

- **CSR Auto-Approval** (`csr-approver`): stream-watch, millisecond reaction time
- **Node Labeling** (`node-labeler`): applies `node-role.kubernetes.io/hci-vm: ""` before MCO renders ignition
- **Permanent**: re-reads config from `hci-node-manager-config` ConfigMap every ~30 s

#### 4. hci-consumer Operator ✅ Complete

Kubernetes operator for steady-state worker VM lifecycle (Epics 1 and 2 complete, Epics 3–4 in backlog):

- **CRD**: `WorkerPool` (`hci-integration.openshift.io/v1alpha1`) — declarative desired worker count
- **Scale-up**: creates `DataVolume` + `VirtualMachine` on HCI when `workers.count` increases
- **Scale-down**: deletes VM and node when `workers.count` decreases, gated on node NotReady state
- **Observe/diff/act**: all API calls isolated in `observe_world.yml`; `diff_desired_actual.yml` is pure set arithmetic
- **`maxPoolSize` enforcement**: CEL admission rule on CRD + runtime clamping with CR condition

See the [hci-consumer operator README](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/README.md)
and the [Operator Roadmap](../development/operator-roadmap.md) for full implementation status.

## Deployment Flow

### Configuration Input

All cluster-pair decisions are captured once in a single file,
`workspace/integration-setup.yaml`, filled in jointly by the HCI admin
(`provider.*`) and the main cluster admin (`consumer.*`). The `generate-setup`
script derives everything else from it: `setup_env.sh`, `operator/build/config.env`,
the direct-topology route MachineConfigs, the DNS zone files and an initial
`WorkerPool` CR with `workers.count: 0`. See [Setup Concept](setup-concept.md) for the
design and [Prerequisites](../prerequisites.md#environment-configuration) for the how-to.

The concrete values shown as examples throughout the architecture pages map to
these fields:

| Example value in these pages | `integration-setup.yaml` field |
|---|---|
| `mediated` or `direct` routing | `consumer.networking.topology` |
| Main cluster domain `cluster.example.com` | `consumer.domain` |
| DNS server `172.16.0.1` (the bastion) | `consumer.networking.dnsServer` |
| Main cluster internal network `10.0.0.0/24` (mediated only) | `consumer.networking.internalNetwork` |
| Gateway towards that network `172.16.0.1` (mediated only) | `consumer.networking.internalGateway` |
| MachineConfigPool `hci-vm` | `consumer.machineConfigPool` (default `hci-vm`) |
| Operator namespace `hci-node-manager` | `consumer.operatorNamespace` |
| Worker name prefix `worker-x86` | `consumer.workers.namePrefix` |
| Worker VM resources (4 vCPU, 8Gi, 50Gi) | `consumer.workers.resources` (operator defaults) |
| HCI namespace `main-cluster-workers` | `provider.namespace` |
| Gateway external IP `172.16.1.100`, prefix `16`, default router `172.16.0.1` | `provider.gateway.ip`, `.prefixLength`, `.defaultRouter` |
| Gateway VM resources (2 vCPU, 4Gi, 30Gi) | `provider.gateway.resources` (operator defaults) |
| Internal worker network `192.168.100.0/24` | `provider.networking.internalSubnet` |
| MAC address prefix `52:54:01` | `provider.networking.macPrefix` (default `52:54:00`) |
| Maximum number of workers `10` | `provider.maxPoolSize` |
| Image registry strategy | `registry.model` |

### Phase 1: Prerequisites

1. Main cluster operational with OpenShift 4.20+
2. HCI cluster operational with OpenShift Virtualization
3. Network connectivity between clusters
4. Registry strategy selected (`registry.model`)
5. `workspace/integration-setup.yaml` completed and `generate-setup` run — this also
   produces the DNS zone files to be added on the bastion

### Phase 2: Main Cluster Preparation

1. Create MachineConfigPool for HCI workers
2. Apply MachineConfigs (base + variant overlay; the direct-topology route
   MachineConfigs are generated by `generate-setup`)
3. Deploy HCI node manager (optional but recommended)
4. Configure registry access (if using bastion proxy)

### Phase 3: HCI Cluster Preparation

1. Cluster admin applies ClusterUserDefinedNetwork
2. Create and label integration namespace
3. Run `setup-provider-credentials.sh` to create operator credential Secrets

### Phase 4: Deployment

1. Apply the generated `WorkerPool` CR (`workspace/workerpool-hci-workers.yaml`, `workers.count: 0`) — `hci-consumer` creates the `WorkerPoolProvisioning` CR automatically
2. `hci-provisioner` creates UDN, gateway VM, ignition, and bootfiles; sets `WorkerPool` phase → `Ready`
3. Set `workers.count` on the live `WorkerPool`; `hci-consumer` scales up and worker VMs network-boot (iPXE) and install RHCOS
4. Workers join main cluster; CSRs approved automatically by the `csr-approver` sidecar; nodes become Ready

### Phase 5: Verification

1. Verify nodes appear in main cluster
2. Check node labels and MachineConfigPool membership
3. Test workload deployment on x86 workers
4. Verify cross-architecture pod communication

## Security Considerations

### Namespace Isolation

- HCI workers deployed in dedicated namespace
- Network policies control traffic flow
- RBAC limits access to integration resources
- Separate service accounts for components

### Network Segmentation

- Internal worker network isolated from HCI pod network
- Gateway VM controls all external access
- Firewall rules on gateway VM
- Optional network policies on main cluster

### Certificate Management

- Main cluster CA trusted by HCI workers
- Node certificates issued by main cluster
- TLS for all API communication
- Automatic certificate rotation

### Access Control

- SSH keys managed via secrets
- Ignition configuration secured
- RBAC for HCI cluster resources
- Audit logging enabled

## Performance Considerations

### Network Latency

- **Gateway VM overhead**: ~0.5-1ms additional latency
- **Cross-cluster communication**: Depends on physical network
- **Mitigation**: Place gateway VM on low-latency nodes

### Nested Virtualization

- **HCI workers are VMs**: Some overhead vs bare metal
- **CPU performance**: ~5-10% overhead
- **Memory**: Direct mapping, minimal overhead
- **Storage**: Depends on HCI storage backend

### Resource Allocation

**Gateway VM:**
- 2 vCPU, 4GB RAM (minimal overhead)
- Can be increased for high-throughput scenarios

**Worker VMs:**
- Default: 4 vCPU, 8GB RAM, 50GB disk per worker (`consumer.workers.resources`)
- Adjust based on workload requirements
- Consider HCI node capacity

## Scalability

### Horizontal Scaling

- **Add workers**: Increase `WorkerPool.spec.consumer.workers.count`
- **Multiple namespaces**: Support multiple integration namespaces
- **Gateway HA**: Deploy multiple gateway VMs for redundancy

### Vertical Scaling

- **Worker resources**: Adjust vCPU/memory per worker
- **Gateway resources**: Increase for high-throughput scenarios
- **Storage**: Expand worker VM disks as needed

### Limitations

- **Network bandwidth**: Gateway VM is potential bottleneck
- **HCI capacity**: Limited by physical HCI resources
- **IP address space**: Internal network size (default /24 = 254 hosts)

## High Availability

### Gateway VM HA

Options for gateway VM redundancy:

1. **Active-Passive**: Deploy backup gateway VM
2. **Active-Active**: Multiple gateways with load balancing
3. **VM Live Migration**: Leverage OpenShift Virtualization HA

### Worker VM HA

- **Pod disruption budgets**: Protect workloads during maintenance
- **Node affinity**: Spread workers across HCI nodes
- **VM live migration**: Move VMs without downtime

### Network HA

- **Multiple gateway VMs**: Eliminate single point of failure
- **Redundant routing**: Multiple paths to main cluster
- **Monitoring**: Detect and alert on network issues

### HCI Cluster-Level HA

The HA mechanisms above (live migration, node affinity, gateway redundancy) all operate
**within** a single Fusion HCI cluster. They protect against individual HCI host failures
but cannot protect against a full HCI cluster outage.

For deployments where loss of all x86 workers is unacceptable, the recommended approach
is **dual-HCI**: two independent Fusion HCI units, each with its own `WorkerPool` CR on
the main cluster. Worker VMs are spread across both units; if one HCI cluster goes down,
the other continues to supply x86 capacity. This requires the main cluster workloads to
tolerate reduced x86 capacity during a single-unit outage (e.g. via pod disruption budgets
and appropriate replica counts).

## Monitoring and Observability

### Key Metrics

**Gateway VM:**
- Network throughput (in/out)
- Packet loss rate
- CPU and memory utilization
- DHCP lease activity

**Worker VMs:**
- Node status and readiness
- Resource utilization
- Network connectivity
- Pod scheduling success rate

**Integration Health:**
- CSR approval rate
- Node join time
- Cross-architecture pod communication latency

### Logging

- Gateway VM logs (dnsmasq, firewalld, NetworkManager)
- Worker VM console logs
- Main cluster node logs
- HCI cluster virtualization logs

### Alerting

- Gateway VM down
- Worker VM failed to join
- Network connectivity issues
- Resource exhaustion

## Operational Procedures

### Adding Workers

1. Increase `WorkerPool.spec.consumer.workers.count`
2. The `hci-consumer` operator creates the additional VMs automatically
3. Monitor CSR approval and node join via `oc get workerpool -w`
4. Verify new nodes are Ready

### Removing Workers

1. Decrease `WorkerPool.spec.consumer.workers.count`
2. The operator cordons and drains surplus nodes, then deletes the VMs
3. `WorkerPool.status.phase` shows `ScalingDown` / `ScalingDownBlocked` until complete

### Upgrading

**Main Cluster Upgrade:**
- HCI workers upgrade with main cluster
- MachineConfigPool manages rolling updates
- Workers reboot to apply new configuration

**HCI Cluster Upgrade:**
- Gateway VM may need recreation
- Worker VMs unaffected (run RHCOS from main cluster)
- Plan maintenance window for gateway VM updates

### Troubleshooting

See [Troubleshooting Guide](../operations/troubleshooting.md) for detailed troubleshooting procedures.

## Best Practices

### Deployment

1. **Start small**: Deploy 1-2 workers initially
2. **Test thoroughly**: Verify functionality before scaling
3. **CSR approval is automatic**: the `csr-approver` sidecar in the operator handles it
4. **Document configuration**: Keep `WorkerPool` and `WorkerPoolProvisioning` CR manifests in version control

### Operations

1. **Monitor continuously**: Set up alerts for critical metrics
2. **Regular backups**: Back up CR manifests and configurations
3. **Plan maintenance**: Schedule updates during low-traffic periods
4. **Test disaster recovery**: Verify recovery procedures work

### Security

1. **Least privilege**: Use minimal RBAC permissions
2. **Network policies**: Restrict traffic where possible
3. **Regular updates**: Keep gateway VM OS updated
4. **Audit logs**: Review logs regularly for anomalies

## Limitations and Known Issues

### Current Limitations

1. **Single gateway VM**: Potential single point of failure (HA possible but not default)
2. **Network bandwidth**: Gateway VM throughput limited by VM resources
3. **IP address space**: Internal network /24 limits to ~250 workers
4. **CSR approval and node labeling**: Handled automatically by the `csr-approver` and `node-labeler` sidecars in the `hci-consumer-operator` Deployment
5. **HCI availability is a hard dependency for the main cluster**: All x86 worker nodes
   run as VMs on the Fusion HCI box. If the HCI cluster becomes unavailable (hardware
   failure, maintenance, power loss), the main cluster loses those worker nodes and has
   no path to replace them until HCI recovers. Intra-HCI redundancy (VM live migration,
   node affinity across HCI hosts) mitigates individual host failures within the HCI box,
   but does **not** protect against a full HCI cluster outage.
   **HA implication**: deployments with strict availability requirements should operate
   two independent Fusion HCI units, each backing a separate `WorkerPool` CR, so that
   the main cluster retains x86 capacity if one HCI unit is lost.

### Known Issues

1. **OVN IPAM with localnet**: OVN IPAM is disabled; the gateway VM's IPs are set via cloud-init and the workers' IPs via DHCP reservations on the gateway
2. **Dual network conflict**: Worker VMs must disable HCI pod network interface
3. **MachineConfig inheritance**: Requires platform labeling to prevent conflicts

### Workarounds

See [Troubleshooting Guide](../operations/troubleshooting.md) for detailed workarounds.

## Future Enhancements

### Short-term

- Gateway VM HA implementation
- Enhanced monitoring dashboards
- Automated testing framework
- Performance optimization guide

### Long-term

- Multi-gateway load balancing
- Integration with cluster autoscaler

## References

### Documentation

- [Getting Started Guide](../getting-started.md)
- [Prerequisites](../prerequisites.md)
- [Deployment Variants](../deployment-variants.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [Developer Notes](../development/developer-notes.md)

### OpenShift Documentation

- [Multi-Architecture Compute](https://docs.openshift.com/container-platform/latest/post_installation_configuration/configuring-multi-arch-compute-machines/multi-architecture-configuration.html)
- [OpenShift Virtualization](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [OVN-Kubernetes](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)
- [MachineConfig](https://docs.openshift.com/container-platform/latest/post_installation_configuration/machine-configuration-tasks.html)

## Conclusion

The Fusion HCI multi-architecture integration provides a robust, scalable solution for extending OpenShift clusters with x86 worker nodes. By leveraging OpenShift Virtualization and OVN-Kubernetes networking, the integration maintains cloud-native principles while enabling multi-architecture workload deployment.

The architecture balances complexity, performance, and operational requirements, providing a production-ready solution for organizations needing multi-architecture capabilities.