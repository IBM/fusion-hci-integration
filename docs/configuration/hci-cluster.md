# HCI Cluster Configuration

This document describes, step by step, what is configured on the HCI cluster to host
the x86 worker VMs that join the main OpenShift cluster.

!!! info "This page describes the manual steps behind the scripted setup"
    The recommended way to set up the HCI side is the script-supported flow of the
    [Setup Guide](../getting-started.md). Every step on this page is either a command
    from that guide or something its scripts do for you. Use this page to understand
    what each step does, to repeat a single step by hand, or to troubleshoot.

    All values (cluster contexts, namespaces, addresses) come from
    `workspace/integration-setup.yaml` via `generate-setup`. The commands below use
    the variables from the generated `setup_env.sh`, for example
    `${HCI_CLUSTER_CONTEXT}` and `${HCI_INTEGRATION_NAMESPACE}`; source it first
    (see [Workspace Setup](../getting-started.md#workspace-setup)). Example values
    in this page are those of `templates/integration-setup.example.yaml`.

!!! info "Operator-managed"
    Gateway VM, internal `UserDefinedNetwork`, worker VM lifecycle and ignition
    distribution are managed by the **`hci-provisioner`** and **`hci-consumer`**
    operators. See
    [`operator/hci-consumer/`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/README.md)
    and [`operator/hci-provisioner/`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-provisioner/)
    for usage.

## Overview

| Manual step on this page | Setup Guide step | Scripted by | Cadence |
|---|---|---|---|
| [Physical network mapping](#step-2-physical-network-mapping) | prerequisite, not scripted | — | once per HCI cluster |
| [Cluster-scoped external network](#step-1-apply-the-cluster-scoped-network-resource) | [A.2](../getting-started.md#a2-apply-cluster-scoped-network-configuration) | `oc apply -f hci-cluster/cluster-network-setup.yaml` | once per HCI cluster |
| [Integration namespace and label](#namespace-setup) | [B.1](../getting-started.md#b1-create-and-label-the-integration-namespace) | `oc create namespace` / `oc label` | once per main cluster |
| [Consumer RBAC on the HCI cluster](#step-3-rbac-for-the-operators) | [B.2](../getting-started.md#b2-set-up-registry-rbac-on-the-hci-cluster) | `hci-cluster/setup-consumer-rbac.sh` | once per main cluster |
| [Operator credentials](#step-1-set-up-credentials) | [C.7](../getting-started.md#c7-create-operator-credentials) | `operator/setup-provider-credentials.sh` | once per main cluster |
| [WorkerPool CR](#step-2-apply-the-workerpool-cr) | [C.9](../getting-started.md#c9-apply-the-workerpool-cr) | `generate-setup`, then `oc apply` | once per main cluster |
| [Verification](#post-deployment-verification) | [Verify Integration](../getting-started.md#verify-integration) | — | after each deployment |

The HCI image registry (Setup Guide
[A.1](../getting-started.md#a1-enable-the-hci-image-registry)) is not covered here.

## Prerequisites

Before configuring the HCI cluster, ensure:

- ✅ HCI cluster is operational (OpenShift 4.20 or later)
- ✅ OpenShift Virtualization operator installed
- ✅ Sufficient resources available (CPU, memory, storage)
- ✅ Network connectivity to main cluster established
- ✅ `workspace/integration-setup.yaml` completed and `generate-setup` run

See [Prerequisites](../prerequisites.md) for detailed requirements.

## Cluster-Admin Setup

Done once per HCI cluster, shared by all integrations. Setup Guide: [Tier A](../getting-started.md#tier-a-hci-cluster-wide-setup).

### Step 1: Apply the Cluster-Scoped Network Resource

**Purpose:** Create the `ClusterUserDefinedNetwork` that gives every gateway VM its
external connectivity.

**Who:** Cluster administrator (one-time setup)

**Setup Guide:** [A.2](../getting-started.md#a2-apply-cluster-scoped-network-configuration)

**Command:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} apply -f hci-cluster/cluster-network-setup.yaml
```

**Resource created:**
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
        mode: Disabled
```

**Verification:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} get clusteruserdefinednetwork router-external-network
# router-external-network    Active
```

### Step 2: Physical Network Mapping

**Purpose:** Map the OVN network name `localnet1` (the `physicalNetworkName` above) to the
bridge that is connected to the physical network of the HCI nodes.

**Who:** Cluster administrator. This depends on how the HCI nodes are wired and is a
**prerequisite**, not part of the scripted setup. Apply it before the namespace is
labeled in step B.1 of the Setup Guide.

**Example** (requires the Kubernetes NMState Operator; adapt the bridge to your nodes):
```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: localnet1-bridge-mapping
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    ovn:
      bridge-mappings:
      - localnet: localnet1   # must equal physicalNetworkName in the ClusterUserDefinedNetwork
        bridge: br-ex         # bridge connected to the physical network
        state: present
```

**Verification:**
```bash
# Policy applied
oc --context ${HCI_CLUSTER_CONTEXT} get nncp localnet1-bridge-mapping

# Mapping present on a node
oc --context ${HCI_CLUSTER_CONTEXT} debug node/<hci-node> -- chroot /host \
  ovs-vsctl get open . external_ids:ovn-bridge-mappings
# "localnet1:br-ex,..."
```

## Namespace Setup

Done once per main cluster you connect. Setup Guide:
[Tier B](../getting-started.md#tier-b-hci-per-integration-setup). The namespace name is
`provider.namespace` in `integration-setup.yaml` (example: `main-cluster-workers`),
available as `${HCI_INTEGRATION_NAMESPACE}`.

### Step 1: Create Integration Namespace

**Setup Guide:** [B.1](../getting-started.md#b1-create-and-label-the-integration-namespace)

```bash
oc --context ${HCI_CLUSTER_CONTEXT} create namespace ${HCI_INTEGRATION_NAMESPACE}
```

### Step 2: Label Namespace for Network Access

**Purpose:** Let the `ClusterUserDefinedNetwork` create the
`router-external-network` attachment in this namespace.

```bash
oc --context ${HCI_CLUSTER_CONTEXT} label namespace ${HCI_INTEGRATION_NAMESPACE} \
  hci-gateway-enabled=true
```

**Verification:**
```bash
# Namespace label
oc --context ${HCI_CLUSTER_CONTEXT} get namespace ${HCI_INTEGRATION_NAMESPACE} --show-labels

# NetworkAttachmentDefinition created by the controller
oc --context ${HCI_CLUSTER_CONTEXT} get network-attachment-definition \
  -n ${HCI_INTEGRATION_NAMESPACE}
# router-external-network
```

**Expected:** the attachment should appear within 1-2 minutes after labeling. It must
exist before the gateway VM is created.

### Step 3: RBAC for the Operators

**Setup Guide:** [B.2](../getting-started.md#b2-set-up-registry-rbac-on-the-hci-cluster)

```bash
./hci-cluster/setup-consumer-rbac.sh
```

The script requires the namespace from the previous steps and, in
`${HCI_INTEGRATION_NAMESPACE}` on the HCI cluster, creates:

- the `hci-consumer-operator` ServiceAccount with a namespace-scoped Role and RoleBinding
  (VirtualMachines, DataVolumes, PVCs, Secrets, ConfigMaps, `UserDefinedNetwork`)
- a read-only ClusterRole for the `ClusterUserDefinedNetwork` existence check done by
  the provisioner
- the `registry-pusher` ServiceAccount and token, used only by the cross-cluster
  registry model

Pass `--delete` to remove everything again before re-running it.

### Step 4: Secrets

No other Secrets need to be created by hand on the HCI cluster. The gateway VM cloud-init
Secret and the provisioner SSH keypair are generated by the `hci-provisioner` operator.
The only credential handover is the provider kubeconfig Secret on the main cluster —
see [Operator Deployment](#operator-deployment) below.

## Operator Deployment

The gateway VM, internal `UserDefinedNetwork`, ignition distribution and worker VM
lifecycle are fully managed by the two operators. You apply **one CR** — the `WorkerPool`.
Build and deployment of the operators themselves is described in
[Building and Deploying the Operators](../development/operator-build-deploy.md)
(Setup Guide [C.8](../getting-started.md#c8-build-and-deploy-the-operators)).

!!! info "How the two operators interact"
    1. You apply the `WorkerPool` CR.
    2. The `hci-consumer` operator creates the `MachineConfigPool` + `MachineConfig`s on
       the main cluster if absent, then gates on the pool being healthy.
    3. The `hci-consumer` creates the `WorkerPoolProvisioning` CR automatically and sets
       `WorkerPool.status.phase = Provisioning`.
    4. The `hci-provisioner` picks up the `WorkerPoolProvisioning` CR and runs the
       bootstrap steps (UDN → GatewayVM → Ignition) to `Complete`.
    5. The provisioner patches `WorkerPool.status.phase = Ready`.
    6. The `hci-consumer` immediately begins scaling up to `workers.count`.

### Step 1: Set Up Credentials

**Setup Guide:** [C.7](../getting-started.md#c7-create-operator-credentials)

Run the credential setup script once. It uses both cluster contexts from
`setup_env.sh`, creates the ServiceAccounts and Roles on the HCI cluster, and writes the
`hci-provisioner-credentials` and `hci-provider-credentials` kubeconfig Secrets to the
operator namespace (`${MAIN_INTEGRATION_NAMESPACE}`) on the main cluster:

```bash
./operator/setup-provider-credentials.sh
```

See [`operator/setup-provider-credentials.sh`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/setup-provider-credentials.sh)
for the `--consumer` / `--provisioner` / `--delete` flags and environment overrides.

### Step 2: Apply the WorkerPool CR

**Setup Guide:** [C.9](../getting-started.md#c9-apply-the-workerpool-cr)

The `WorkerPool` CR is not written by hand. `generate-setup` renders it from
`integration-setup.yaml` into `workspace/workerpool-hci-workers.yaml` with
`workers.count: 0`, so applying it provisions the gateway only. The provider values come
from the HCI admin (`provider.*`), the consumer values from the main cluster admin
(`consumer.*`). With the example file the generated CR contains:

```yaml
apiVersion: hci-integration.openshift.io/v1alpha1
kind: WorkerPool
metadata:
  name: hci-workers
  namespace: hci-node-manager
spec:
  provider:
    apiEndpoint: "https://api.hci.example.com:6443"
    namespace: "main-cluster-workers"
    credentialsSecret: "hci-provisioner-credentials"
    maxPoolSize: 10
    gateway:
      ip: "172.16.1.100"
      prefixLength: 16
      defaultRouter: "172.16.0.1"
    networking:
      macPrefix: "52:54:01"
      internalSubnet: "192.168.100.0/24"
  consumer:
    machineConfigPool: "hci-vm"
    networking:
      topology: "mediated"          # or: direct
      dnsServer: "172.16.0.1"
      internalNetwork: "10.0.0.0/24"   # mediated topology only
      internalGateway: "172.16.0.1"    # mediated topology only
    workers:
      count: 0
      namePrefix: "worker-x86"
```

The field-by-field mapping is in
[Architecture Overview](../architecture/architecture-overview.md#configuration-input). The
operator repository also contains an annotated sample:
[`workerpool-sample.yaml`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/config/samples/workerpool-sample.yaml).

**Apply and watch:**
```bash
oc --context ${MAIN_CLUSTER_CONTEXT} apply -f workspace/workerpool-hci-workers.yaml

# WorkerPool: Provisioning → Ready
oc --context ${MAIN_CLUSTER_CONTEXT} -n ${MAIN_INTEGRATION_NAMESPACE} get workerpool hci-workers -w

# WorkerPoolProvisioning: created automatically; shows per-step progress
oc --context ${MAIN_CLUSTER_CONTEXT} -n ${MAIN_INTEGRATION_NAMESPACE} get workerpoolprovisioning -w
```

Once the pool is `Ready`, add workers as described under
[Scaling Operations](#scaling-operations). The deployment is complete when `PHASE=Ready`
and `WORKERS`, `DEPLOYED` and `READY` are equal with `PENDING=0`.

## Post-Deployment Verification

Setup Guide: [Verify Integration](../getting-started.md#verify-integration). The checks
below look at the HCI side. The gateway VM is named `hci-gateway`; it is reached over SSH
at its external address (`provider.gateway.ip`), the VMs are not pods.

### Step 1: Verify Gateway VM

**Check VM status:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} get vm hci-gateway -n ${HCI_INTEGRATION_NAMESPACE}
oc --context ${HCI_CLUSTER_CONTEXT} get vmi hci-gateway -n ${HCI_INTEGRATION_NAMESPACE}
# PHASE=Running
```

**Check inside the gateway VM:**
```bash
ssh core@172.16.1.100          # provider.gateway.ip

# 1. Network interfaces
ip addr show
# - eth1: 172.16.1.100/16   (external)
# - eth2: 192.168.100.1/24  (internal)

# 2. Routing
ip route show
# - default via 172.16.0.1 dev eth1
# - 10.0.0.0/24 via 172.16.0.1 dev eth1   (mediated topology only)
# - 192.168.100.0/24 dev eth2

# 3. Services (both active)
systemctl status dnsmasq nginx

# 4. DHCP log
sudo journalctl -u dnsmasq -n 50
```

### Step 2: Verify Worker VMs

**Check VM status:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} get vm  -n ${HCI_INTEGRATION_NAMESPACE} -l app=worker-vm
oc --context ${HCI_CLUSTER_CONTEXT} get vmi -n ${HCI_INTEGRATION_NAMESPACE} -l app=worker-vm
# PHASE=Running for all
```

**Check network boot:**
```bash
virtctl console -n ${HCI_INTEGRATION_NAMESPACE} worker-x86-1

# Should show:
# 1. iPXE boot menu ("Worker VM Boot Menu")
# 2. RHCOS installation progress
# 3. Eventually: login prompt after installation
```

**Monitor events:**
```bash
oc --context ${HCI_CLUSTER_CONTEXT} get events -n ${HCI_INTEGRATION_NAMESPACE} --watch
```

### Step 3: Verify Networks

```bash
# External network (from the ClusterUserDefinedNetwork) and internal network (UDN)
oc --context ${HCI_CLUSTER_CONTEXT} get network-attachment-definition \
  -n ${HCI_INTEGRATION_NAMESPACE}
# router-external-network
# router-internal-network

# Details of one attachment
oc --context ${HCI_CLUSTER_CONTEXT} get network-attachment-definition router-external-network \
  -n ${HCI_INTEGRATION_NAMESPACE} -o yaml
```

**Connectivity test from the gateway VM:**
```bash
ssh core@172.16.1.100

ping -c 3 172.16.0.1                # bastion / DNS (consumer.networking.dnsServer)
ping -c 3 api.cluster.example.com   # main cluster API
ping -c 3 192.168.100.10            # first worker VM (once it has booted)
```

## Scaling Operations

Scale by editing the live `WorkerPool` on the main cluster, in the operator namespace
(`${MAIN_INTEGRATION_NAMESPACE}`, example `hci-node-manager`). Workers can be added up to
`provider.maxPoolSize`; DNS records and DHCP reservations exist for that many slots. See
also [Scaling the Worker Pool](../getting-started.md#scaling-the-worker-pool).

### Adding Workers

```bash
oc --context ${MAIN_CLUSTER_CONTEXT} -n ${MAIN_INTEGRATION_NAMESPACE} patch workerpool hci-workers \
  --type merge -p '{"spec":{"consumer":{"workers":{"count":5}}}}'
```

The `hci-consumer` operator creates the additional VMs and waits for them to join
the cluster. `WorkerPool.status.phase` moves through `ScalingUp` → `Ready`.

### Removing Workers

```bash
oc --context ${MAIN_CLUSTER_CONTEXT} -n ${MAIN_INTEGRATION_NAMESPACE} patch workerpool hci-workers \
  --type merge -p '{"spec":{"consumer":{"workers":{"count":2}}}}'
```

The operator cordons and drains surplus nodes (highest-index first) before deleting
the VMs. `WorkerPool.status.phase` reflects `ScalingDown` or `ScalingDownBlocked`
(if live workloads are preventing drain) until the pool reaches the target size.

!!! note "Regenerating the setup"
    `generate-setup` rewrites `workspace/workerpool-hci-workers.yaml` with
    `workers.count: 0`. To keep the current size of a live pool, save it with
    `oc get workerpool hci-workers -o yaml`.

## Maintenance

### Updating Gateway VM Configuration

Gateway VM resources (CPU, memory, storage) are set in `provider.gateway.resources` of
`integration-setup.yaml` and end up in the `WorkerPoolProvisioning` CR. The gateway VM is
a one-shot provisioned resource, not continuously reconciled after `Complete`, so a
change requires a teardown and re-bootstrap.

For in-place configuration changes on a running gateway VM (for example dnsmasq tuning),
SSH directly:

```bash
ssh core@172.16.1.100          # provider.gateway.ip
sudo -i
# make changes, e.g.:
systemctl restart dnsmasq
```

### Updating Worker VMs

Worker VMs run RHCOS from the main cluster — OS-level updates happen via the main
cluster's `MachineConfigPool`. To change VM hardware resources (CPU/memory), scale
the pool to 0 and back up; the `hci-consumer` operator will recreate the VMs with
the updated `WorkerPool` spec values.

## Troubleshooting

### Gateway VM Won't Start

**Check:**
```bash
# VM events
oc --context ${HCI_CLUSTER_CONTEXT} describe vm hci-gateway -n ${HCI_INTEGRATION_NAMESPACE}

# DataVolume status
oc --context ${HCI_CLUSTER_CONTEXT} get dv -n ${HCI_INTEGRATION_NAMESPACE}

# Storage capacity
oc --context ${HCI_CLUSTER_CONTEXT} get pvc -n ${HCI_INTEGRATION_NAMESPACE}

# Provisioner progress and errors
oc --context ${MAIN_CLUSTER_CONTEXT} -n ${MAIN_INTEGRATION_NAMESPACE} get workerpoolprovisioning -o yaml
```

### Worker VM Won't Network-Boot

**Check:**
```bash
ssh core@172.16.1.100          # provider.gateway.ip

# DHCP/TFTP and HTTP services
sudo systemctl status dnsmasq nginx

# iPXE loader, boot script, RHCOS boot files
ls -la /var/lib/tftpboot/
ls -la /var/www/html/ /var/www/html/rhcos/

# Is the worker's MAC being offered an address?
sudo journalctl -u dnsmasq | grep -i dhcp | tail -20
```

See [VM Provisioning](../architecture/vm-provisioning.md#network-boot-fails) for the
full list of checks.

### Network Attachment Fails

**Check:**
```bash
# Attachments exist
oc --context ${HCI_CLUSTER_CONTEXT} get network-attachment-definition -n ${HCI_INTEGRATION_NAMESPACE}

# Namespace carries the label
oc --context ${HCI_CLUSTER_CONTEXT} get namespace ${HCI_INTEGRATION_NAMESPACE} --show-labels

# ClusterUserDefinedNetwork status
oc --context ${HCI_CLUSTER_CONTEXT} get clusteruserdefinednetwork router-external-network -o yaml

# OVN controller logs
oc --context ${HCI_CLUSTER_CONTEXT} logs -n openshift-ovn-kubernetes -l app=ovnkube-node --tail=100
```

See [Troubleshooting Guide](../operations/troubleshooting.md) for detailed solutions.

## Best Practices

### Resource Planning

1. **Start small** - Deploy 1-2 workers initially
2. **Monitor usage** - Check CPU, memory, storage utilization
3. **Plan capacity** - Ensure HCI cluster has sufficient resources
4. **Reserve resources** - Don't overcommit HCI cluster

### Configuration Management

1. **Version control** - Keep `integration-setup.yaml` (without credentials) and an export of the live `WorkerPool` in Git
2. **Use separate CRs per consumer** - One `WorkerPool` CR per LinuxONE tenant
3. **Document changes** - Maintain changelog
4. **Test changes** - Verify in dev before production

### Security

1. **Protect secrets** - Use sealed secrets or external secret management
2. **Limit access** - Use RBAC to control namespace access
3. **Network policies** - Restrict traffic where possible
4. **Regular updates** - Keep gateway VM OS updated

### Operations

1. **Monitor continuously** - Watch `WorkerPool.status` phase and condition columns
2. **Backup CR manifests** - Keep the exported `WorkerPool` YAML in Git
3. **Test recovery** - Verify teardown and re-bootstrap procedures
4. **Document procedures** - Maintain runbooks

## References

- [Setup Guide](../getting-started.md)
- [Architecture Overview](../architecture/architecture-overview.md)
- [Network Design](../architecture/network-design.md)
- [VM Provisioning](../architecture/vm-provisioning.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [hci-consumer Operator README](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/README.md)
- [hci-provisioner Operator](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-provisioner/)
