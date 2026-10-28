# Getting Started

This guide walks you through the full lifecycle from a bare HCI cluster to a
running multi-architecture integration.  The process is organised in three
independent tiers that have different cadences:

| Tier | Who | How often |
|---|---|---|
| **A — HCI cluster-wide setup** | HCI admin | Once per HCI cluster |
| **B — HCI per-integration setup** | HCI admin | Once per main-cluster you want to connect |
| **C — Connect a main cluster** | Main-cluster admin | Once per main cluster (re-run for re-connections) |

!!! tip "Reconnecting an existing cluster?"
    If the bastion host is already configured and the main cluster has previously
    been integrated, **tiers A and B are already done**.
    Jump straight to [Tier C](#tier-c-connect-a-main-cluster) and check each
    step against your existing state — several steps will be no-ops.

!!! warning "Prerequisites Required"
    Before starting, ensure you've completed all steps in [Prerequisites](prerequisites.md),
    including setting up contexts named `main-cluster` and `hci-cluster` and
    choosing your [registry strategy](prerequisites.md#registry-strategy-selection).

---

## Workspace Setup

If you have not done so already, complete the [Environment Configuration](prerequisites.md#environment-configuration)
section of the prerequisites: copy the example, fill in `workspace/integration-setup.yaml`,
and run `generate-setup` once to produce all artifacts including `setup_env.sh`.

```bash
# If generate-setup has not been run yet:
mkdir -p workspace
cp templates/integration-setup.example.yaml workspace/integration-setup.yaml
vi workspace/integration-setup.yaml          # fill in your values
./generate-setup workspace/integration-setup.yaml
```

Source `setup_env.sh` to load the environment for this shell session:

```bash
# Source it (required for all commands in this guide)
source setup_env.sh

# Verify
echo "Main Cluster: ${MAIN_CLUSTER_CONTEXT}"
echo "HCI Cluster:  ${HCI_CLUSTER_CONTEXT}"
```

!!! tip "Every new shell"
    Source `setup_env.sh` from the repo root in every new terminal — all
    commands in this guide use the `${VARIABLES}` it provides.

---

## Tier A — HCI Cluster-Wide Setup

**Run once per HCI cluster.  Subsequent integrations skip this tier entirely.**

These steps require HCI cluster-admin access.  They create shared infrastructure
that every main-cluster integration will use.

### A.1 — Enable the HCI Image Registry

The script configures the registry for external access.  It is idempotent —
safe to re-run.

What it does in one shot:
- Configures ODF/NooBaa S3 storage and enables the external default route
- Sets `disableRedirect: true` — required for cross-cluster push; without it
  the registry issues S3 pre-signed redirects that clients cannot follow across
  the bastion boundary

```bash
oc config use-context ${HCI_CLUSTER_CONTEXT}
./hci-cluster/enable-image-registry-s3.sh
```

Verify:

```bash
oc get route default-route -n openshift-image-registry
curl -k https://$(oc get route default-route \
  -n openshift-image-registry -o jsonpath='{.spec.host}')/v2/
# UNAUTHORIZED = registry is up and reachable

oc get configs.imageregistry.operator.openshift.io/cluster \
  -o jsonpath='{.spec.disableRedirect}'
# true
```

### A.2 — Apply Cluster-Scoped Network Configuration

The `ClusterUserDefinedNetwork` provides the external network attachment that
every gateway VM will use.  Apply it once — it is cluster-scoped and
integration-namespace agnostic.

```bash
oc config use-context ${HCI_CLUSTER_CONTEXT}
oc apply -f hci-cluster/cluster-network-setup.yaml

# Verify
oc get clusteruserdefinednetwork
# router-external-network    Active
```

---

## Tier B — HCI Per-Integration Setup

**Run once per main cluster you connect.  Reconnecting the same main cluster
does not require re-running these steps unless the namespace or RBAC was
deleted.**

These steps create the HCI-side namespace, credentials, and RBAC for one
specific main-cluster ↔ HCI pairing.

### B.1 — Create and Label the Integration Namespace

```bash
oc config use-context ${HCI_CLUSTER_CONTEXT}

oc create namespace ${HCI_INTEGRATION_NAMESPACE}

# Label enables the ClusterUserDefinedNetwork controller to create the NAD
oc label namespace ${HCI_INTEGRATION_NAMESPACE} hci-gateway-enabled=true

# Verify the NetworkAttachmentDefinition was created automatically
sleep 5
oc get network-attachment-definition -n ${HCI_INTEGRATION_NAMESPACE}
# router-external-network
```

!!! warning "NAD must exist before deploying VMs"
    If the NAD is absent after labeling, check the namespace label and the
    `ClusterUserDefinedNetwork` status before continuing.

### B.2 — Set Up Registry RBAC on the HCI Cluster

This script creates the `registry-pusher` ServiceAccount in
`${HCI_INTEGRATION_NAMESPACE}` on the HCI cluster — the only credential that
cannot be minted from the main cluster side.  Its long-lived token is later
read by `setup-registry-access.sh` (step C.6) to create the registry pull
secret on the main cluster, without ever mutating the HCI cluster again.

```bash
# Run from the repo root with setup_env.sh already sourced
./hci-cluster/setup-consumer-rbac.sh
```

!!! tip "Recreating RBAC"
    If you need to rotate credentials or the SA was deleted, pass `--delete`
    first and then re-run:
    ```bash
    ./hci-cluster/setup-consumer-rbac.sh --delete
    ./hci-cluster/setup-consumer-rbac.sh
    ```

---

## Tier C — Connect a Main Cluster

**Run for each new main cluster, and again when reconnecting a previously
integrated cluster.**

!!! note "Assumed execution context for Tier C"
    All commands in this tier are run **on the bastion host of the main cluster**
    as an unprivileged but `sudo`-capable user, with the repository cloned and
    `setup_env.sh` sourced.  Commands that need elevated privileges call `sudo`
    explicitly — do not run an entire shell session as root.

Each step starts with a **check** command.  Run the check first — if it
passes, the step is already done and you move on.

### C.1 — Configure DNS on the Bastion

Check: all worker hostnames resolve correctly.

```bash
# Run for each planned worker name
nslookup worker-x86-1.<main-cluster-domain>
nslookup 192.168.100.10   # reverse lookup
```

If any lookup fails, add the missing forward (A) and reverse (PTR) entries on
the bastion DNS server.

`generate-setup` automatically derives these zone files and writes them to the `workspace/` directory:

- `workspace/<your-domain>.zone` — forward zone section with A records for the gateway VM (`hci-gateway.<domain>`) and all worker nodes up to `maxPoolSize`
- `workspace/<subnet>.in-addr.arpa.zone` — reverse zonefile with PTR records for worker nodes

Copy or append these entries on the bastion DNS server:

```bash
ssh user@${BASTION_HOST}

sudo vi /var/named/<your-domain>.zone
# Append contents from workspace/<your-domain>.zone:
# hci-gateway.cluster.example.com.           IN  A    172.16.1.100
# worker-x86-1.cluster.example.com.          IN  A    192.168.100.10
# worker-x86-2.cluster.example.com.          IN  A    192.168.100.11
# worker-x86-3.cluster.example.com.          IN  A    192.168.100.12

sudo vi /var/named/192.168.100.in-addr.arpa.zone
# Append/create with contents from workspace/<subnet>.in-addr.arpa.zone:
# 10    IN  PTR  worker-x86-1.cluster.example.com.
# 11    IN  PTR  worker-x86-2.cluster.example.com.
# 12    IN  PTR  worker-x86-3.cluster.example.com.

# Zone-file edits alone are picked up by a reload, but use stop/start whenever
# /etc/named.conf was touched (see the warning below)
sudo systemctl stop named-chroot
sudo systemctl start named-chroot
```

!!! warning "Use stop/start for `named-chroot`, not `reload`"
    On a chrooted BIND (`named-chroot`) the config file is bind-mounted into
    `/var/named/chroot/etc/`. An editor that saves by writing a new file gives
    `/etc/named.conf` a new inode, while the chroot keeps pointing at the old,
    unlinked one. `systemctl reload` then silently re-reads the **stale** config,
    so ACL changes have no effect and nothing in the log says so. A stop/start
    re-creates the mount. After editing `named.conf`, check that the copies match:

    ```bash
    sudo ls -li /etc/named.conf /var/named/chroot/etc/named.conf   # same size and mtime, link count 1
    ```

!!! warning "DNS is critical"
    Without correct forward and reverse DNS, the `csr-approver` sidecar cannot
    validate worker node names and CSRs will not be approved.

!!! tip "Keep DNS in sync with your WorkerPool"

    The zone files are generated from the same `integration-setup.yaml` as the
    WorkerPool CR, so they stay in sync as long as you regenerate both.

    | DNS config | `integration-setup.yaml` field |
    |---|---|
    | Worker name prefix (`worker-x86`) | `consumer.workers.namePrefix` |
    | Internal subnet (`192.168.100.x`) | `provider.networking.internalSubnet` |
    | Number of entries | pre-added up to `provider.maxPoolSize` |
    | Cluster domain | `consumer.domain` |

#### Allow recursion for the gateway and the worker network

The bastion DNS server is not only authoritative for the cluster zone. It is
also the only resolver the HCI components use, so it must resolve **external**
names (for example `mirror.openshift.com`) on their behalf. The default BIND
configuration only allows recursion for `localhost` and the bastion's own
networks, so queries from the gateway VM and the worker VMs are refused.

| Client | Source address seen by the bastion | Needs recursion for |
|---|---|---|
| `hci-gateway` | gateway external IP (`provider.gateway.ip`, e.g. `172.16.1.100`) | RHCOS boot file download (`rhcos-sync`) from `mirror.openshift.com` |
| Worker VMs | worker IPs in `spec.provider.networking.internalSubnet` (e.g. `192.168.100.0/24`) | Name resolution during first boot, before and after joining the cluster |

Check: run this **on the gateway VM** (`ssh core@<gateway-ip>`).

```bash
dig @<dnsServer> mirror.openshift.com
# status: NOERROR with an ANSWER section  ← pass, nothing to do
# status: REFUSED, or no answer           ← recursion is not allowed, fix below
```

!!! note "Test from the right host"
    A `dig` from the bastion or from any other host that is already allowed
    proves nothing. The ACL is evaluated against the source address, so the
    test must run on the gateway (and, for the worker network, from a host in
    the internal subnet).

If the lookup is refused, add both networks to the recursion ACL on the bastion
(file and ACL name depend on your `named.conf`):

```bash
sudo vi /etc/named.conf
# acl "internal_nets" {
#     ...existing entries...;
#     172.16.1.100/32;       # hci-gateway external IP (provider.gateway.ip)
#     192.168.100.0/24;      # HCI internal worker subnet (provider.networking.internalSubnet)
# };
#
# options {
#     allow-query       { localhost; internal_nets; };
#     allow-recursion   { localhost; internal_nets; };
#     allow-query-cache { localhost; internal_nets; };   # set explicitly, do not rely on defaults
# };

sudo named-checkconf

# stop/start, NOT reload — see the warning above
sudo systemctl stop named-chroot
sudo systemctl start named-chroot
sudo ls -li /etc/named.conf /var/named/chroot/etc/named.conf   # must match
```

!!! tip "Where the refusal shows up"
    A refused recursive query is logged on the bastion as
    `query (cache) '<name>/A/IN' denied` for the client address. The denial is
    reported against the *cache* ACL, so `allow-query-cache` must include the
    gateway as well.

!!! warning "A missing entry fails silently"
    If the gateway is refused, `rhcos-sync.service` on the gateway fails every
    5 minutes with `curl: (6) Could not resolve host: mirror.openshift.com`
    (see `journalctl -u rhcos-sync.service`). On the operator side this only
    shows up as the scale-up being deferred until the gateway syncs the boot
    files, and `current-version.txt` never appears under `/rhcos/`.

!!! note "The gateway's DNS settings are applied once"
    The gateway VM receives its upstream DNS server (`spec.consumer.networking.dnsServer`)
    through cloud-init on first boot only. Changing the recursion ACL on the
    bastion takes effect immediately and needs no change on the gateway, but
    changing `dnsServer` in the WorkerPool afterwards does not update an
    already-running gateway.

### C.2 — Configure Bastion Routing and Firewall (Mediated Topology only)

Check: the route to the worker subnet exists on the bastion.

```bash
ip route show | grep "${INTERNAL_NETWORK}"
# 192.168.100.0/24 via <gateway-ip>  ← pass, nothing to do
# (no output)                        ← run the scripts below
```

If the route or firewall rules are missing, run the scripts with `sudo` (the scripts automatically locate and source `setup_env.sh` from the repository root):

```bash
sudo ./main-cluster/scripts/01-add-route.sh
sudo ./main-cluster/scripts/02-firewall-setup.sh
```

### C.3 — Enable Multi-Architecture Support

Check: the cluster payload already supports multiple architectures.

```bash
oc --context ${MAIN_CLUSTER_CONTEXT} \
  get clusterversion -o jsonpath='{.items[0].status.desired.image}' | grep -i multi \
  && echo "Multi-arch already enabled — nothing to do"
```

If the check produces no output:

```bash
oc adm --context ${MAIN_CLUSTER_CONTEXT} upgrade --to-multi-arch=true

# Wait for completion (30–60 minutes)
oc --context ${MAIN_CLUSTER_CONTEXT} get clusterversion -w
```

### C.4 — Apply MachineConfigs

Check: the `hci-vm` MachineConfigPool exists.

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc get mcp hci-vm 2>/dev/null && echo "MCP exists — nothing to do"
```

If absent, apply the overlay that matches your network topology
(see [Deployment Variants](deployment-variants.md)):

=== "Mediated Topology"
    ```bash
    oc apply -k main-cluster/configuration/overlays/mediated/

    oc get mc | grep hci
    # machineconfig-pool-hci-vm
    # machineconfig-hci-vm-kargs

    oc get mcp hci-vm
    # MACHINECOUNT: 0  (no workers yet — expected)
    ```

=== "Direct Topology"
    ```bash
    oc apply -k main-cluster/configuration/overlays/direct/

    oc get mc | grep hci
    # machineconfig-pool-hci-vm
    # machineconfig-hci-vm-kargs
    # 99-master-s390x-hci-network-route

    # Wait for master pool to finish rolling before continuing
    oc get mcp master -w
    ```

### C.5 — Configure Bastion Registry Proxy

Check: the bastion is registered as an insecure registry on the main cluster.

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc get image.config.openshift.io cluster \
  -o jsonpath='{.spec.registrySources.insecureRegistries}' \
  | grep -o "${BASTION_HOST}:${REGISTRY_PROXY_PORT}" \
  && echo "Registry proxy configured — nothing to do"
```

If absent, run the setup script directly on the bastion **as your normal user (not with `sudo`)**. It automatically sources `setup_env.sh`, wraps the HAProxy, firewall, and certificate commands in `sudo` itself, and runs all `oc` commands unprivileged with your own login against `${MAIN_CLUSTER_CONTEXT}`:

```bash
./main-cluster/bastion-registry/setup-registry-proxy.sh
```

!!! warning "MachineConfigPool rollout"
    This triggers a cluster-wide MachineConfig update — all worker nodes
    restart in sequence.  Allow 10–30 minutes.

Verify connectivity once the rollout is complete:

```bash
# From the bastion
curl -sk https://localhost:${REGISTRY_PROXY_PORT}/v2/ && echo ok
```

### C.6 — Create the Registry Access Secret

Check: the push/pull secret exists in the operator namespace.

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc get secret ${REGISTRY_SECRET_NAME} -n hci-node-manager 2>/dev/null \
  && echo "Secret exists — nothing to do"
```

If absent, run the setup script.  It reads the long-lived token from the
`registry-pusher` SA in `${HCI_INTEGRATION_NAMESPACE}` on the HCI cluster
(created in Tier B step B.2 — this script is read-only on the HCI side) and
stores it as a docker-registry Secret on the main cluster:

```bash
# Run from repo root with setup_env.sh sourced
./main-cluster/bastion-registry/setup-registry-access.sh
```

The script creates `${REGISTRY_SECRET_NAME}` (default: `hci-registry-push`)
in the `hci-node-manager` namespace.

### C.7 — Create Operator Credentials

The operators need their HCI-side credential Secrets to exist before they start
reconciling.  Create them now, before deploying.

Check: the credentials Secrets exist in the operator namespace.

```bash
oc --context ${MAIN_CLUSTER_CONTEXT} \
  get secret hci-provisioner-credentials hci-provider-credentials \
  -n ${MAIN_INTEGRATION_NAMESPACE}
# Both names listed without error → credentials exist, nothing to do
# Error: secrets "..." not found  → run the script below
```

If absent, run the script from the repo root with `setup_env.sh` sourced.  It
connects to **both clusters** using the contexts from `setup_env.sh`, creates
the `hci-consumer-operator` and `hci-provisioner-operator` ServiceAccounts with
their Roles on the HCI cluster, mints long-lived tokens, and writes two
kubeconfig Secrets to the main cluster — all in one shot:

```bash
./operator/setup-provider-credentials.sh
```

Two Secrets are created in `${MAIN_INTEGRATION_NAMESPACE}`:

| Secret | Consumed by | Scope |
|---|---|---|
| `hci-provider-credentials` | `hci-consumer` operator | VM + DataVolume CRUD in the HCI namespace — steady-state reconcile |
| `hci-provisioner-credentials` | `hci-provisioner` operator | Gateway VM, UDN, SA/token management — bootstrap and teardown only |

!!! tip "Rotating credentials"
    Re-run the script at any time to rotate tokens.  Pass `--consumer` or
    `--provisioner` to rotate only one of the two.

### C.8 — Build and Deploy the Operators

Check: both operator pods are running.

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc get pods -n hci-node-manager
# hci-consumer-operator-xxxx    3/3  Running  ← pass
# hci-provisioner-operator-xxxx 1/1  Running  ← pass
```

Whether deploying for the first time or rebuilding after a code change, the
steps are the same — see the dedicated page for the full workflow:

**[Building and Deploying the Operators →](development/operator-build-deploy.md)**

Quick reference for the bastion-proxy registry case:

```bash
# REGISTRY_PUSH, REGISTRY_PULL, REGISTRY_SECRET_NAME are already exported
# from setup_env.sh — no config.env editing needed.

pushd operator
make apply-buildconfigs   # one-time: namespace, ImageStreams, BuildConfigs
                          # auto-selects external-registry overlay when REGISTRY_PUSH is set
make build                # builds both operator images in-cluster
make install              # applies WorkerPool and WorkerPoolProvisioning CRDs
make deploy               # generates active overlay from environment, runs oc apply -k
                          # MAIN_CLUSTER_DOMAIN is derived automatically — nothing to set
popd

oc get pods -n hci-node-manager
# hci-consumer-operator-xxxx    3/3  Running
# hci-provisioner-operator-xxxx 1/1  Running
```

### C.9 — Apply the WorkerPool CR

!!! info "One CR — fully automated"
    Applying the `WorkerPool` CR is all that is needed.  The operators handle
    everything: gateway VM, ignition, boot files, worker join, CSR approval,
    and node labeling.

`generate-setup` has already rendered an initial WorkerPool CR from
`integration-setup.yaml` into `workspace/workerpool-hci-workers.yaml`. It has
`workers.count: 0`, so applying it provisions the HCI gateway only. Workers are
added afterwards by editing the live resource.

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc apply -f workspace/workerpool-hci-workers.yaml

# Once the pool is Ready, add workers:
oc -n ${MAIN_INTEGRATION_NAMESPACE} edit workerpool hci-workers   # set spec.consumer.workers.count
```

The generated file is a starting point and is overwritten on every
`generate-setup` run. To keep the current state of a live pool, save it with
`oc get workerpool hci-workers -o yaml`.

Watch both operators progress from a single terminal:

```bash
# WorkerPool: Provisioning → Ready → ScalingUp → Ready
oc get workerpool ${WORKERPOOL_NAME} -w

# WorkerPoolProvisioning: created automatically, shows per-step progress
oc get workerpoolprovisioning -w
```

The deployment is complete when `PHASE=Ready` and `WORKERS`, `DEPLOYED`, and
`READY` are all equal with `PENDING=0`:

```bash
oc get workerpool
# NAME         PHASE   WORKERS   DEPLOYED   READY   PENDING   AGE
# hci-workers  Ready   3         3          3       0         12m
```

If the pool does not reach `Ready`, see
[Troubleshooting](operations/troubleshooting.md).

---

## Scaling the Worker Pool

Once the pool is `Ready`, scaling is a single-field edit — the operator handles
cordon, drain, and VM lifecycle automatically.

### Scale Up

```bash
oc patch workerpool ${WORKERPOOL_NAME} \
  --type=merge \
  -p '{"spec":{"consumer":{"workers":{"count": 5}}}}'

oc get workerpool ${WORKERPOOL_NAME} -w
# Transitions: ScalingUp → Ready
```

Ensure DNS entries exist for every new worker IP before scaling up.

### Scale Down

Scale down by reducing `workers.count`:

```bash
oc patch workerpool ${WORKERPOOL_NAME} \
  --type=merge \
  -p '{"spec":{"consumer":{"workers":{"count": 2}}}}'
```

The operator cordons and drains removed nodes before deleting their VMs.
Watch progress:

```bash
oc get workerpool ${WORKERPOOL_NAME} -w
# Transitions: ScalingDown → Ready
```

---

## Verify Integration

### Check Node Status

```bash
oc get nodes -l node-role.kubernetes.io/hci-vm=""
# All HCI worker nodes should be Ready
```

> **Note:** If the x86 workers are `Ready` but missing from this list, and the WorkerPool
> stays in `ScalingUp` with `readyWorkers: 0`, see
> [Troubleshooting: WorkerPool Stuck in ScalingUp](operations/troubleshooting.md#workerpool-stuck-in-scalingup-although-all-workers-are-ready).

### Verify MachineConfigPool

```bash
oc get mcp hci-vm
# MACHINECOUNT and READYMACHINECOUNT should match workers.count
# DEGRADED: False
```

### Verify Network Configuration

```bash
# Check routes on a worker node (Mediated Topology)
oc debug node/<hci-worker-node> -- chroot /host ip route
# 192.168.100.0/24 via <gateway-ip>

# Check UDN on HCI cluster
oc config use-context ${HCI_CLUSTER_CONTEXT}
oc get userdefinednetwork -n ${HCI_INTEGRATION_NAMESPACE}
```

### Test Workload Scheduling

```bash
# Schedule a test pod on an HCI worker
oc run test-pod --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/hci-vm":""}}}' \
  --restart=Never --command -- sleep 60

oc get pod test-pod -o wide
# Should show an HCI worker node in the NODE column

oc delete pod test-pod
```

---

## Troubleshooting

### Registry Proxy Issues

```bash
# Verify HAProxy is running on bastion
ssh user@${BASTION_HOST} systemctl status haproxy

# Check insecure-registries in cluster config
oc get image.config.openshift.io cluster \
  -o jsonpath='{.spec.registrySources.insecureRegistries}' | tr ',' '\n'

# Test push/pull secret
oc get secret ${REGISTRY_SECRET_NAME} -n hci-node-manager -o yaml
```

### Gateway VM Not Starting

```bash
# Check provisioner logs
oc logs deployment/hci-provisioner-operator -c operator -n hci-node-manager | tail -40

# Check VM status on HCI cluster
oc config use-context ${HCI_CLUSTER_CONTEXT}
oc get vm -n ${HCI_INTEGRATION_NAMESPACE}
oc describe vm gateway-vm -n ${HCI_INTEGRATION_NAMESPACE}
```

### Workers Not Booting

```bash
# Check that DNS resolves
nslookup worker-x86-1.${MAIN_CLUSTER_CONTEXT}

# Check DHCP/PXE logs on gateway
ssh -J user@${BASTION_HOST} cloud-user@<gateway-ip>
sudo journalctl -u dhcpd -f
sudo journalctl -u tftp -f
```

### CSRs Not Being Approved

```bash
# Check csr-approver sidecar logs
oc logs deployment/hci-consumer-operator -c csr-approver -n hci-node-manager | tail -20

# List pending CSRs
oc get csr | grep Pending
```

### Workers Not Joining Cluster

```bash
# Check consumer operator logs
oc logs deployment/hci-consumer-operator -c operator -n hci-node-manager | tail -40

# Check node-labeler sidecar
oc logs deployment/hci-consumer-operator -c node-labeler -n hci-node-manager | tail -20
```

---

## Tear Down

```bash
# Delete all WorkerPool objects first (triggers drain + VM cleanup)
oc delete workerpool --all -n hci-node-manager
# Wait for finalizers to complete, then:

# Remove operators
cd operator/
make undeploy

# Remove CRDs (also deletes any remaining CRs)
make uninstall

# Remove namespace
oc delete namespace hci-node-manager
```

!!! warning "Uninstalling CRDs while WorkerPools exist"
    Running `make uninstall` while active `WorkerPool` CRs exist bypasses the
    finalizer that drains nodes and deletes VMs.  Always delete all `WorkerPool`
    objects and wait for completion first.

---

## Next Steps

- [Configuration Reference — Main Cluster](configuration/main-cluster.md)
- [Configuration Reference — HCI Cluster](configuration/hci-cluster.md)
- [Building and Deploying the Operators](development/operator-build-deploy.md)
- [Operations and Monitoring](operations/monitoring.md)
- [Troubleshooting Guide](operations/troubleshooting.md)
