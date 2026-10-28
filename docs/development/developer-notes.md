# Developer Notes

This document captures key technical decisions, lessons learned, and best practices discovered during the development of this integration solution.

## Core Design Principles

### 1. Separation of Concerns

**Principle**: Cluster-scoped resources should never be managed by namespace-scoped deployments.

**Why**: Multiple integration namespaces would conflict when trying to manage the same cluster-scoped resource (e.g., `ClusterUserDefinedNetwork`).

**Implementation**:
- Cluster-admin applies `ClusterUserDefinedNetwork` once (Setup Guide Tier A)
- Integration namespaces are labeled `hci-gateway-enabled=true`
- Namespace-scoped `UserDefinedNetwork` and gateway/worker VMs are created automatically by the `hci-provisioner` operator
- Clear separation between cluster-admin and integration-team responsibilities

**Reference**: See `hci-cluster/` for cluster-scoped setup.

### 2. Network Interface Management

**Principle**: Disable unused network interfaces completely, don't just deprioritize them.

**Why**: Worker VMs have two interfaces: `enp1s0` (HCI pod network) and `enp2s0` (main cluster network / internal UDN). Having both active causes:
- Dual default routes
- DNS conflicts
- Identity confusion
- NetworkManager and OVN-Kubernetes bridge attachment conflicts

**Implementation**:
- Completely disable `enp1s0` via kernel arguments in the `99-hci-vm-kargs` MachineConfig
- Pass `coreos.inst.karg=ip=enp1s0:off coreos.inst.karg=ip=enp2s0:dhcp` during iPXE first boot / installation
- Use only `enp2s0` for all cluster communication and OVN `br-ex` mapping

**Code**:
```yaml
# 99-hci-vm-kargs
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-hci-vm-kargs
  labels:
    machineconfiguration.openshift.io/role: hci-vm
    node-platform: hci-vm
spec:
  kernelArguments:
    - "root=/dev/disk/by-label/root"
    - "rd.multipath=0"
    - "rd.neednet=1"
    - "ip=enp1s0:off"
    - "ip=enp2s0:dhcp"
  config:
    ignition:
      version: 3.5.0
```

**Reference**: `main-cluster/configuration/base/machineconfig-hci-vm-kargs.yaml`

### 3. Platform-Based Configuration Inheritance

**Principle**: Use labels to prevent architecture-specific config inheritance.

**Why**: HCI x86 workers were inheriting s390x multipath storage configs from the base worker pool, causing boot failures.

**Implementation**:
- Label MachineConfigs with `node-platform: s390x` or `node-platform: hci`
- MachineConfigPool selectors exclude incompatible platforms
- Each platform gets appropriate storage/network configuration

**Code**:
```yaml
# MachineConfigPool selector
machineConfigSelector:
  matchExpressions:
    - key: machineconfiguration.openshift.io/role
      operator: In
      values: [worker, hci-vm]
    - key: node-platform
      operator: NotIn
      values: [s390x]  # Exclude s390x-specific configs
```

**Reference**: `main-cluster/configuration/base/machineconfig-pool-hci-vm.yaml`

## Technical Decisions

### Static IP Assignment via Cloud-Init and DHCP

**Decision**: Use cloud-init with MAC address matching for the gateway VM, and static DHCP reservations on the gateway for worker VMs.

**Why**:
- **Gateway VM**: Configured via cloud-init network configuration (`gateway-vm-cloudinit.j2`). MAC address matching configures static IPs on the physical interface (`172.16.1.100/16`) and internal UDN interface (`192.168.100.1/24`) without relying on OVN IPAM.
- **Worker VMs**: Receive deterministic IPs and hostnames from `dnsmasq` on the gateway VM via static reservations in `/etc/dnsmasq.d/pxe.conf` based on MAC prefix `52:54:01`. No cloud-init or ignition network injection needed on workers.

**Gateway Cloud-Init Implementation**:
```yaml
network:
  version: 2
  ethernets:
    external:
      match:
        macaddress: "52:54:01:00:00:01"
      addresses: [172.16.1.100/16]
      gateway4: 172.16.0.1
      nameservers:
        addresses: [172.16.0.1]
    internal:
      match:
        macaddress: "52:54:01:00:00:02"
      addresses: [192.168.100.1/24]
```

### Kustomize for Deployment Variants

**Decision**: Use Kustomize base + overlays for mediated vs direct topologies (with `generate-setup` providing automated rendering).

**Why**:
- DRY principle - base configs defined once
- Clear visibility of variant differences
- Easy to add new variants (ARM, Power)
- GitOps-ready
- Industry standard

**Structure**:
```
main-cluster/configuration/
├── base/                    # Common MachineConfigs
│   ├── kustomization.yaml
│   ├── machineconfig-pool-hci-vm.yaml
│   └── machineconfig-hci-vm-kargs.yaml
└── overlays/
    ├── mediated/            # Mediated Topology (private network)
    │   └── kustomization.yaml
    └── direct/              # Direct Topology (shared/public network)
        ├── kustomization.yaml
        ├── 99-master-s390x-hci-network-route.yaml
        └── 99-worker-s390x-hci-network-route.yaml
```

### OVN Networking Topology

**Decision**: Use OVN localnet (external) + layer2 (internal) topologies.

**Why**:
- **Localnet**: Direct physical network access without overlay encapsulation
- **Layer2**: Complete isolation for internal worker network
- **Performance**: No double encapsulation overhead
- **Security**: Internal network completely isolated from HCI pod network

**Alternatives Rejected**:
- Pure overlay networks - Too much encapsulation overhead
- Physical bridge - Requires node-level configuration
- Router VM with NAT - Adds complexity, breaks cluster networking

## Common Pitfalls & Solutions

### 1. NAD Namespace References

**Problem**: NetworkAttachmentDefinition references pointing to wrong namespace.

**Symptom**: VMs fail to start with "failed to get pod annotation" errors.

**Solution**: Always use fully qualified NAD references:
```yaml
# Wrong
networks:
  - name: router-external-network

# Correct
networks:
  - name: <namespace>/router-external-network
```

**Prevention**: The operator automatically formats the network attachment as `<namespace>/router-external-network`.

### 2. ClusterUserDefinedNetwork Conflicts

**Problem**: Multiple deployments trying to manage the same ClusterUserDefinedNetwork.

**Symptom**: Second deployment fails or overwrites the cluster-scoped network.

**Solution**:
- Cluster-admin creates `ClusterUserDefinedNetwork` once
- Integration namespace must be labeled: `hci-gateway-enabled=true`
- Provisioner operator references the generated NAD and manages only namespace-scoped resources

### 3. Master and Worker Node Routing (Direct Topology)

**Problem**: Master and s390x worker nodes cannot reach HCI internal network in direct topology deployments.

**Symptom**: CSR approval fails, cross-architecture pod communication fails.

**Solution**: Add static routes on master and worker nodes via MachineConfigs:
```bash
# Master route
ip route add 192.168.100.0/24 via <gateway-external-ip> dev br-ex

# Worker route
ip route add 192.168.100.0/24 via <gateway-external-ip>
```

**Implementation**: `main-cluster/configuration/overlays/direct/99-master-s390x-hci-network-route.yaml` and `99-worker-s390x-hci-network-route.yaml`

### 4. DNS Resolution

**Problem**: Workers using wrong DNS server (HCI cluster instead of main cluster).

**Symptom**: Can't resolve main cluster API, etcd endpoints.

**Solution**:
- Gateway VM `dnsmasq` serves main cluster DNS (`172.16.0.1`) via DHCP
- Disable `enp1s0` via kernel arguments to prevent HCI Pod network DNS from taking precedence
- Verify with: `oc debug node/<worker> -- chroot /host cat /etc/resolv.conf`

## Best Practices

### Configuration Management

1. **Use single source of truth**: `integration-setup.yaml` processed by `./generate-setup`
2. **Never commit credentials**: Use `.gitignore` and example files
3. **Validate before apply**: Check generated artifacts in `workspace/`
4. **Test both topologies**: Mediated (private network) and Direct (shared network)

### Deployment Workflow

1. **Gateway first**: The operator provisions and boots the gateway VM before worker VMs
2. **Verify gateway**: Ensure RHCOS boot files are downloaded and services are active
3. **Enable workers gradually**: Start with 1 canary worker, verify Ready state, then scale
4. **Monitor MachineConfigPool**: Watch `oc get mcp hci-vm` for `UPDATED: True`

### Troubleshooting Approach

1. **Check MachineConfigPool status**: `oc --context ${MAIN_CLUSTER_CONTEXT} get mcp hci-vm`
2. **Verify network attachments**: `oc --context ${HCI_CLUSTER_CONTEXT} get nad -n ${HCI_INTEGRATION_NAMESPACE}`
3. **Inspect VM status**: `oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE}`
4. **Debug node**: `oc --context ${MAIN_CLUSTER_CONTEXT} debug node/<worker-name>`
5. **Check gateway status**: `ssh core@<gateway-ip>` (or `virtctl console`)

## Performance Considerations

### Network Performance

- **OVN localnet**: Near-native performance (no overlay encapsulation)
- **MTU**: Ensure consistent MTU across all networks (typically 1500)
- **Gateway VM resources**: 2 vCPU, 4GB RAM sufficient for 10-20 workers

### Storage Performance

- **Worker VMs**: Use fast storage for etcd-heavy workloads
- **Gateway VM**: Standard storage sufficient (mostly network I/O)
- **Avoid multipath**: HCI virtual disks don't need multipath

## Security Considerations

### Network Isolation

- Internal worker network (192.168.100.0/24) completely isolated via OVN layer2
- No direct access from HCI pod network to workers
- Gateway VM provides controlled routing

### Access Control

- Cluster-admin required for ClusterUserDefinedNetwork
- Namespace-level RBAC for VM deployment
- SSH key from main cluster required for VM access

### Firewall Rules

Gateway VM implements defense-in-depth:
- Explicit allow rules for cluster traffic
- NAT for internet access
- Drop all other traffic

## Future Improvements

### Operator Development

See [Operator Roadmap](operator-roadmap.md) and [Build & Deploy Operators](operator-build-deploy.md).

Key benefits:
- Declarative configuration via `WorkerPool` and `WorkerPoolProvisioning` CRDs
- Automated lifecycle management (gateway, UDN, worker VMs, CSRs, node labeling)
- Self-healing capabilities
- Multi-cluster and multi-namespace support

### Additional Architectures

Structure supports:
- ARM-based main clusters
- Power-based main clusters
- Additional HCI platforms

Implementation: Create new Kustomize overlay for architecture-specific needs.

## References

### Internal Documentation
- [Architecture Overview](../architecture/architecture-overview.md)
- [Network Design](../architecture/network-design.md)
- [Troubleshooting](../operations/troubleshooting.md)

### External Resources
- [OVN-Kubernetes Documentation](https://github.com/ovn-org/ovn-kubernetes)
- [OpenShift Multi-Architecture](https://docs.openshift.com/container-platform/latest/post_installation_configuration/configuring-multi-arch-compute-machines/multi-architecture-configuration.html)
- [Kustomize Documentation](https://kustomize.io/)

## Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-04-22 | Dual network conflict solution | Team |
| 2026-04-22 | Platform labeling implementation | Team |
| 2026-04-27 | ClusterUserDefinedNetwork separation | Team |
| 2026-06-08 | Centralized configuration system | Team |
| 2026-06-09 | Repository consolidation | Team |

---

**Note**: This document is living documentation. Update it when you discover new patterns, solutions, or pitfalls.