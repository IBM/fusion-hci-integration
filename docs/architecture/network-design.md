# Network Design

This document provides detailed information about the network architecture used in the Fusion HCI multi-architecture integration.

## Overview

The network design uses a dual-network approach with OVN-Kubernetes to provide:

- **External connectivity** to the main cluster network
- **Internal isolation** for HCI worker VMs
- **Gateway routing** between networks
- **DHCP and network boot services** for worker provisioning

!!! info "Nothing on this page is configured by hand"
    The networks, gateway VM configuration (addressing, routing, NAT, firewall,
    dnsmasq) and worker NICs described here are created by the operators from the
    values in `integration-setup.yaml`. The snippets show *what the operators set
    up* so that you can understand and troubleshoot it; they are not steps to
    execute. The only manual network step is the one-time external network on the
    HCI cluster (see [Localnet](#1-localnet-external-network)).

## Network Topologies

### OVN-Kubernetes Network Types

The integration uses two OVN-Kubernetes network topologies:

#### 1. Localnet (External Network)

**Purpose:** Connect gateway VM to physical network

**Characteristics:**
- Maps directly to physical network interface
- Provides external connectivity
- No OVN overlay encapsulation
- Direct Layer 2 access to physical network

**Configuration:**
```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: router-external-network
spec:
  namespaceSelector:
    matchLabels:
      hci-gateway-enabled: "true"
  network:
    topology: Localnet
    localnet:
      physicalNetworkName: localnet1
      role: Secondary
      mtu: 1500
      ipam:
        mode: Disabled  # no OVN IPAM; see IP Assignment Methods
```

**Key Points:**
- Cluster-scoped resource (one per HCI cluster), created once by the HCI cluster admin
  with `hci-cluster/cluster-network-setup.yaml`
  (see [Getting Started](../getting-started.md))
- Each integration namespace on the HCI cluster must carry the label
  `hci-gateway-enabled=true` to attach to it
- Requires physical network mapping on HCI nodes
- IPAM disabled - IPs are set statically on the gateway VM and via DHCP reservations for workers
- Multiple namespaces can use same network

#### 2. Layer2 (Internal Network)

**Purpose:** Isolated network for HCI worker VMs

**Characteristics:**
- Pure OVN logical switch
- No physical network mapping
- Isolated from HCI pod network
- Gateway VM provides routing

**Configuration:**
```yaml
apiVersion: k8s.ovn.org/v1
kind: UserDefinedNetwork
metadata:
  name: router-internal-network
  namespace: main-cluster-workers
spec:
  topology: Layer2
  layer2:
    role: Secondary
    ipam:
      mode: Disabled  # no OVN IPAM; see IP Assignment Methods
```

**Key Points:**
- Namespace-scoped resource, created per integration by `hci-provisioner`
  in `provider.namespace` (UDN step)
- Completely isolated from other networks
- No MTU is set; the OVN-Kubernetes default applies (see [MTU Considerations](#mtu-considerations))
- Gateway VM bridges to external network

## Network Addressing

### Address Allocation

All addresses, names and sizes on this page are the example values from
`templates/integration-setup.example.yaml`. The real values are set once in
`integration-setup.yaml`; see the field mapping in
[Architecture Overview](architecture-overview.md#configuration-input).

```
External Network (varies by deployment):
├── Mediated Topology: main cluster 10.0.0.0/24 (consumer.networking.internalNetwork)
├── Direct Topology: 172.16.0.0/16 (derived from provider.gateway.ip / prefixLength)
├── Bastion / DNS server: 172.16.0.1 (consumer.networking.dnsServer)
└── Gateway VM: 172.16.1.100 (provider.gateway.ip)

Internal Network (provider.networking.internalSubnet):
├── Network: 192.168.100.0/24
├── Gateway: 192.168.100.1 (network address + .1)
├── Workers: 192.168.100.10-19 (network address + .10, one per slot up to provider.maxPoolSize = 10)
└── Remainder: unused
```

### IP Assignment Methods

OVN IPAM is disabled on both networks. Addresses are assigned in two different ways:

#### Gateway VM: static configuration via cloud-init

The `hci-provisioner` renders the gateway's NetworkManager connections into its
cloud-init data. The external NIC gets the address from `provider.gateway.ip`:

```ini
# external connection (eth1), MAC 52:54:01:00:00:01
[ipv4]
method=manual
addresses=172.16.1.100/16        # provider.gateway.ip / prefixLength
gateway=172.16.0.1               # provider.gateway.defaultRouter
dns=172.16.0.1                   # consumer.networking.dnsServer
# mediated topology only:
route1=10.0.0.0/24,172.16.0.1    # consumer.networking.internalNetwork, internalGateway
```

The internal NIC (eth2) gets the first address of `provider.networking.internalSubnet`
(`192.168.100.1/24`).

#### Worker VMs: static DHCP reservations on the gateway

Worker VMs have no cloud-init. The gateway's `dnsmasq` runs DHCP in static-only mode,
with one reservation per possible worker slot (up to `provider.maxPoolSize`):

```bash
# /etc/dnsmasq.d/pxe.conf (generated)
dhcp-range=192.168.100.0,static
dhcp-option=3,192.168.100.1                # default gateway = gateway VM
dhcp-option=6,172.16.0.1                   # DNS = consumer.networking.dnsServer

# one pair per slot: MAC -> IP, and the hostname for that slot
dhcp-host=52:54:01:00:00:10,192.168.100.10,set:host1
dhcp-option=tag:host1,12,worker-x86-1.cluster.example.com
dhcp-host=52:54:01:00:00:11,192.168.100.11,set:host2
dhcp-option=tag:host2,12,worker-x86-2.cluster.example.com
# ... up to slot 10 (192.168.100.19)
```

**Advantages:**
- Predictable IP address and hostname per worker slot
- No dynamic lease pool to manage; scaling within the pool limit needs no gateway change
- No dependency on OVN IPAM
- Supports network boot

## Gateway VM Architecture

### Network Interfaces

The gateway VM has two network interfaces:

```
┌─────────────────────────────────────┐
│         Gateway VM                  │
│                                     │
│  ┌──────────────────────────────┐   │
│  │ eth1 (external)              │   │
│  │ - Localnet topology          │   │
│  │ - Physical network access    │   │
│  │ - IP: From external network  │   │
│  │ - MAC: 52:54:01:00:00:01     │   │
│  └──────────────────────────────┘   │
│                                     │
│  ┌──────────────────────────────┐   │
│  │ eth2 (internal)              │   │
│  │ - Layer2 topology            │   │
│  │ - OVN logical switch         │   │
│  │ - IP: 192.168.100.1/24       │   │
│  │ - MAC: 52:54:01:00:00:02     │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

### Routing Configuration

The gateway VM performs IP routing between networks:

```bash
# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Route to main cluster (example)
ip route add 10.0.0.0/24 via 172.16.0.1

# Default route via external gateway
ip route add default via 172.16.0.1
```

### NAT Configuration

Selective NAT for different traffic types:

```bash
# Transparent routing (no NAT) for main cluster
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 \
  -d 10.0.0.0/24 -j ACCEPT

# Transparent routing (no NAT) for external network
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 \
  -d 172.16.0.0/16 -j ACCEPT

# Masquerading (NAT) for internet
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 \
  -o eth1 -j MASQUERADE
```

**Why Selective NAT?**
- Main cluster needs to see real worker IPs for node management
- External network may need real IPs for monitoring/logging
- Internet traffic can use NAT for simplicity

## Routing Strategies

### Mediated Topology (Private Network)

```
Main Cluster (10.0.0.0/24)
         ↓
    Bastion Host
    (internal side on 10.0.0.0/24)
    (172.16.0.1 external)
         ↓
   Route: 192.168.100.0/24 via 172.16.1.100
         ↓
    Gateway VM
    (172.16.1.100 external)
    (192.168.100.1 internal)
         ↓
    Worker VMs
    (192.168.100.10+)
```

**Configuration:**
- Bastion routes to internal network
- No changes to main cluster nodes
- All traffic through bastion
- Selected with `consumer.networking.topology: mediated`; the bastion route
  (`main-cluster/scripts/01-add-route.sh`) and firewall
  (`02-firewall-setup.sh`) are driven by the values generated from
  `integration-setup.yaml` (`consumer.networking.internalNetwork`,
  `internalGateway`, `consumer.bastion.*`)

### Direct Topology (Public Network)

```
Main Cluster (172.16.0.0/16)
    ├── Masters
    │   └── Route: 192.168.100.0/24 via 172.16.1.100
    └── Workers (s390x)
        └── Route: 192.168.100.0/24 via 172.16.1.100
         ↓
    Gateway VM
    (172.16.1.100 external)
    (192.168.100.1 internal)
         ↓
    Worker VMs
    (192.168.100.10+)
```

**Configuration:**
- Direct connectivity to gateway VM
- Static routes on master nodes
- Static routes on s390x worker nodes
- No bastion routing needed
- Selected with `consumer.networking.topology: direct` (the default); the route
  MachineConfigs are generated by `generate-setup` from `provider.gateway.ip` and
  `provider.networking.internalSubnet`, and are created by the `hci-consumer`
  operator if absent

## DNS Configuration

### DNS Resolution Flow

Workers receive the main cluster DNS server directly through DHCP (option 6). Their
queries are routed through the gateway VM like any other traffic to the main cluster
network:

```
Worker VM
    ↓ Query: api-int.cluster.example.com  (DNS server from DHCP)
Gateway VM (routes the packet)
    ↓
Main Cluster DNS (consumer.networking.dnsServer)
    ↓ Response, same path back
Worker VM
```

### Gateway VM DNS Configuration

The gateway's own `dnsmasq` also forwards to the main cluster DNS:

```bash
# /etc/dnsmasq.d/pxe.conf (generated)
no-resolv
server=172.16.0.1           # consumer.networking.dnsServer
domain=cluster.example.com  # consumer.domain
```

### Worker VM DNS Configuration

Worker VMs have no cloud-init. DNS server, search domain and hostname come from the
gateway's DHCP reservation:

```bash
dhcp-option=6,172.16.0.1                   # DNS server
domain=cluster.example.com                 # DHCP option 15, search domain
dhcp-option=tag:host1,12,worker-x86-1.cluster.example.com   # hostname
```

## DHCP and Network Boot

### DHCP Configuration

The gateway VM provides DHCP for worker VMs in static-only mode: there is no dynamic
address pool, only one reservation per worker slot. See
[IP Assignment Methods](#ip-assignment-methods) for the generated configuration.

### Network Boot Configuration

Worker VMs boot via iPXE. `dnsmasq` serves the first-stage loader over TFTP and
points iPXE to an HTTP boot script, `nginx` serves everything else:

```bash
# /etc/dnsmasq.d/pxe.conf (generated, excerpt)
enable-tftp
tftp-root=/var/lib/tftpboot
tftp-secure

# first request (native PXE firmware): iPXE loader over TFTP
# second request (iPXE announces itself with DHCP option 175): HTTP boot script
dhcp-match=set:ipxe,175
dhcp-boot=tag:!ipxe,undionly.kpxe
dhcp-boot=tag:ipxe,http://192.168.100.1/boot.ipxe
```

```
/var/lib/tftpboot/undionly.kpxe          iPXE loader (TFTP)
/var/www/html/boot.ipxe                  boot script (HTTP, port 80)
/var/www/html/rhcos/rhcos-live-*         RHCOS kernel, initramfs, rootfs (HTTP)
/var/www/html/rhcos/worker-hci.ign       ignition stub (HTTP)
```

The RHCOS files are downloaded by the gateway from the OpenShift mirror for the stream
requested by the operator.

### Boot Process

1. Worker VM powers on and requests DHCP
2. Gateway VM answers with the reserved IP, hostname and `undionly.kpxe`
3. The firmware loads `undionly.kpxe` via TFTP and starts iPXE
4. iPXE requests DHCP again and is pointed to `http://192.168.100.1/boot.ipxe`
5. `boot.ipxe` shows a 10-second menu; with an empty disk it installs RHCOS
6. iPXE loads the RHCOS live kernel and initramfs over HTTP
7. The installer fetches `worker-hci.ign` and writes RHCOS to disk
8. The worker reboots from disk and joins the cluster

The detailed sequence is in [VM Provisioning](vm-provisioning.md#phase-2-network-boot-ipxe).

## Network Security

### Firewall Rules

Gateway VM firewall configuration (set by the cloud-init data, excerpt):

```bash
# Interfaces and zones
firewall-cmd --permanent --zone=external --add-interface=eth1
firewall-cmd --permanent --zone=internal --add-interface=eth2

# Forwarding between the internal and external side
firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -i eth2 -o eth1 -j ACCEPT
firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -i eth1 -o eth2 -j ACCEPT

# Services on the internal side: network boot and ignition
firewall-cmd --permanent --zone=internal --add-service=dhcp
firewall-cmd --permanent --zone=internal --add-service=tftp
firewall-cmd --permanent --zone=internal --add-service=http

# SSH (management)
firewall-cmd --permanent --zone=external --add-service=ssh
firewall-cmd --permanent --zone=internal --add-service=ssh
```

The NAT rules shown under [NAT Configuration](#nat-configuration) are added the same way.

### Network Policies

!!! note "Optional hardening, not created by the operators"
    The operators do not create any `NetworkPolicy`. The example below only shows
    what an administrator could add on top; adapt the labels (the gateway VM is named
    `hci-gateway`) before using it.

Standard Kubernetes network policies (enforced by OVN-Kubernetes) can restrict traffic:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-only
spec:
  podSelector:
    matchLabels:
      app: worker-vm
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: gateway-vm
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: gateway-vm
```

## MTU Considerations

### MTU Sizing

```
Physical Network: 1500 (standard Ethernet)
    ↓
Localnet (external): 1500 (set in cluster-network-setup.yaml, no encapsulation)
    ↓
Layer2 (internal): OVN-Kubernetes default (no MTU set by the provisioner)
```

### Why the Internal Network May Need a Lower MTU

- OVN adds encapsulation headers (Geneve) on the internal Layer2 network
- Typical overhead: 50-100 bytes
- The operators neither set an MTU on the internal network nor send an MTU to the
  workers via DHCP

### MTU Configuration

The external network MTU is set once in
`hci-cluster/cluster-network-setup.yaml`:

```yaml
localnet:
  mtu: 1500
```

If your environment requires a specific MTU on the internal network, verify the effective
value on the `UserDefinedNetwork` and inside a worker VM after the first worker is up.

## Performance Optimization

### Network Throughput

**Gateway VM as Bottleneck:**
- VM network throughput: ~10 Gbps typical
- Physical network: 25-50 Gbps available
- Gateway VM is limiting factor

**Mitigation:**
- Increase gateway VM vCPU allocation
- Use multiple gateway VMs for HA/load balancing
- Enable virtio network drivers
- Consider SR-IOV for high-performance scenarios

### Latency Optimization

**Typical Latencies:**
- Physical network: <0.1ms
- OVN overlay: +0.2-0.5ms
- Gateway VM routing: +0.5-1ms
- Total: ~1-2ms additional latency

**Optimization:**
- Place gateway VM on low-latency nodes
- Use CPU pinning for gateway VM
- Enable NUMA awareness
- Minimize network hops

## High Availability

!!! warning "Not implemented"
    The operators create exactly one gateway VM per integration (`hci-gateway`). The
    multi-gateway layout below is a design option; Gateway VM HA is listed under
    Future Enhancements in the [Architecture Overview](architecture-overview.md).

### Multiple Gateway VMs

A redundant design would use multiple gateway VMs:

```yaml
# Gateway VM 1
external: 172.16.1.100
internal: 192.168.100.1

# Gateway VM 2
external: 172.16.1.101
internal: 192.168.100.2
```

**Load Balancing Options:**
1. Round-robin DNS
2. VRRP (keepalived)
3. BGP routing
4. External load balancer

### Failover Scenarios

**Gateway VM Failure:**
1. Detect failure (health check)
2. Promote backup gateway
3. Update routing tables
4. Workers reconnect automatically

**Network Failure:**
1. OVN detects link down
2. Reroutes traffic if alternate path exists
3. Alerts monitoring system

## Monitoring

### Key Metrics

**Gateway VM:**
- Network throughput (in/out)
- Packet loss rate
- NAT connection table size
- CPU utilization
- Memory utilization

**Network Health:**
- Latency between networks
- Packet loss percentage
- MTU path discovery results
- DNS resolution time

### Monitoring Tools

```bash
# Network throughput
iftop -i eth1

# Packet loss
ping -c 100 192.168.100.10 | grep loss

# NAT connections
conntrack -L | wc -l

# DNS performance
dig @192.168.100.1 api.cluster.example.com +stats
```

## Troubleshooting

### Common Issues

**Workers can't reach main cluster:**
- Check gateway VM routing table
- Verify NAT rules (should NOT NAT cluster traffic)
- Test connectivity from gateway VM
- Check firewall rules

**DNS resolution fails:**
- Verify gateway VM DNS forwarder configuration
- Check main cluster DNS server accessibility
- Test DNS from gateway VM
- Verify worker VM DNS configuration

**Network boot fails:**
- Check `dnsmasq` (DHCP and TFTP) and `nginx` (HTTP) on the gateway VM
- Check that the worker's MAC address has a `dhcp-host` reservation
- Check `undionly.kpxe` in the TFTP root and `boot.ipxe` in the HTTP root
- Check that the RHCOS boot files and `current-version.txt` exist under `/var/www/html/rhcos/`
- Verify network connectivity during boot

See [Troubleshooting Guide](../operations/troubleshooting.md) for detailed solutions.

## Best Practices

### Network Design

1. **Use static IPs for gateway VM** - Ensures consistent routing
2. **Document IP allocations** - Maintain IP address inventory
3. **Plan for growth** - Reserve IP ranges for future workers
4. **Monitor network performance** - Establish baselines

### Security

1. **Minimize exposed services** - Only open required ports
2. **Use network policies** - Restrict traffic where possible
3. **Regular security audits** - Review firewall rules
4. **Encrypt sensitive traffic** - Use TLS for management

### Operations

1. **Automate configuration** - Let the operators generate the gateway configuration from `integration-setup.yaml`
2. **Test failover scenarios** - Verify HA works
3. **Monitor continuously** - Set up alerts
4. **Document changes** - Keep network diagrams updated

## References

- [Architecture Overview](architecture-overview.md)
- [Deployment Variants](../deployment-variants.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [OVN-Kubernetes Documentation](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)