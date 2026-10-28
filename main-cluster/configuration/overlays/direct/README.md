# Direct Topology Overlay

## Description
Configuration for public network deployments where main cluster nodes have direct connectivity.
Commonly used in KVM, bare metal, or less restricted environments.

**Directory:** `overlays/direct/`

## Network Topology

```
┌─────────────────────────────────────┐
│ Main Cluster (s390x KVM)            │
│ Public Network: 172.16.x.x          │
│                                     │
│ ┌──────────┐  ┌──────────┐         │
│ │ Master 1 │  │ Master 2 │         │
│ │ (br-ex)  │  │ (br-ex)  │         │
│ └────┬─────┘  └────┬─────┘         │
└──────┼─────────────┼───────────────┘
       │             │
       │ Direct access to HCI network
       │
    ┌──▼─────────────▼──┐
    │ Gateway VM        │ 172.16.1.100
    │ (Same network)    │
    └───────┬───────────┘
            │
       ┌────▼─────┐
       │ Worker   │ 192.168.100.x
       │ VMs      │
       └──────────┘
```

## What's Included

- Base MachineConfigs (pool + kargs)
- **Master node static route** (99-master-s390x-hci-network-route.yaml)
- **S390x worker node static route** (99-worker-s390x-hci-network-route.yaml)

## Characteristics

- **Main cluster**: Public network (172.16.x.x)
- **Routing**: Direct connectivity
- **DNS**: Direct or via bastion
- **Gateway access**: Same network as main cluster

## What's Different

The Direct Topology adds MachineConfigs for both master and s390x worker nodes to create static routes to the HCI internal network (192.168.100.0/24).

**Master Route** (99-master-s390x-hci-network-route.yaml):
- Required for cluster management (CSR approval, scheduling, health checks)
- Waits for br-ex interface to be available
- Adds route: `192.168.100.0/24 via 172.16.1.100 dev br-ex`
- Persists across reboots

**S390x Worker Route** (99-worker-s390x-hci-network-route.yaml):
- Required for pod-to-pod communication across architectures
- Enables service endpoints spanning both worker types
- Adds route: `192.168.100.0/24 via 172.16.1.100`
- Only applies to s390x workers (via `node-platform: s390x` label)

## Prerequisites

1. Main cluster nodes on same network as HCI gateway (172.16.x.x)

2. Network connectivity verified between main cluster and HCI

3. Gateway VM IP address available in the shared network

## Apply Configuration

```bash
# From main-cluster/configuration/
kubectl apply -k overlays/direct/

# Or using oc
oc apply -k overlays/direct/
```

## Verify

```bash
# Check MachineConfigPool
oc get mcp workers-hci

# Check MachineConfigs (including master route)
oc get mc | grep hci

# Verify master route MachineConfig
oc get mc 99-master-s390x-hci-network-route

# Wait for workers-hci pool to be ready
oc wait --for=condition=Updated mcp/workers-hci --timeout=600s

# Wait for master pool to apply route (if masters need update)
oc get mcp master
```

## Verify Route on Master Nodes

After the master MachineConfig is applied:

```bash
# Check route on a master node
oc debug node/<master-node-name>
chroot /host
ip route | grep 192.168.100
# Should show: 192.168.100.0/24 via 172.16.1.100 dev br-ex
```

## Next Steps

After applying this configuration:

1. Verify firewall setup (see scripts/02-firewall-setup.sh)
2. Apply the `WorkerPool` CR (see docs/getting-started.md, step C.9) — the operators deploy the gateway VM and worker VMs
3. Workers will automatically join the cluster

## Troubleshooting

### Route not appearing on master nodes

Check the systemd service status:
```bash
oc debug node/<master-node-name>
chroot /host
systemctl status hci-network-route.service
journalctl -u hci-network-route.service
```

### Connectivity issues

Verify gateway VM is reachable from master:
```bash
oc debug node/<master-node-name>
chroot /host
ping 172.16.1.100  # Gateway external IP
ping 192.168.100.1  # Gateway internal IP (should work after route)