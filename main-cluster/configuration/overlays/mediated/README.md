# Mediated Topology Overlay

## Description
Configuration for private network deployments where main cluster nodes are behind a bastion.
Commonly used in z/VM, LPAR, or highly secured environments.

**Directory:** `overlays/mediated/`

## Network Topology

```
┌─────────────────────────────────────┐
│ Main Cluster (s390x z/VM)           │
│ Private Network: 10.x.x.x           │
│                                     │
│ ┌─────────────┐                     │
│ │ Bastion     │ 172.16.0.1          │
│ │ (Public IP) │                     │
│ └──────┬──────┘                     │
└────────┼────────────────────────────┘
         │
         │ Routes traffic to HCI workers
         │
    ┌────▼─────┐
    │ Gateway  │ 172.16.1.100
    │ VM       │
    └──────────┘
         │
    ┌────▼─────┐
    │ Worker   │ 192.168.100.x
    │ VMs      │
    └──────────┘
```

## What's Included

- Base MachineConfigs (pool + kargs)
- No additional resources needed

## Characteristics

- **Main cluster**: Private network (10.x.x.x)
- **Routing**: Via bastion host
- **DNS**: Bastion provides resolution
- **Gateway access**: Through bastion's public IP

## Prerequisites

1. Bastion configured with route to HCI network:
   ```bash
   ip route add 192.168.100.0/24 via 172.16.1.100
   ```

2. DNS entries for HCI workers in bastion's DNS server

3. Firewall rules allowing traffic between bastion and HCI gateway

## Apply Configuration

```bash
# From main-cluster/configuration/
kubectl apply -k overlays/mediated/

# Or using oc
oc apply -k overlays/mediated/
```

## Verify

```bash
# Check MachineConfigPool
oc get mcp workers-hci

# Check MachineConfigs
oc get mc | grep hci

# Wait for workers-hci pool to be ready
oc wait --for=condition=Updated mcp/workers-hci --timeout=600s
```

## Next Steps

After applying this configuration:

1. Configure bastion route (see scripts/01-add-route.sh)
2. Verify firewall setup (see scripts/02-firewall-setup.sh)
3. Apply the `WorkerPool` CR (see docs/getting-started.md, step C.9) — the operators deploy the gateway VM and worker VMs
4. Workers will automatically join the cluster