# Prerequisites

This page outlines the requirements and preparation steps needed before deploying the Fusion HCI multi-architecture integration.

## System Requirements

### Main Cluster (s390x/LinuxONE)

**OpenShift Version:**
- OpenShift 4.20 or later (tested on 4.20+)
- Multi-architecture support enabled

**Cluster Configuration:**
- At least 3 control plane nodes
- Existing s390x worker nodes (optional but recommended)
- Cluster-admin access required

**Network Requirements:**
- Routable network for cluster nodes
- Bastion host with external connectivity
- DNS server (typically on bastion)
- Available IP addresses for HCI workers

**Storage:**
- No persistent storage required on main cluster
- Worker node data stored on HCI cluster VMs

### HCI Cluster (Fusion HCI)

**OpenShift Version:**
- OpenShift 4.20 or later (tested on 4.20+)
- OpenShift Virtualization operator installed

**Cluster Configuration:**
- Worker nodes with virtualization capabilities
- Sufficient compute resources for VMs
- Cluster-admin access required

**Network Requirements:**
- OVN-Kubernetes CNI (default)
- Physical network access (localnet support)
- Available IP addresses in physical network range

**Storage:**
- Fusion Data Foundation (FDF) built-in with S3 storage (NooBaa)
- Storage class for VM disks
- Sufficient capacity for worker VMs (50GB+ per VM)
- FDF provides persistent S3 storage for HCI cluster's image registry

### Network Connectivity

**Between Clusters:**
- Network connectivity between HCI and main cluster
- Routing configured (via bastion or direct)
- Firewall rules allowing required traffic

**Required Ports:**
- **6443**: Kubernetes API server
- **22623**: Machine config server
- **80/443**: Application routes
- **9000-9999**: Node ports (if used)
- **DHCP (67/68)**: For PXE boot
- **TFTP (69)**: For PXE boot
- **HTTP (8080)**: For ignition files

## Software Requirements

### On Your Workstation

**Required Tools:**
```bash
# OpenShift CLI
oc version
# Client Version: 4.20.0 or later

# Kubernetes CLI (optional, oc includes kubectl)
kubectl version --client

# Kustomize (or use kubectl kustomize)
kustomize version
# v5.0.0 or later
```

**Optional Tools:**
```bash
# For documentation
mkdocs --version
# mkdocs, version 1.5.0 or later

# For YAML validation
yamllint --version

# For shell script linting
shellcheck --version
```

### Installation

=== "Linux"
    ```bash
    # OpenShift CLI
    curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
    tar xzf openshift-client-linux.tar.gz
    sudo mv oc kubectl /usr/local/bin/
    
    # Kustomize
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
    sudo mv kustomize /usr/local/bin/
    ```

=== "macOS"
    ```bash
    # Using Homebrew
    brew install openshift-cli kustomize
    ```

=== "Windows"
    ```powershell
    # Using Chocolatey
    choco install kubernetes-cli kustomize
    
    # Download oc separately from:
    # https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
    ```

## Access Requirements

### Kubernetes Context Setup

!!! tip "Context Management"
    Using named contexts makes it easy to switch between clusters. We recommend naming your contexts `main-cluster` and `hci-cluster` for consistency with documentation examples and helper scripts.

### Main Cluster Access

1. **Login and Create Context**
   ```bash
   # Login to main cluster
   oc login https://api.cluster.example.com:6443
   
   # Get the current context name
   oc config current-context
   # Output: default/api-cluster-example-com:6443/admin
   
   # Rename context for easy reference
   oc config rename-context $(oc config current-context) main-cluster
   
   # Verify
   oc config get-contexts
   # Should show 'main-cluster' with a '*' indicating it's active
   
   # Test access
   oc whoami
   # Should show your username
   
   oc auth can-i '*' '*' --all-namespaces
   # Should return "yes"
   ```

2. **Bastion Host Access**
   ```bash
   # SSH access to bastion
   ssh user@bastion.cluster.example.com
   
   # On bastion, also setup context (if using oc there)
   oc login https://api.cluster.example.com:6443
   oc config rename-context $(oc config current-context) main-cluster
   
   # Verify DNS service
   systemctl status named
   
   # Verify routing capability
   ip route show
   ```

### HCI Cluster Access

1. **Login and Create Context**
   ```bash
   # Login to HCI cluster
   oc login https://api.hci-cluster.example.com:6443
   
   # Rename context for easy reference
   oc config rename-context $(oc config current-context) hci-cluster
   
   # Verify
   oc config get-contexts
   # Should show both 'main-cluster' and 'hci-cluster'
   
   # Test access
   oc whoami
   
   oc auth can-i '*' '*' --all-namespaces
   # Should return "yes"
   ```

2. **OpenShift Virtualization**
   ```bash
   # Ensure you're using HCI cluster context
   oc config use-context hci-cluster
   
   # Verify virtualization operator
   oc get csv -n openshift-cnv
   
   # Check for HyperConverged CR
   oc get hyperconverged -n openshift-cnv
   ```

### Switching Between Clusters

Once contexts are configured, switching is simple:

```bash
# Switch to main cluster
oc config use-context main-cluster
oc get nodes

# Switch to HCI cluster
oc config use-context hci-cluster
oc get nodes

# View all contexts
oc config get-contexts

# View current context
oc config current-context
```

!!! note "Context in Scripts"
    The helper scripts in `main-cluster/scripts/` use the centralized `setup_env.sh` configuration which allows you to specify context names. Update `setup_env.sh` with your context names:
    ```bash
    MAIN_CLUSTER_CONTEXT="main-cluster"
    HCI_CLUSTER_CONTEXT="hci-cluster"
    ```

## Environment Configuration

Before starting deployment, capture all cluster-pair decisions in a single
configuration file — `workspace/integration-setup.yaml`.  This is the **only**
file you edit by hand.  The `generate-setup` script derives every other
environment artifact from it: shell environment variables, operator config,
kustomize overlays, DNS zone files, and the initial `WorkerPool` CR.
All integration-specific assets land in `workspace/`; `setup_env.sh` is written
to the repo root so every script in the repository can source it with a relative
path.

### Setting Up `workspace/integration-setup.yaml`

```bash
# 1. Create the workspace directory (skip if it already exists)
mkdir -p workspace

# 2. Copy the annotated example into the workspace
cp templates/integration-setup.example.yaml workspace/integration-setup.yaml

# 3. Open it in your editor — every field has an inline comment explaining
#    what it is and how to find the right value
vi workspace/integration-setup.yaml
```

The file has three top-level sections with clear ownership:

| Section | Owner | What goes here |
|---|---|---|
| `consumer.*` | Main cluster (s390x/LinuxONE) admin | Cluster context, domain, operator namespace, bastion, topology, DNS server |
| `provider.*` | HCI cluster admin | Cluster context, HCI namespace, gateway IP, MAC prefix, internal subnet |
| `registry.*` | Both admins (agreed once) | Registry model (`local-s2i`, `cross-cluster`, `external`) and model-specific fields |

!!! tip "Two-admin handover"
    In a two-team setup the main cluster admin fills in `consumer.*` and the
    HCI admin fills in `provider.*`. The finished file is the negotiated record
    of the cluster-pair relationship — keep it alongside your Ansible inventory.

All fields have inline comments in the example file. The required fields are:

```yaml
# ── Consumer cluster (s390x / LinuxONE) ──────────────────────────────────────
consumer:
  context: main-cluster              # oc config get-contexts
  domain: cluster.example.com        # oc get dns cluster -o jsonpath='{.spec.baseDomain}'
  operatorNamespace: hci-node-manager
  bastion:
    host: bastion.cluster.example.com
    user: root
  networking:
    topology: mediated               # direct | mediated
    dnsServer: 172.16.0.1            # main cluster bastion IP
    # mediated topology only:
    internalNetwork: 10.0.0.0/24    # main cluster's internal network
    internalGateway: 172.16.0.1     # HCI-side gateway to that network

# ── Provider cluster (x86 / Fusion HCI) ──────────────────────────────────────
provider:
  context: hci-cluster               # oc config get-contexts
  apiEndpoint: https://api.hci.example.com:6443
  registryHostname: default-route-openshift-image-registry.apps.hci.example.com
  namespace: main-cluster-workers    # one namespace per main cluster on this HCI
  maxPoolSize: 10                    # optional, default: 10; also sizes DNS zones
  gateway:
    ip: 172.16.1.100                 # assigned from HCI physical network
    prefixLength: 16
    defaultRouter: 172.16.0.1
  networking:
    macPrefix: "52:54:01"            # unique per pool on this HCI; optional, default: 52:54:00
    internalSubnet: 192.168.100.0/24

# ── Image registry ─────────────────────────────────────────────────────────────
registry:
  model: cross-cluster               # local-s2i | cross-cluster | external
  # cross-cluster model only:
  proxyPort: 5443
  saName: registry-pusher
  secretName: hci-registry-push
```

### Generating All Configuration Artifacts

Once `workspace/integration-setup.yaml` is complete, run the generator from
the repo root:

```bash
./generate-setup workspace/integration-setup.yaml
```

This writes every derived artifact in one shot:

| Output | Purpose |
|---|---|
| `setup_env.sh` | Shell environment — source this in every terminal session |
| `workspace/workerpool-hci-workers.yaml` | Initial `WorkerPool` CR (`workers.count: 0`) |
| `operator/build/config.env` | Makefile variables for `make build` / `make deploy` |
| `main-cluster/configuration/overlays/<topology>/` | Kustomize overlays (direct topology only) |
| `workspace/<domain>.zone` | Forward DNS zone section (A records for gateway + workers) |
| `workspace/<subnet>.in-addr.arpa.zone` | Reverse DNS zone (PTR records) |

```bash
# After generating, source the environment in your current shell
source setup_env.sh
```

!!! tip "Re-run after any change"
    `generate-setup` is idempotent — re-running it after editing
    `workspace/integration-setup.yaml` regenerates all artifacts consistently.
    The `WorkerPool` CR in `workspace/` is overwritten on every run; to preserve
    the live state of a running pool use `oc get workerpool hci-workers -o yaml`
    instead.

### Configuration Validation

Before proceeding to deployment, validate your configuration:

- [ ] All IP addresses are available and not in use
- [ ] DNS entries planned for worker nodes
- [ ] Cluster contexts are configured and accessible
- [ ] Network connectivity between clusters verified
- [ ] Firewall rules planned
- [ ] Storage capacity sufficient for worker VMs
- [ ] `workspace/integration-setup.yaml` created and `./generate-setup` run
- [ ] `setup_env.sh` sourced in the current shell

### DNS Configuration

!!! tip "DNS zone files are generated automatically"
    Once you have run `./generate-setup workspace/integration-setup.yaml`,
    ready-to-use zone file sections are written into `workspace/`:

    - `workspace/<domain>.zone` — forward A records for the gateway VM and all
      worker nodes up to `provider.maxPoolSize`
    - `workspace/<subnet>.in-addr.arpa.zone` — reverse PTR records for worker nodes

    Copy or append those files to your bastion DNS server instead of writing
    entries by hand.  Re-run `generate-setup` after any change to
    `workspace/integration-setup.yaml` to keep the zone files in sync with the
    WorkerPool configuration.  Step-by-step instructions for applying them are
    in the [Getting Started guide — step C.1](getting-started.md#c1-configure-dns-on-the-bastion).

The generated forward zone section looks like this:

```dns
; Forward zone entries — produced by generate-setup
hci-gateway.cluster.example.com.     IN  A  172.16.1.100
worker-x86-1.cluster.example.com.    IN  A  192.168.100.10
worker-x86-2.cluster.example.com.    IN  A  192.168.100.11
worker-x86-3.cluster.example.com.    IN  A  192.168.100.12
```

!!! warning "Allow recursive queries from the gateway and worker subnet"
    The bastion DNS server is also the upstream resolver for the gateway VM and
    all worker VMs.  By default a BIND server only allows recursion from
    `localhost` and its own networks, so queries from those VMs are refused.
    Add the gateway's external IP (`provider.gateway.ip`) and the worker subnet
    (`provider.networking.internalSubnet`) to the recursion ACL — for example in
    a typical BIND configuration:

    ```bash
    # /etc/named.conf
    acl "internal_nets" {
        ...existing entries...;
        172.16.1.100/32;        # provider.gateway.ip
        192.168.100.0/24;       # provider.networking.internalSubnet
    };
    options {
        allow-query       { localhost; internal_nets; };
        allow-recursion   { localhost; internal_nets; };
        allow-query-cache { localhost; internal_nets; };
    };
    ```

    The [Getting Started guide — step C.1](getting-started.md#c1-configure-dns-on-the-bastion)
    covers this in detail, including the stop/start requirement for `named-chroot`.

### Routing Configuration

!!! tip "Routing is handled by scripts driven by `setup_env.sh`"
    You do not set IP addresses or routes by hand.  After running `generate-setup`
    (which writes `setup_env.sh`), the scripts and kustomize overlays in the
    [Getting Started guide](getting-started.md) pick up all values automatically:

    - **Mediated topology** — `main-cluster/scripts/01-add-route.sh` and
      `02-firewall-setup.sh` configure the bastion route and firewall rules
      (step C.2).  Both scripts source `setup_env.sh` — no manual editing needed.
    - **Direct topology** — `generate-setup` writes a ready-to-apply route
      MachineConfig into `main-cluster/configuration/overlays/direct/`
      (applied with `oc apply -k` in step C.4).

## Registry Strategy Selection

!!! tip "Record your choice in `workspace/integration-setup.yaml`, then follow the setup guide"
    Set `registry.model` to your chosen strategy before running `generate-setup`.
    The script wires the correct registry URLs and credentials into `setup_env.sh`
    and `operator/build/config.env` automatically.  The actual HAProxy proxy and
    credential setup is then handled by scripts in the
    [Getting Started guide](getting-started.md) (steps C.5 and C.6) that source
    `setup_env.sh` — no manual variable editing needed.

Choose your container image registry strategy:

### Option 1: Bastion Registry Proxy (Recommended) — `registry.model: cross-cluster`

**Use when:**
- You want to build multi-architecture images
- HCI workers on main cluster cannot directly access HCI cluster registry
- You need a unified registry accessible from both clusters

**Architecture:**
- HCI cluster has built-in Fusion Data Foundation (FDF) with S3 storage (NooBaa)
- HCI cluster's image registry uses FDF S3 for persistent storage
- HAProxy on main cluster's bastion proxies registry traffic to HCI cluster
- Enables all workers (s390x and x86) to access HCI registry

**Setup:** Set `registry.model: cross-cluster` in `workspace/integration-setup.yaml`.
The actual HAProxy and credential setup is handled by `setup-registry-proxy.sh`
(step C.5) and `setup-registry-access.sh` (step C.6) — both source `setup_env.sh`.

**Documentation:** [Bastion Registry README](https://github.com/IBM/fusion-hci-integration/tree/main/main-cluster/bastion-registry/README.md)

**Pros:**
- ✅ Persistent storage via HCI cluster's built-in FDF (no external S3 needed)
- ✅ Works for all network topologies
- ✅ Enables cross-cluster builds
- ✅ Single registry for all architectures
- ✅ No persistent storage required on main cluster

**Cons:**
- ❌ Requires bastion HAProxy configuration
- ❌ Additional infrastructure component (proxy)
- ❌ Self-signed certificate (insecure registry config needed)

### Option 2: Public Registry (quay.io, ICR, etc.) — `registry.model: external`

**Use when:**
- You have access to external registry
- You don't want to manage internal registry infrastructure
- Internet connectivity is reliable

**Setup:** Set `registry.model: external` and `registry.pullSecretName` in
`workspace/integration-setup.yaml`.  Pre-create the pull secret on the main
cluster before following the setup guide.

**Pros:**
- ✅ No infrastructure to manage
- ✅ High availability
- ✅ Valid SSL certificates
- ✅ Often includes image scanning

**Cons:**
- ❌ Requires internet connectivity
- ❌ May have cost implications
- ❌ Data egress from clusters
- ❌ Dependency on external service

### Option 3: Main Cluster Internal Registry (Not Recommended) — `registry.model: local-s2i`

**Use when:**
- Testing only
- Temporary deployments
- No persistent storage requirements

**Setup:** Set `registry.model: local-s2i` in `workspace/integration-setup.yaml`.
No additional infrastructure needed — images are built and stored in the main
cluster's internal ImageStream registry.

**Pros:**
- ✅ No additional setup
- ✅ Already available

**Cons:**
- ❌ **Ephemeral storage** - images lost on pod restart
- ❌ Not suitable for production
- ❌ May not be accessible from HCI workers

### Decision Matrix

| Requirement | Bastion Proxy (`cross-cluster`) | Public Registry (`external`) | Internal Registry (`local-s2i`) |
|---|---|---|---|
| Persistent Storage | ✅ Yes | ✅ Yes | ❌ No (ephemeral) |
| Multi-arch Builds | ✅ Yes | ✅ Yes | ⚠️ Limited |
| Production Ready | ✅ Yes | ✅ Yes | ❌ No |
| Setup Complexity | Medium | Low | None |
| External Dependency | No | Yes | No |
| Cost | Infrastructure | Service fees | None |

**Recommendation:** Use `cross-cluster` (bastion registry proxy) for production
deployments, or `external` if you prefer a managed registry service.

## Deployment Variant Selection

!!! tip "Record your choice in `workspace/integration-setup.yaml`"
    Set `consumer.networking.topology` to `mediated` or `direct`.  `generate-setup`
    uses this to generate the correct kustomize overlays and to include the
    mediated-topology fields (`internalNetwork`, `internalGateway`) in `setup_env.sh`.
    See [Deployment Variants](deployment-variants.md) for a detailed comparison.

Choose your deployment variant based on your main cluster network topology:

### Mediated Topology
**Use when:**
- Main cluster nodes are in a private network not directly reachable from the HCI cluster
- Bastion host provides external connectivity

**Requirements:**
- Bastion must route to HCI internal network
- DNS provided by bastion
- Gateway VM connects via bastion's public IP

### Direct Topology
**Use when:**
- Main cluster nodes are on the same routable network as the HCI cluster
- Direct connectivity between main cluster nodes and HCI

**Requirements:**
- Master nodes need a static route to the HCI internal subnet — generated by `generate-setup` into `main-cluster/configuration/overlays/direct/`
- Gateway VM on same network as main cluster
- Direct DNS resolution

See [Deployment Variants](deployment-variants.md) for detailed comparison.

## Pre-Deployment Checklist

Before proceeding with deployment, verify:

### Main Cluster
- [ ] OpenShift 4.20+ installed
- [ ] Multi-architecture support enabled (`oc adm upgrade --to-multiarch`)
- [ ] Cluster-admin access confirmed
- [ ] Context renamed to `main-cluster`
- [ ] Bastion host accessible via SSH
- [ ] DNS server running and accessible
- [ ] IP addresses allocated for HCI workers and gateway VM
- [ ] `workspace/integration-setup.yaml` filled in and `./generate-setup` run
- [ ] **Registry model chosen** and set in `workspace/integration-setup.yaml`

### HCI Cluster
- [ ] OpenShift 4.20+ installed
- [ ] OpenShift Virtualization operator installed
- [ ] Cluster-admin access confirmed
- [ ] Context renamed to `hci-cluster`
- [ ] Storage class available for VMs
- [ ] Sufficient compute resources (CPU, memory)
- [ ] Network connectivity to main cluster verified
- [ ] IP addresses allocated in physical network

### Workstation
- [ ] `oc` CLI installed and configured
- [ ] `kustomize` installed (or `kubectl kustomize` available)
- [ ] Access to both clusters configured
- [ ] Contexts properly named (`main-cluster`, `hci-cluster`)
- [ ] Repository cloned locally

### Network
- [ ] Connectivity between clusters verified
- [ ] Firewall rules configured
- [ ] IP address ranges allocated
- [ ] DNS configuration planned
- [ ] Routing strategy determined (z/VM or KVM)

## Next Steps

Once all prerequisites are met:

1. **Review Architecture**: Read [Architecture Overview](architecture/architecture-overview.md)
2. **Choose Variant**: Review [Deployment Variants](deployment-variants.md)
3. **Start Deployment**: Follow [Getting Started Guide](getting-started.md)

## Troubleshooting Prerequisites

### Cannot Access Cluster
```bash
# Check kubeconfig
echo $KUBECONFIG
cat ~/.kube/config

# Test connectivity
curl -k https://api.cluster.example.com:6443/version

# Check credentials
oc login --token=<token> --server=https://api.cluster.example.com:6443
```

### Context Issues
```bash
# List all contexts
oc config get-contexts

# View current context
oc config current-context

# Rename a context
oc config rename-context <old-name> <new-name>

# Delete a context
oc config delete-context <context-name>
```

### OpenShift Virtualization Not Available
```bash
# Check operator installation
oc get csv -n openshift-cnv

# Install if missing (via OperatorHub in web console)
# Or check OpenShift documentation for your version
```

### Network Connectivity Issues
```bash
# Test from HCI cluster to main cluster
oc debug node/<hci-node> -- chroot /host ping <main-cluster-bastion-ip>

# Test DNS resolution
oc debug node/<hci-node> -- chroot /host nslookup api.cluster.example.com
```

## Support

If you encounter issues with prerequisites:

- Check [Troubleshooting Guide](operations/troubleshooting.md)
- Review [Developer Notes](development/developer-notes.md)
- Open an issue on [GitHub](https://github.com/IBM/fusion-hci-integration/issues)