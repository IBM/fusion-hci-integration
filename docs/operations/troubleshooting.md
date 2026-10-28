# Troubleshooting Guide

This guide covers common issues encountered when deploying and operating the Fusion HCI multi-architecture integration, along with their solutions.

!!! info "Troubleshooting and the Setup Guide"
    Most initial setup issues trace back to specific steps in the
    [Setup Guide](../getting-started.md). When debugging, verify the corresponding
    stage and automated resources:

    | Issue area | Setup Guide step / Component | Key resources & logs |
    |---|---|---|
    | [Gateway VM & CUDN / NAD](#vm-deployment-issues) | [Tier A](../getting-started.md#tier-a-hci-cluster-wide-setup), [Tier B](../getting-started.md#tier-b-hci-per-integration-setup) | `ClusterUserDefinedNetwork`, `UserDefinedNetwork`, `vmi/hci-gateway` |
    | [DNS & Bastion routing](#dns-and-routing-issues) | [C.1](../getting-started.md#c1-configure-dns-on-the-bastion), [C.2](../getting-started.md#c2-configure-bastion-routing-and-firewall-mediated-topology-only) | Bastion `named`, `ip route`, `iptables` |
    | [Direct topology routes](#3-master-nodes-cannot-reach-workers-direct-topology) | [C.4](../getting-started.md#c4-apply-machineconfigs) | `99-master-s390x-hci-network-route`, `99-worker-s390x-hci-network-route` |
    | [Worker boot & PXE](#vm-fails-to-boot-from-pxe) | [C.8](../getting-started.md#c8-build-and-deploy-the-operators), [C.9](../getting-started.md#c9-apply-the-workerpool-cr) | Gateway `dnsmasq`, `nginx`, `rhcos-sync.service` |
    | [Node joining & CSRs](#node-join-issues) | [C.8](../getting-started.md#c8-build-and-deploy-the-operators) | `csr-approver`, `node-labeler`, `mcp/hci-vm` |

## Table of Contents

- [Network Issues](#network-issues)
- [VM Deployment Issues](#vm-deployment-issues)
- [Node Join Issues](#node-join-issues)
- [DNS and Routing Issues](#dns-and-routing-issues)
- [Multi-Namespace Deployment Issues](#multi-namespace-deployment-issues)
- [Diagnostic Commands](#diagnostic-commands)
- [Gateway Verification](#gateway-verification)

## Network Issues

### Worker VM Has Dual Network Conflict

**Symptoms:**
- Worker VM has two active interfaces (enp1s0 and enp2s0)
- Dual default routes causing routing conflicts
- DNS resolution fails or returns wrong results
- Node cannot reach main cluster API

**Root Cause:**
The worker VM has two network interfaces:
- **enp1s0**: Connected to HCI cluster's Pod network (should be disabled)
- **enp2s0**: Connected to main cluster network (should be active)

Both interfaces receive DHCP configuration, creating conflicts.

**Solution:**

The `99-hci-vm-kargs` MachineConfig (and the iPXE boot command) disables `enp1s0` and configures `enp2s0` via kernel arguments:

```yaml
# 99-hci-vm-kargs (created automatically by the hci-consumer operator)
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

During installation, the iPXE boot command on the gateway also supplies `coreos.inst.karg=ip=enp1s0:off coreos.inst.karg=ip=enp2s0:dhcp` so that RHCOS installs and boots with the correct interface active.

**Verification:**
```bash
# Debug worker node
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/worker-x86-1
chroot /host

# Check interface status
ip link show enp1s0  # Should be DOWN or unconfigured
ip link show enp2s0  # Should be UP

# Check IP addresses
ip addr show enp1s0  # Should have no IP
ip addr show enp2s0  # Should have 192.168.100.x

# Check routes
ip route show  # Should only show routes via enp2s0 (192.168.100.1 gateway)

# Check DNS
cat /etc/resolv.conf  # Should show main cluster DNS (172.16.0.1)
```

### OVN-Kubernetes br-ex Bridge Conflict

**Symptoms:**
- OVN-Kubernetes creates br-ex bridge on wrong interface (enp1s0)
- Default route appears on br-ex instead of enp2s0
- Worker cannot reach main cluster API
- DNS resolution uses wrong DNS server

**Root Cause:**
OVN-Kubernetes automatically selects the first available network interface for the external bridge (br-ex). In HCI workers, it incorrectly chooses enp1s0 instead of enp2s0.

**Solution:**

Force OVN to use enp2s0 for br-ex:

```yaml
# In MachineConfig
storage:
  files:
    - path: /etc/systemd/system/ovs-configuration.service.d/override.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [Service]
          Environment="OVN_KUBERNETES_EXTERNAL_INTERFACE=enp2s0"
```

**Verification:**
```bash
# Check OVN interface selection
systemctl cat ovs-configuration.service | grep OVN_KUBERNETES_EXTERNAL_INTERFACE

# Check br-ex is using enp2s0
ovs-vsctl show | grep -A 5 br-ex

# Should show enp2s0 as port, not enp1s0
```

### Gateway VM Gets Wrong IP Address (IPAM Issue)

**Symptoms:**
- Gateway VM receives a dynamic IP (e.g. `172.16.0.2`) instead of the requested static IP (`172.16.1.100`)
- Network conflicts or routing mismatches with bastion
- Workers cannot reach main cluster through the gateway

**Root Cause:**
ClusterUserDefinedNetwork with Localnet topology does not honor static IP addresses specified in pod annotations. OVN's IPAM for localnet networks assigns IPs sequentially from the subnet.

**Solution:**

The gateway VM configures its static IP via cloud-init network configuration (handled automatically by the `hci-provisioner` operator using `gateway-vm-cloudinit.j2`):

```yaml
# Inside gateway-vm-cloudinit Secret (rendered by operator)
apiVersion: v1
kind: Secret
metadata:
  name: gateway-vm-cloudinit
stringData:
  networkdata: |
    version: 2
    ethernets:
      external:
        match:
          macaddress: "52:54:01:00:00:01"
        addresses:
          - 172.16.1.100/16
        gateway4: 172.16.0.1
        nameservers:
          addresses:
            - 172.16.0.1
      internal:
        match:
          macaddress: "52:54:01:00:00:02"
        addresses:
          - 192.168.100.1/24
```

**Why This Works:**
- Cloud-init configures the static IP and MAC matching directly inside the VM
- No dependency on OVN IPAM for the external physical interface
- Standard approach for physical network attachment
- Gateway has full control over its external and internal routing

**Verification:**
```bash
# Check gateway VM status
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} hci-gateway

# SSH to gateway VM
ssh core@172.16.1.100

# Inside VM: check IP addresses
ip addr show
# Should show 172.16.1.100 on external interface (eth1)
# Should show 192.168.100.1 on internal interface (eth2)
```

## VM Deployment Issues

### VM Stuck in ContainerCreating

**Symptoms:**
- virt-launcher pod stuck in ContainerCreating for hours
- VM never starts
- Pod events show network attachment errors

**Possible Causes:**

#### 1. Wrong NetworkAttachmentDefinition Reference

**Error Message:**
```
failed to get pod annotation: timed out waiting for annotations: context deadline exceeded
```

**Check:**
```bash
# Get NAD configuration
oc --context ${HCI_CLUSTER_CONTEXT} get nad router-external-network -n ${HCI_INTEGRATION_NAMESPACE} -o jsonpath='{.spec.config}' | jq .

# Check netAttachDefName field
# Should be: "${HCI_INTEGRATION_NAMESPACE}/router-external-network"
# NOT: "other-namespace/router-external-network"
```

**Solution:**
See [Multi-Namespace Deployment Issues](#multi-namespace-deployment-issues)

#### 2. Missing ClusterUserDefinedNetwork

**Check:**
```bash
# Verify ClusterUserDefinedNetwork exists on HCI
oc --context ${HCI_CLUSTER_CONTEXT} get clusteruserdefinednetwork router-external-network

# Verify namespace is labeled
oc --context ${HCI_CLUSTER_CONTEXT} get namespace ${HCI_INTEGRATION_NAMESPACE} --show-labels | grep hci-gateway-enabled
```

**Solution:**
```bash
# Apply cluster-admin network setup (Setup Guide A.2)
oc --context ${HCI_CLUSTER_CONTEXT} apply -f hci-cluster/cluster-network-setup.yaml

# Label namespace (Setup Guide B.1)
oc --context ${HCI_CLUSTER_CONTEXT} label namespace ${HCI_INTEGRATION_NAMESPACE} hci-gateway-enabled=true
```

#### 3. OVN Controller Issues

**Check:**
```bash
# Check OVN controller logs on HCI
oc --context ${HCI_CLUSTER_CONTEXT} logs -n openshift-ovn-kubernetes -l app=ovnkube-node --tail=100 | grep -i error

# Check for NAD creation
oc --context ${HCI_CLUSTER_CONTEXT} get nad -n ${HCI_INTEGRATION_NAMESPACE}
```

**Solution:**
Wait for OVN controller to create NAD (usually 1-2 minutes after namespace labeling).

### VM Fails to Boot from PXE

**Symptoms:**
- VM starts but doesn't PXE boot
- Console shows "No bootable device" or iPXE timeout
- DHCP requests not answered

**Possible Causes:**

#### 1. Gateway VM Not Running

**Check:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} hci-gateway
# Should show "Running"
```

**Solution:**
```bash
# Check virt-launcher pod logs
oc --context ${HCI_CLUSTER_CONTEXT} logs -n ${HCI_INTEGRATION_NAMESPACE} -l kubevirt.io/domain=hci-gateway

# Restart if needed
virtctl restart hci-gateway -n ${HCI_INTEGRATION_NAMESPACE}
```

#### 2. DHCP/PXE Service Not Running

**Check:**
```bash
# SSH to gateway VM
ssh core@<gateway-external-ip>

# Check dnsmasq and nginx
systemctl status dnsmasq nginx
journalctl -u dnsmasq -n 50
```

**Solution:**
```bash
# Restart services
sudo systemctl restart dnsmasq nginx

# Check static DHCP reservations
cat /etc/dnsmasq.d/pxe.conf
```

#### 3. Network Connectivity Issue

**Check:**
```bash
# From gateway VM, test internal network
ping 192.168.100.10  # Worker IP

# Check firewall rules
sudo iptables -L -n -v | grep 192.168.100
```

#### 4. RHCOS Boot Files Missing or Downloading

**Check:**
```bash
# SSH to gateway VM
ssh core@<gateway-external-ip>

# Verify boot files exist in webroot
ls -lh /var/www/html/rhcos/

# Check sync timer status
systemctl status rhcos-sync.service
```

## Node Join Issues

### Worker Node Doesn't Appear in Cluster

**Symptoms:**
- Worker VM boots successfully
- RHCOS installed
- Node doesn't appear in `oc get nodes`

**Diagnostic Steps:**

```bash
# 1. Check if node is trying to join
oc --context ${MAIN_CLUSTER_CONTEXT} get csr | grep Pending

# 2. Access worker node (via debug or SSH from bastion)
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/worker-x86-1  # If visible
# Or: ssh core@192.168.100.10 (from bastion)
# Or: virtctl console worker-x86-1 -n ${HCI_INTEGRATION_NAMESPACE}

# 3. Check kubelet status
chroot /host
systemctl status kubelet
journalctl -u kubelet -n 100

# 4. Check machine-config-daemon
systemctl status machine-config-daemon
journalctl -u machine-config-daemon -n 100
```

**Common Issues:**

#### 1. CSR Not Approved

The `csr-approver` container in the `hci-consumer-operator` pod automatically approves both bootstrap and node-serving CSRs for nodes matching the configured prefix, internal subnet, and `amd64` architecture.

**Manual Approval (if approver is not running):**
```bash
# Approve pending CSRs
oc --context ${MAIN_CLUSTER_CONTEXT} get csr -o name | xargs oc --context ${MAIN_CLUSTER_CONTEXT} adm certificate approve
```

#### 2. Cannot Reach API Server

**Check:**
```bash
# From worker node
curl -k https://api.cluster.example.com:6443/version
```

**Solution:**
- Verify DNS resolution
- Check routing (see [DNS and Routing Issues](#dns-and-routing-issues))
- Verify gateway VM is routing correctly

#### 3. Stale `kube-apiserver-lb-signer` CA Bundle (MCP Created Long Before First Worker)

**Symptoms:**

- Worker installs RHCOS and boots successfully
- kubelet cannot register with the API server
- SSH to the worker (`ssh core@worker-x86-<n>` from the bastion) shows:

```bash
journalctl -b | grep -i "22623\|mcs\|ignition\|tls" | tail -30
# x509: certificate signed by unknown authority (possibly because of
# "crypto/rsa: verification error" while trying to verify candidate
# authority certificate "kube-apiserver-lb-signer")
```

**Root cause:**

The `rendered-hci-vm` MachineConfig is generated by the MCO when the
`hci-vm` MachineConfigPool is first created. It bakes in the current
`kube-apiserver-lb-signer` CA bundle at that point in time. If a
significant amount of time passes between MCP creation and the first
worker actually joining the pool, the cluster's lb-signer certificate
rotates — but the MCO does not re-render an empty pool (no nodes = no
trigger). Workers that boot and receive the stale `rendered-hci-vm`
apply the old CA bundle and kubelet can no longer verify the API server
certificate.

Once the MCP is current, additional workers can join at any later time:
the MCO keeps the rendered MC up to date for pools that have at least one
node, so the bundle stays current going forward.

**Fix:**

```bash
# 1. Scale the WorkerPool down to zero (removes all worker VMs cleanly)
oc --context ${MAIN_CLUSTER_CONTEXT} patch workerpool hci-workers -n ${MAIN_INTEGRATION_NAMESPACE} \
  --type=merge -p '{"spec":{"consumer":{"workers":{"count":0}}}}'

# Wait for all VMs to be gone
oc --context ${HCI_CLUSTER_CONTEXT} get vm -n ${HCI_INTEGRATION_NAMESPACE} -w

# 2. Delete the MCP and its source MachineConfig
#    The hci-consumer operator recreates them on the next reconcile,
#    causing the MCO to render a fresh rendered-hci-vm with the current
#    kube-apiserver-lb-signer bundle.
oc --context ${MAIN_CLUSTER_CONTEXT} delete mcp hci-vm
oc --context ${MAIN_CLUSTER_CONTEXT} delete mc 99-hci-vm-kargs

# 3. Wait for the operator to recreate the MCP and for the MCO to render
oc --context ${MAIN_CLUSTER_CONTEXT} get mc -w | grep rendered-hci-vm          # wait for new rendered-hci-vm
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp hci-vm -o jsonpath='{.status.configuration.name}'  # must be non-empty

# 4. Verify the MCS now serves the config without error
curl -sk https://api-int.${MAIN_CLUSTER_DOMAIN}:22623/config/hci-vm \
  | jq .ignition.version

# 5. Scale back up — start with one canary worker to confirm
oc --context ${MAIN_CLUSTER_CONTEXT} patch workerpool hci-workers -n ${MAIN_INTEGRATION_NAMESPACE} \
  --type=merge -p '{"spec":{"consumer":{"workers":{"count":1}}}}'

# Once worker-x86-1 is Ready, scale to the desired count
oc --context ${MAIN_CLUSTER_CONTEXT} patch workerpool hci-workers -n ${MAIN_INTEGRATION_NAMESPACE} \
  --type=merge -p '{"spec":{"consumer":{"workers":{"count":3}}}}'
```

#### 4. Machine Config Daemon Stuck

**Check:**
```bash
journalctl -u machine-config-daemon-pull.service -f
```

**Common causes:**
- Cannot pull images (check internet connectivity)
- Cannot reach image registry
- Disk space issues

**Solution:**
```bash
# Check disk space
df -h

# Test image pull
podman pull quay.io/openshift-release-dev/ocp-release:latest

# Check registry connectivity
curl -v https://quay.io
```

### Node Stuck in NotReady State

**Symptoms:**
- Node appears in cluster
- Status shows NotReady
- Pods cannot be scheduled

**Check:**
```bash
# Get node details
oc describe node worker-x86-1

# Look for conditions
oc get node worker-x86-1 -o jsonpath='{.status.conditions[*].message}'
```

**Common Issues:**

#### 1. CNI Not Ready

**Solution:**
```bash
# Check OVN pods on node
oc get pods -n openshift-ovn-kubernetes -o wide | grep worker-x86-1

# Check logs
oc logs -n openshift-ovn-kubernetes <ovn-pod-name>
```

#### 2. Container Runtime Issues

**Solution:**
```bash
# SSH to node
oc debug node/worker-x86-1
chroot /host

# Check CRI-O
systemctl status crio
journalctl -u crio -n 100
```

### WorkerPool Stuck in ScalingUp Although All Workers Are Ready

**Symptoms:**
- `oc get workerpool -n hci-node-manager` shows `phase: ScalingUp` indefinitely
- `status.deployedWorkers` equals `spec.consumer.workers.count`, but `status.readyWorkers: 0`
- All `worker-x86-*` nodes are `Ready` and report `kubernetes.io/arch=amd64`
- The x86 nodes do **not** carry the `node-role.kubernetes.io/hci-vm` label
- `oc get mcp hci-vm` shows `MACHINECOUNT 0`; the x86 nodes are counted in the `worker` pool instead
- The WorkerPool may still show the stale condition `WorkerReconcileActive=False / BootstrapInProgress`, even though the `WorkerPoolProvisioning` CR is `Complete`. This condition is left over from the first reconcile and does not mean anything here.

**Background:**

The operator counts a node as ready only when the node name matches `<namePrefix>-*` **and** the node has the MCP role label `node-role.kubernetes.io/<machineConfigPool>`. The `node-labeler` sidecar in the `hci-consumer-operator` pod adds this label. It reads its config from the `hci-node-manager-config` ConfigMap, which the operator writes on its first WorkerPool reconcile.

**Root cause in older images (fixed by OPS-08):**

Older `node-labeler` versions read `TARGET_NETWORK` **only once, at startup**. If the operator pod started before a WorkerPool CR existed, which is the normal order on a fresh install, the ConfigMap was missing. The labeler then fell back to `192.168.100.0/24` and kept that value for the lifetime of the pod.

Current images re-read the ConfigMap every ~30 s and fix themselves. If the symptom still shows up with a current image, the most likely cause is a mismatch between `TARGET_NETWORK` / `NODE_NAME_PATTERN` and the actual node IPs/names. Check the labeler's debug output and compare the ConfigMap with the node list.

**Check:**
```bash
# Check node-labeler logs
oc --context ${MAIN_CLUSTER_CONTEXT} logs -n ${MAIN_INTEGRATION_NAMESPACE} deploy/hci-consumer-operator -c node-labeler | grep -E "fallback|Target network|Labeling"
# Healthy output:
#   Labeling active: network=192.168.100.0/24, name pattern=worker-x86-.*, arch=amd64

# Network the labeler should be using
oc --context ${MAIN_CLUSTER_CONTEXT} get cm hci-node-manager-config -n ${MAIN_INTEGRATION_NAMESPACE} -o jsonpath='{.data.TARGET_NETWORK}{"\n"}'

# Nodes missing the role label
oc --context ${MAIN_CLUSTER_CONTEXT} get nodes -l 'kubernetes.io/arch=amd64,!node-role.kubernetes.io/hci-vm'
```

**Solution:**

```bash
# Option A (preferred): restart the operator pod to force a re-scan
oc --context ${MAIN_CLUSTER_CONTEXT} rollout restart deployment/hci-consumer-operator -n ${MAIN_INTEGRATION_NAMESPACE}
oc --context ${MAIN_CLUSTER_CONTEXT} rollout status deployment/hci-consumer-operator -n ${MAIN_INTEGRATION_NAMESPACE}

# Option B: label the nodes manually
oc --context ${MAIN_CLUSTER_CONTEXT} label node <worker-x86-N>.<cluster-domain> node-role.kubernetes.io/hci-vm= --overwrite
```

> **Note:** Once labelled, the nodes move from the `worker` MCP to the `hci-vm` MCP. HCI workers boot from `/config/hci-vm` and already run the `rendered-hci-vm-*` config. Check this with the node annotation `machineconfiguration.openshift.io/currentConfig`. If it already shows `rendered-hci-vm-*`, labelling triggers **no** MCO update and **no** reboot. If it shows `rendered-worker-*`, MCO applies the `hci-vm` config and reboots the nodes one at a time (`maxUnavailable: 1`).
>
> ⚠️ Never put `hci-vm` on s390x nodes. The `hci-vm` config carries x86-VM kernel arguments and would make them unbootable. Current labeler images enforce this through a name + arch guard.

**Verify:**
```bash
oc --context ${MAIN_CLUSTER_CONTEXT} get nodes -l node-role.kubernetes.io/hci-vm
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp hci-vm                       # MACHINECOUNT == worker count
oc --context ${MAIN_CLUSTER_CONTEXT} get workerpool -n ${MAIN_INTEGRATION_NAMESPACE}   # phase: Ready, readyWorkers == count
```


## DNS and Routing Issues

### DNS Resolution Fails

**Symptoms:**
- Cannot resolve cluster hostnames
- Cannot resolve internet hostnames
- Intermittent resolution failures

**Diagnostic Steps:**

```bash
# From worker node
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/worker-x86-1
chroot /host

# Check DNS configuration
cat /etc/resolv.conf

# Test DNS resolution
dig api.cluster.example.com
dig quay.io

# Test DNS server directly
dig @172.16.0.1 api.cluster.example.com
```

**Common Issues:**

#### 1. Wrong DNS Server

**Expected:**
```
nameserver 172.16.0.1
search cluster.example.com
```

**Solution:**
Verify the DHCP server (`dnsmasq`) on the gateway VM is advertising `dhcp-option=option:dns-server,172.16.0.1` and `dhcp-option=option:domain-search,cluster.example.com`.

#### 2. DNS Server Not Allowing Recursion

**Check:**
```bash
# On bastion/DNS server (172.16.0.1)
# Check named configuration
grep -r "allow-recursion" /etc/named*

# Should include internal worker network and mediated network
allow-recursion { localhost; 10.0.0.0/24; 192.168.100.0/24; 172.16.0.0/16; };
```

**Solution:**
Update DNS server configuration to allow recursion from worker network.

### Routing Issues

**Symptoms:**
- Cannot reach main cluster API
- Cannot reach internet
- Packets not being forwarded

**Diagnostic Steps:**

```bash
# From worker node
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/worker-x86-1
chroot /host

# Check routing table
ip route show

# Test connectivity
ping -c 3 192.168.100.1  # Gateway
ping -c 3 api.cluster.example.com
ping -c 3 8.8.8.8  # Internet

# Trace route
traceroute api.cluster.example.com
```

**Common Issues:**

#### 1. Missing Default Route

**Solution:**
```bash
# Check if default route exists
ip route show default

# If missing, check DHCP
journalctl -u NetworkManager | grep DHCP
```

#### 2. Gateway Not Routing (Mediated Topology)

**Check:**
```bash
# On bastion
ip route | grep 192.168.100

# Should show route to HCI internal network via gateway external IP
```

**Solution:**
```bash
# Add route on bastion (Setup Guide C.2 / 01-add-route.sh)
sudo ip route add 192.168.100.0/24 via 172.16.1.100

# Make persistent
sudo nmcli connection modify <conn-name> +ipv4.routes "192.168.100.0/24 172.16.1.100"
```

#### 3. Master Nodes Cannot Reach Workers (Direct Topology)

**Symptoms:**
- CSRs not being approved
- Node status updates delayed
- Pods cannot be scheduled

**Check:**
```bash
# From master node
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/<master-node>
chroot /host

# Check route to HCI network
ip route | grep 192.168.100

# Test connectivity
ping -c 3 192.168.100.10
```

**Solution:**
Verify MachineConfig for master route is applied (Setup Guide C.4):

```bash
# Check MachineConfig
oc --context ${MAIN_CLUSTER_CONTEXT} get mc 99-master-s390x-hci-network-route

# Check if applied to masters
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp master

# If not applied, apply from workspace rendered by generate-setup
oc --context ${MAIN_CLUSTER_CONTEXT} apply -f workspace/main-cluster-machineconfigs/
```

#### 4. S390x Workers Cannot Reach HCI Workers (Direct Topology)

**Symptoms:**
- Cross-architecture pod communication fails
- Services spanning both worker types don't work
- Network policies fail

**Check:**
```bash
# From s390x worker
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/<s390x-worker>
chroot /host

# Check route
ip route | grep 192.168.100

# Test connectivity
ping -c 3 192.168.100.10
```

**Solution:**
Verify MachineConfig for s390x worker route is applied (Setup Guide C.4):

```bash
# Check MachineConfig
oc --context ${MAIN_CLUSTER_CONTEXT} get mc 99-worker-s390x-hci-network-route

# Check if applied to workers
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp worker

# If not applied, apply from workspace rendered by generate-setup
oc --context ${MAIN_CLUSTER_CONTEXT} apply -f workspace/main-cluster-machineconfigs/
```

### Gateway VM NAT Issues

**Symptoms:**
- Workers can reach main cluster but not internet
- Or vice versa

**Check:**
```bash
# SSH to gateway VM
ssh core@172.16.1.100

# Check NAT rules
sudo iptables -t nat -L -n -v | grep 192.168.100

# Check IP forwarding
sysctl net.ipv4.ip_forward  # Should be 1
```

**Expected NAT Rules:**
```
# Transparent routing (no NAT) for mediated private network
ACCEPT all -- 192.168.100.0/24 10.0.0.0/24

# Transparent routing (no NAT) for external network
ACCEPT all -- 192.168.100.0/24 172.16.0.0/16

# Masquerading (NAT) for internet
MASQUERADE all -- 192.168.100.0/24 0.0.0.0/0
```

**Solution:**
Check gateway VM cloud-init configuration and redeploy if needed.

## Multi-Namespace Deployment Issues

### Second Namespace Deployment Fails

**Symptoms:**
- First namespace deployment works fine
- Second namespace VMs stuck in ContainerCreating
- Network attachment errors in pod events

**Root Cause:**
ClusterUserDefinedNetwork is cluster-scoped. Only the cluster-admin should create it;
each integration namespace gets the resulting NAD automatically via the namespace label.

**Error Message:**
```
network cluster_udn_router-external-network NAD main-cluster-workers/router-external-network
failed to get pod annotation: timed out waiting for annotations
```

**Solution:**

1. **Cluster admin applies cluster-scoped resources once (Setup Guide A.2):**
   ```bash
   oc --context ${HCI_CLUSTER_CONTEXT} apply -f hci-cluster/cluster-network-setup.yaml
   ```

2. **Label each namespace (Setup Guide B.1):**
   ```bash
   oc --context ${HCI_CLUSTER_CONTEXT} label namespace <namespace> hci-gateway-enabled=true
   ```

3. **Apply `WorkerPoolProvisioning` CR** — the `hci-provisioner` operator creates the
   namespace-scoped `UserDefinedNetwork` and gateway VM automatically.

**Quick fix for existing deployments:**

```bash
# 1. Apply cluster-admin setup
oc --context ${HCI_CLUSTER_CONTEXT} apply -f hci-cluster/cluster-network-setup.yaml

# 2. Label all namespaces
oc --context ${HCI_CLUSTER_CONTEXT} label namespace main-cluster-workers hci-gateway-enabled=true
oc --context ${HCI_CLUSTER_CONTEXT} label namespace main-cluster-workers-2 hci-gateway-enabled=true

# 3. Stop gateway VMs
oc --context ${HCI_CLUSTER_CONTEXT} patch vm hci-gateway -n main-cluster-workers --type merge -p '{"spec":{"running":false}}'
oc --context ${HCI_CLUSTER_CONTEXT} patch vm hci-gateway -n main-cluster-workers-2 --type merge -p '{"spec":{"running":false}}'

# 4. Delete incorrect NADs
oc --context ${HCI_CLUSTER_CONTEXT} delete nad router-external-network -n main-cluster-workers
oc --context ${HCI_CLUSTER_CONTEXT} delete nad router-external-network -n main-cluster-workers-2

# 5. Wait for controller to recreate NADs (1-2 minutes)
watch oc --context ${HCI_CLUSTER_CONTEXT} get nad -A

# 6. Verify NAD configuration
oc --context ${HCI_CLUSTER_CONTEXT} get nad router-external-network -n main-cluster-workers -o jsonpath='{.spec.config}' | jq .netAttachDefName
# Should show: "main-cluster-workers/router-external-network"

# 7. Start VMs
oc --context ${HCI_CLUSTER_CONTEXT} patch vm hci-gateway -n main-cluster-workers --type merge -p '{"spec":{"running":true}}'
oc --context ${HCI_CLUSTER_CONTEXT} patch vm hci-gateway -n main-cluster-workers-2 --type merge -p '{"spec":{"running":true}}'
```

## Diagnostic Commands

### Quick Health Check

```bash
#!/bin/bash
# Quick health check for HCI integration

echo "=== Cluster Status (Main Cluster) ==="
oc --context ${MAIN_CLUSTER_CONTEXT} get nodes -l node-role.kubernetes.io/hci-vm

echo "=== MachineConfigPools (Main Cluster) ==="
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp hci-vm

echo "=== Gateway VM (HCI Cluster) ==="
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} hci-gateway

echo "=== Worker VMs (HCI Cluster) ==="
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} -l app=worker-vm

echo "=== Pending CSRs (Main Cluster) ==="
oc --context ${MAIN_CLUSTER_CONTEXT} get csr | grep Pending

echo "=== Network Attachments (HCI Cluster) ==="
oc --context ${HCI_CLUSTER_CONTEXT} get nad -n ${HCI_INTEGRATION_NAMESPACE}

echo "=== ClusterUserDefinedNetwork (HCI Cluster) ==="
oc --context ${HCI_CLUSTER_CONTEXT} get clusteruserdefinednetwork router-external-network
```

### Network Diagnostics

```bash
#!/bin/bash
# Network diagnostics from worker node

echo "=== Interfaces ==="
ip link show

echo "=== IP Addresses ==="
ip addr show

echo "=== Routes ==="
ip route show

echo "=== DNS Configuration ==="
cat /etc/resolv.conf

echo "=== Test DNS ==="
dig api.cluster.example.com
dig quay.io

echo "=== Test Connectivity ==="
ping -c 3 192.168.100.1  # Gateway
ping -c 3 api.cluster.example.com  # Main cluster
ping -c 3 8.8.8.8  # Internet
```

### Gateway VM Diagnostics

```bash
#!/bin/bash
# Gateway VM diagnostics (run via ssh core@<gateway-ip>)

echo "=== Network Interfaces ==="
ip addr show

echo "=== Routing Table ==="
ip route show

echo "=== NAT Rules ==="
sudo iptables -t nat -L -n -v

echo "=== IP Forwarding ==="
sysctl net.ipv4.ip_forward

echo "=== DHCP/PXE Services ==="
systemctl status dnsmasq nginx

echo "=== Static DHCP Reservations ==="
cat /etc/dnsmasq.d/pxe.conf

echo "=== Test Connectivity ==="
ping -c 3 172.16.0.1  # Bastion/DNS
ping -c 3 api.cluster.example.com  # Main cluster
ping -c 3 8.8.8.8  # Internet
```

### Log Collection

```bash
#!/bin/bash
# Collect logs for troubleshooting

LOGDIR="hci-integration-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

# Main Cluster resources
oc --context ${MAIN_CLUSTER_CONTEXT} get nodes -o yaml > "$LOGDIR/nodes.yaml"
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp -o yaml > "$LOGDIR/machineconfigpools.yaml"
oc --context ${MAIN_CLUSTER_CONTEXT} get mc -o yaml > "$LOGDIR/machineconfigs.yaml"
oc --context ${MAIN_CLUSTER_CONTEXT} get csr -o yaml > "$LOGDIR/csrs.yaml"
oc --context ${MAIN_CLUSTER_CONTEXT} get workerpool -n ${MAIN_INTEGRATION_NAMESPACE} -o yaml > "$LOGDIR/workerpools.yaml"
oc --context ${MAIN_CLUSTER_CONTEXT} logs -n ${MAIN_INTEGRATION_NAMESPACE} deploy/hci-consumer-operator -c hci-consumer-operator > "$LOGDIR/hci-consumer-operator.log"
oc --context ${MAIN_CLUSTER_CONTEXT} logs -n ${MAIN_INTEGRATION_NAMESPACE} deploy/hci-consumer-operator -c node-labeler > "$LOGDIR/node-labeler.log"
oc --context ${MAIN_CLUSTER_CONTEXT} logs -n ${MAIN_INTEGRATION_NAMESPACE} deploy/hci-consumer-operator -c csr-approver > "$LOGDIR/csr-approver.log"

# HCI Cluster resources
oc --context ${HCI_CLUSTER_CONTEXT} get all -n ${HCI_INTEGRATION_NAMESPACE} -o yaml > "$LOGDIR/hci-resources.yaml"
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} -o yaml > "$LOGDIR/vmis.yaml"
oc --context ${HCI_CLUSTER_CONTEXT} get nad -n ${HCI_INTEGRATION_NAMESPACE} -o yaml > "$LOGDIR/nads.yaml"
oc --context ${HCI_CLUSTER_CONTEXT} get clusteruserdefinednetwork -o yaml > "$LOGDIR/cudns.yaml"
oc --context ${HCI_CLUSTER_CONTEXT} get workerpoolprovisioning -n ${HCI_INTEGRATION_NAMESPACE} -o yaml > "$LOGDIR/workerpoolprovisioning.yaml"
oc --context ${HCI_CLUSTER_CONTEXT} logs -n ${HCI_INTEGRATION_NAMESPACE} deploy/hci-provisioner-operator > "$LOGDIR/hci-provisioner-operator.log"

# Gateway VM pod logs
oc --context ${HCI_CLUSTER_CONTEXT} logs -n ${HCI_INTEGRATION_NAMESPACE} -l kubevirt.io/domain=hci-gateway --tail=500 > "$LOGDIR/gateway-vm-launcher.log"
oc --context ${HCI_CLUSTER_CONTEXT} logs -n openshift-ovn-kubernetes -l app=ovnkube-node --tail=500 > "$LOGDIR/ovn-kubernetes.log"

# Worker node logs (if accessible)
for node in $(oc --context ${MAIN_CLUSTER_CONTEXT} get nodes -l node-role.kubernetes.io/hci-vm -o name); do
    nodename=$(basename $node)
    oc --context ${MAIN_CLUSTER_CONTEXT} adm node-logs $node > "$LOGDIR/${nodename}-node.log" 2>&1
done

tar czf "${LOGDIR}.tar.gz" "$LOGDIR"
echo "Logs collected in ${LOGDIR}.tar.gz"
```

## Gateway Verification

Use these checks when `WorkerPoolProvisioning` is `Complete` but worker VMs are not
booting or joining the cluster as expected.

### Confirm All Provisioning Steps Completed

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}

# All steps should show status: Complete
oc get workerpoolprovisioning -o yaml | grep -A3 'steps:'
```

### Verify Gateway VM Services

```bash
# SSH to the gateway VM (provisioner SSH key is injected automatically)
ssh core@<gateway-external-ip>

# Ignition file — placed by the operator's Ignition step
curl -sI http://localhost/rhcos/worker-hci.ign
# Should return: HTTP/1.1 200 OK

# RHCOS boot files — downloaded by rhcos-sync timer on first boot
ls -lh /var/www/html/rhcos/
# Should show rhcos-live-kernel, rhcos-live-initramfs.img, rhcos-live-rootfs.img symlinks

# DHCP/PXE services
systemctl status dnsmasq nginx
# Both should show: active (running)

exit
```

!!! info "RHCOS file download timing"
    The operator writes `desired-version.txt` to the gateway during bootstrap.
    The `rhcos-sync` systemd timer then downloads the matching RHCOS files in the
    background — typically a few minutes after first boot. The `hci-consumer`
    operator gates scale-up on `current-version.txt` being present; worker VMs
    will not be created until the files are confirmed downloaded.

### Monitor Worker Boot Progress

Workers go through these stages automatically once the pool scales up:

1. **VM Creation** (1–2 min) — operator creates DataVolume + VirtualMachine on HCI
2. **PXE Boot** (2–3 min) — VM fetches iPXE → RHCOS kernel/initramfs/rootfs → ignition
3. **RHCOS Installation** (5–10 min) — installs to `/dev/vda`, applies ignition
4. **Cluster Join** (5–10 min) — boots from disk, contacts MCS, submits CSRs

```bash
# Watch VM status on HCI cluster
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} -w

# Watch CSR approval on main cluster (auto-approved if hci-node-manager is running)
oc get csr -w

# Watch nodes join
oc get nodes -w

# Access VM console to see boot messages
virtctl console <worker-vm-name> -n ${HCI_INTEGRATION_NAMESPACE}
```

## Getting Help

If you encounter issues not covered in this guide:

1. **Check the logs** using the diagnostic commands above
2. **Review the architecture documentation** to understand expected behavior
3. **Search existing issues** in the GitHub repository
4. **Create a new issue** with:
   - Detailed problem description
   - Steps to reproduce
   - Log output from diagnostic commands
   - Your topology (mediated or direct) and platform (z/VM, KVM, LPAR)
   - OpenShift version (4.20+)

## Related Documentation

- [Getting Started Guide](../getting-started.md) - Initial setup
- [Deployment Variants](../deployment-variants.md) - Understanding your deployment type
- [Prerequisites](../prerequisites.md) - Requirements and dependencies
- [Developer Notes](../development/developer-notes.md) - Technical deep dives