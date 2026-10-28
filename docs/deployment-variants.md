# Deployment Variants

This document explains the two network topology variants supported by the Fusion HCI multi-architecture integration and helps you choose the right one for your environment.

## Overview

The integration supports two deployment variants based on your main cluster's network topology:

- **Mediated Topology**: Main cluster nodes in private network behind bastion
- **Direct Topology**: Main cluster nodes on public network with direct connectivity

The choice depends on how your main cluster is deployed and networked, not on the CPU architecture itself.

## Variant Comparison

### Quick Comparison Table

| Aspect | Mediated Topology | Direct Topology |
|--------|--------------|-------------|
| **Main Cluster Network** | Private (10.x.x.x) | Public (172.16.x.x) |
| **Bastion Role** | Routes all traffic | Routes only if needed |
| **Master Node Config** | Standard | Requires static route |
| **S390x Worker Config** | Standard | Requires static route |
| **Gateway VM Access** | Via bastion | Direct |
| **DNS** | Bastion provides | Bastion or direct |
| **Complexity** | Medium | Low-Medium |
| **Common In** | z/VM environments | KVM environments |
| **Setup Time** | ~30 min | ~20 min |

## Mediated Topology (Private Network)

### When to Use

Choose the Mediated Topology when:

- ✅ Main cluster nodes are in a private network (e.g., 10.x.x.x)
- ✅ Bastion host provides external connectivity
- ✅ Main cluster nodes cannot directly access external networks
- ✅ Common in z/VM, LPAR, or highly secured environments

### Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│ Main Cluster (Private Network)                              │
│ Network: 10.0.0.0/24                                        │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Control Plane│  │ s390x Worker │  │ s390x Worker │      │
│  │ 10.0.0.x     │  │ 10.0.0.x     │  │ 10.0.0.x     │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                            │                                │
│                    ┌───────▼────────┐                       │
│                    │ Bastion Node   │                       │
│                    │ Internal: 10.0.0.x                     │
│                    │ External: 172.16.0.1                   │
│                    └───────┬────────┘                       │
└────────────────────────────┼──────────────────────────────┘
                             │
                             │ All traffic routes through bastion
                             │ - API access (6443)
                             │ - Machine config (22623)
                             │ - Application ingress (80/443)
                             │ - Registry proxy (5443)
                             │
                    ┌────────▼─────────┐
                    │   Gateway VM     │
                    │ External: 172.16.1.100                  │
                    │ Internal: 192.168.100.1                 │
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
      ┌───────▼────────┐           ┌───────▼────────┐
      │  x86 Worker 1  │           │  x86 Worker 2  │
      │ 192.168.100.10 │           │ 192.168.100.11 │
      └────────────────┘           └────────────────┘
```

### Key Characteristics

**Routing:**
- All cluster traffic goes through bastion
- Bastion routes to HCI internal network: `192.168.100.0/24 via 172.16.1.100`
- Gateway VM connects to bastion's external IP

**DNS:**
- Bastion provides DNS for entire cluster
- HCI workers use bastion as DNS server
- Forward and reverse zones on bastion

**Security:**
- Private network provides isolation
- Bastion is single point of entry/exit
- Firewall rules on bastion control access

**Configuration:**
- Apply: `oc apply -k main-cluster/configuration/overlays/mediated/`
- Includes: MachineConfigPool + kernel args
- No master node changes needed
- No s390x worker changes needed

### Setup Steps

1. **Configure Bastion Routing**
   ```bash
   # On bastion host
   sudo ip route add 192.168.100.0/24 via 172.16.1.100
   
   # Make persistent
   sudo tee /etc/sysconfig/network-scripts/route-eth0 <<EOF
   192.168.100.0/24 via 172.16.1.100
   EOF
   ```

2. **Configure DNS on Bastion**
   - Add forward zone entries for HCI workers
   - Add reverse zone for 192.168.100.0/24
   - Ensure recursive queries allowed from HCI network

3. **Apply MachineConfigs**
   ```bash
   oc apply -k main-cluster/configuration/overlays/mediated/
   ```

4. **Deploy Gateway and Workers**
   - Gateway VM uses bastion IP for DNS and routing
   - Workers automatically use bastion DNS

### Verification

```bash
# From bastion, verify route
ip route | grep 192.168.100

# Test connectivity to gateway
ping 172.16.1.100  # Gateway external IP
ping 192.168.100.1   # Gateway internal IP

# Test DNS
nslookup worker-x86-1.cluster.example.com
nslookup 192.168.100.10
```

## Direct Topology (Public Network)

### When to Use

Choose the Direct Topology when:

- ✅ Main cluster nodes are on public/shared network (e.g., 172.16.x.x)
- ✅ Main cluster nodes can directly access external networks
- ✅ Gateway VM will be on same network as main cluster
- ✅ Common in KVM, bare metal, or less restricted environments

### Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│ Main Cluster (Public Network)                               │
│ Network: 172.16.0.0/16                                      │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Control Plane│  │ s390x Worker │  │ s390x Worker │      │
│  │ 172.16.x.x   │  │ 172.16.x.x   │  │ 172.16.x.x   │      │
│  │ (br-ex)      │  │ (needs route)│  │ (needs route)│      │
│  └──────┬───────┘  └──────────────┘  └──────────────┘      │
│         │                                                   │
│         │ Direct access to gateway VM                      │
│         │ Static route: 192.168.100.0/24 via 172.16.1.100 │
│         │                                                   │
└─────────┼───────────────────────────────────────────────────┘
          │
          │ Direct connectivity (no bastion routing needed)
          │
    ┌─────▼──────────┐
    │   Gateway VM   │
    │ External: 172.16.1.100 (same network as cluster)      │
    │ Internal: 192.168.100.1                               │
    └────────┬───────┘
             │
      ┌──────┴──────┐
      │             │
┌─────▼────┐  ┌─────▼────┐
│ Worker 1 │  │ Worker 2 │
│ .100.10  │  │ .100.11  │
└──────────┘  └──────────┘
```

### Key Characteristics

**Routing:**
- Master nodes need static route to HCI internal network
- S390x workers need static route to HCI internal network
- Routes added via MachineConfigs: `192.168.100.0/24 via 172.16.1.100`
- HCI x86 workers route through gateway VM as usual

**DNS:**
- Can use bastion DNS or direct DNS
- More flexible DNS configuration
- HCI workers can use bastion or external DNS

**Security:**
- Public network requires careful firewall rules
- Direct access means more exposure
- Network segmentation via firewall policies

**Configuration:**
- Apply: `oc apply -k main-cluster/configuration/overlays/direct/`
- Includes: MachineConfigPool + kernel args + **master route** + **worker route**
- Master nodes will restart to apply route
- S390x workers will restart to apply route

### What's Included

The direct overlay includes two additional MachineConfigs for routing:

1. **99-master-s390x-hci-network-route.yaml**
   - Applies to: Master nodes
   - Purpose: Cluster management (CSR approval, scheduling, health checks)
   - Route: `192.168.100.0/24 via 172.16.1.100 dev br-ex`

2. **99-worker-s390x-hci-network-route.yaml**
   - Applies to: S390x worker nodes (via `node-platform: s390x` label)
   - Purpose: Pod-to-pod communication across architectures
   - Route: `192.168.100.0/24 via 172.16.1.100`

### Setup Steps

1. **Apply MachineConfigs (includes both routes)**
   ```bash
   oc apply -k main-cluster/configuration/overlays/direct/
   
   # This applies:
   # - MachineConfigPool for HCI workers
   # - Kernel args for HCI workers
   # - 99-master-s390x-hci-network-route (for masters)
   # - 99-worker-s390x-hci-network-route (for s390x workers)
   ```

2. **Wait for MachineConfigPool Updates**
   ```bash
   # Masters will restart one by one
   watch oc get mcp master
   
   # S390x workers will also restart
   watch oc get mcp worker
   
   # Wait for all pools:
   # - UPDATED: True
   # - UPDATING: False
   # - DEGRADED: False
   ```

3. **Verify Routes**
   ```bash
   # Check route on a master node
   oc debug node/<master-node>
   chroot /host
   ip route | grep 192.168.100
   # Should show: 192.168.100.0/24 via 172.16.1.100 dev br-ex
   
   # Check route on s390x worker
   oc debug node/<s390x-worker-node>
   chroot /host
   ip route | grep 192.168.100
   # Should show: 192.168.100.0/24 via 172.16.1.100
   ```

4. **Deploy Gateway and Workers**
   - Gateway VM on same network as cluster
   - Workers route through gateway as usual

### Verification

```bash
# From any master node
oc debug node/<master-node>
chroot /host

# Verify route exists
ip route | grep 192.168.100

# Test connectivity to gateway
ping 172.16.1.100  # Gateway external IP
ping 192.168.100.1   # Gateway internal IP (via route)

# From s390x worker
oc debug node/<s390x-worker>
chroot /host
ip route | grep 192.168.100
ping 192.168.100.1

# Test from HCI worker node
oc debug node/worker-x86-1
chroot /host
ping api.cluster.example.com
```

### Why Both Routes Are Needed

**Master Route:**
- Masters need to communicate with HCI workers for:
  - CSR approval
  - Node status updates
  - Pod scheduling decisions
  - Health checks

**S390x Worker Route:**
- S390x workers need to communicate with HCI workers for:
  - Pod-to-pod communication across architectures
  - Service endpoints spanning both worker types
  - Network policies involving both architectures
  - Multi-architecture application deployments

## Decision Guide

### Choose Mediated Topology If:

- ✅ Your main cluster uses private networking (10.x.x.x)
- ✅ You have a bastion host handling all external traffic
- ✅ Your environment is z/VM, LPAR, or highly secured
- ✅ You're comfortable with bastion-centric architecture
- ✅ You want centralized traffic control

### Choose Direct Topology If:

- ✅ Your main cluster uses public/shared networking (172.16.x.x)
- ✅ Cluster nodes can directly access external networks
- ✅ Your environment is KVM, bare metal, or less restricted
- ✅ You prefer direct connectivity over bastion routing
- ✅ You're comfortable with master and worker node configuration changes

### Still Not Sure?

Ask yourself:

1. **Can my main cluster nodes ping 172.16.1.100 directly?**
   - Yes → Direct Topology
   - No → Mediated Topology

2. **Does all my cluster traffic go through a bastion?**
   - Yes → Mediated Topology
   - No → Direct Topology

3. **Are my cluster nodes on a 10.x.x.x network?**
   - Yes → Likely Mediated Topology
   - No → Likely Direct Topology

## Registry Implications

Both variants work with all registry strategies, but there are considerations:

### Bastion Registry Proxy

- **Mediated**: Natural fit, bastion already routes all traffic
- **Direct**: Works fine, bastion proxies registry traffic

### Public Registry

- **Mediated**: Requires bastion to allow outbound internet
- **Direct**: Direct internet access, no bastion dependency

### Internal Registry

- **Mediated**: Registry accessible via bastion
- **Direct**: Registry directly accessible

See [Prerequisites - Registry Strategy](prerequisites.md#registry-strategy-selection) for details.

## Switching Between Variants

!!! warning "Not Recommended"
    Switching variants after deployment requires redeploying workers and reconfiguring the main cluster. Plan your variant choice carefully.

If you must switch:

1. **Remove existing workers**
   ```bash
   # Scale the WorkerPool to 0 and wait for drain + VM deletion
   oc patch workerpool hci-workers \
     --type merge -p '{"spec":{"consumer":{"workers":{"count":0}}}}'
   # Then delete the WorkerPool CR — the operator cleans up remaining nodes
   oc delete workerpool hci-workers
   ```

2. **Remove old MachineConfigs**
   ```bash
   oc delete mcp hci-vm
   oc delete mc 99-hci-vm-kargs 99-master-s390x-hci-network-route 99-worker-s390x-hci-network-route --ignore-not-found
   ```

3. **Apply new variant**
   ```bash
   # Update integration-setup.yaml with the new topology and run:
   ./generate-setup

   # Or apply manually via overlay:
   # For Mediated Topology:
   oc apply -k main-cluster/configuration/overlays/mediated/
   
   # For Direct Topology:
   oc apply -k main-cluster/configuration/overlays/direct/
   ```

4. **Reconfigure networking** (bastion routes, DNS, etc.)

5. **Redeploy workers** by applying a new `WorkerPool` CR with the updated variant settings

## Troubleshooting by Variant

### Mediated Topology Issues

**Workers can't reach main cluster API:**
- Check bastion routing: `ip route | grep 192.168.100`
- Verify bastion firewall allows traffic
- Test from bastion: `ping 192.168.100.1`

**DNS resolution fails:**
- Check bastion DNS configuration
- Verify recursive queries allowed from 192.168.100.0/24
- Test: `nslookup worker-x86-1.cluster.example.com`

### Direct Topology Issues

**Masters can't reach workers:**
- Check master route: `oc debug node/<master> -- chroot /host ip route | grep 192.168.100`
- Verify MachineConfig applied: `oc get mc 99-master-s390x-hci-network-route`
- Check master pool status: `oc get mcp master`

**S390x workers can't reach HCI workers:**
- Check worker route: `oc debug node/<s390x-worker> -- chroot /host ip route | grep 192.168.100`
- Verify MachineConfig applied: `oc get mc 99-worker-s390x-hci-network-route`
- Check worker pool status: `oc get mcp worker`

**Route not persisting:**
- Check systemd service: `systemctl status hci-network-route.service`
- View logs: `journalctl -u hci-network-route.service`
- For masters, verify br-ex interface exists: `ip link show br-ex`

**Cross-architecture pod communication fails:**
- Verify routes on both master and s390x workers
- Test connectivity: `oc debug node/<s390x-worker> -- chroot /host ping 192.168.100.10`
- Check network policies aren't blocking traffic

## Architecture Flexibility

!!! note "Other Architectures"
    While this documentation focuses on s390x main clusters, both variants work with ARM or Power-based main clusters. The network topology (private vs public) is independent of CPU architecture.

## Summary

| Aspect | Mediated Topology | Direct Topology |
|--------|--------------|-------------|
| **Best For** | Private networks, mediated access | Public networks, direct access |
| **Bastion Role** | Central router | Optional |
| **Master Changes** | None | Static route added |
| **Worker Changes** | None | Static route added (s390x) |
| **Complexity** | Medium | Low-Medium |
| **Flexibility** | Less (bastion-dependent) | More (direct access) |
| **Security** | Higher (isolated) | Medium (exposed) |

**Recommendation**: Choose based on your existing network topology, not on preference. The variant should match how your main cluster is already deployed.

## Next Steps

After choosing your variant:

1. Review [Prerequisites](prerequisites.md) for your chosen variant
2. Follow [Getting Started](getting-started.md) guide
3. Apply the appropriate overlay: `overlays/mediated/` or `overlays/direct/`

## Support

- **Mediated Topology**: [Mediated overlay README](https://github.com/IBM/fusion-hci-integration/tree/main/main-cluster/configuration/overlays/mediated/README.md)
- **Direct Topology**: [Direct overlay README](https://github.com/IBM/fusion-hci-integration/tree/main/main-cluster/configuration/overlays/direct/README.md)
- **Issues**: [GitHub Issues](https://github.com/IBM/fusion-hci-integration/issues)