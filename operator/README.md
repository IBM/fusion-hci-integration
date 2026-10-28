# HCI Integration Operators

Two Ansible operators that together manage the full lifecycle of HCI worker nodes
on the main (LO) cluster:

| Operator | Watches | Does |
|---|---|---|
| **hci-consumer** | `WorkerPool` | Scale worker VMs up/down on HCI; sidecars approve CSRs and label nodes |
| **hci-provisioner** | `WorkerPoolProvisioning` | Bootstrap/teardown: UDN, gateway VM, ignition, MachineConfig validation |

---

## Quick Start

> **Prerequisites**: `oc` logged in with cluster-admin, `kustomize` on PATH.

### 1. Configure the registry

Edit [`build/config.env`](build/config.env) — this is the only file you need to touch:

```bash
# Namespace where operators and images live
OPERATOR_NAMESPACE ?= hci-node-manager

# Registry the build pushes to (external hostname of the internal registry route,
# or an external registry host)
REGISTRY_PUSH ?= default-route-openshift-image-registry.apps.<your-cluster-domain>

# Registry the operator pods pull from (in-cluster hostname)
REGISTRY_PULL ?= image-registry.openshift-image-registry.svc:5000
```

### 2. Apply BuildConfigs (one-time)

```bash
cd operator/
make apply-buildconfigs
```

Creates the namespace, ImageStreams, and both BuildConfig objects in the cluster.
Subsequent image rebuilds skip this step.

### 3. Build the images

```bash
make build
```

Triggers `oc start-build --from-dir` for both operators. The build runs **on a cluster
node** (s390x) — no local container tool required.

Build a single image if needed:

```bash
make build-consumer
make build-provisioner
```

### 4. Install CRDs

```bash
make install
```

Applies `WorkerPool` and `WorkerPoolProvisioning` CRDs to the cluster.

### 5. Deploy the operators

```bash
make deploy
```

Renders the kustomize overlay with the correct image references from `config.env` and
applies it. By default uses [`deploy/overlays/internal-registry/`](deploy/overlays/internal-registry/).

For an external registry:

```bash
make deploy OVERLAY=deploy/overlays/external-registry
```

### Verify

```bash
oc get pods -n hci-node-manager

# hci-consumer pod has three containers:
oc logs deployment/hci-consumer-operator -c operator       -n hci-node-manager
oc logs deployment/hci-consumer-operator -c csr-approver   -n hci-node-manager
oc logs deployment/hci-consumer-operator -c node-labeler   -n hci-node-manager

# hci-provisioner pod has one container:
oc logs deployment/hci-provisioner-operator -c operator    -n hci-node-manager
```

---

## All Make Targets

```
make help
```

| Target | What it does |
|---|---|
| `apply-buildconfigs` | Create namespace, ImageStreams, BuildConfigs in-cluster (one-time) |
| `build` | Build both operator images in-cluster via `oc start-build` |
| `build-consumer` | Build hci-consumer image only |
| `build-provisioner` | Build hci-provisioner image only |
| `install` | Apply both CRDs to the cluster |
| `uninstall` | Remove both CRDs (**deletes all CRs**) |
| `deploy` | Apply kustomize overlay — deploys both operators |
| `undeploy` | Delete operator Deployments (CRDs and namespace kept) |
| `print-config` | Show resolved image refs and overlay path |

---

## Directory Layout

```
operator/
├── Makefile                        ← all build and deploy targets
├── build/
│   ├── config.env                  ← registry coordinates (edit this)
│   └── buildconfig.yaml            ← both BuildConfigs (docker strategy, binary source)
├── hci-consumer/
│   ├── Dockerfile                  ← ose-ansible-operator base + node-manager scripts
│   ├── node-manager/               ← CSR approver + node labeler (run as sidecars)
│   │   ├── node-auto-approver.py
│   │   ├── node-labeler.py
│   │   └── requirements.txt
│   ├── watches.yaml
│   ├── requirements.yml
│   ├── roles/                      ← hci_consumer + hci_consumer_cleanup roles
│   ├── config/crd/                 ← WorkerPool CRD
│   ├── config/rbac/                ← ClusterRole + ClusterRoleBinding
│   └── run-local.sh                ← bastion debug runner (no image needed)
├── hci-provisioner/
│   ├── Dockerfile                  ← ose-ansible-operator base
│   ├── watches.yaml
│   ├── requirements.yml
│   ├── roles/                      ← hci_provisioner + hci_provisioner_cleanup roles
│   ├── config/crd/                 ← WorkerPoolProvisioning CRD
│   ├── config/rbac/                ← ClusterRole + ClusterRoleBinding
│   └── run-local.sh                ← bastion debug runner (no image needed)
└── deploy/
    ├── base/                       ← Deployments, RBAC, ImageStreams, CRD refs
    └── overlays/
        ├── internal-registry/      ← image refs → internal registry svc (default)
        └── external-registry/      ← image refs → external/bastion-proxy registry
```

---

## Configuration Reference

### `build/config.env`

| Variable | Default | Description |
|---|---|---|
| `OPERATOR_NAMESPACE` | `hci-node-manager` | Namespace for everything |
| `CONSUMER_IMAGE_NAME` | `hci-consumer-operator` | ImageStream / image name |
| `PROVISIONER_IMAGE_NAME` | `hci-provisioner-operator` | ImageStream / image name |
| `IMAGE_TAG` | `latest` | Image tag |
| `REGISTRY_PUSH` | *(see file)* | Registry the build pushes to (external hostname) |
| `REGISTRY_PUSH_SECRET` | *(empty)* | Pull secret name if external registry needs auth |
| `REGISTRY_PULL` | `image-registry.openshift-image-registry.svc:5000` | In-cluster pull hostname |

Override any variable on the command line without editing the file:

```bash
make build IMAGE_TAG=v1.2.3
make deploy IMAGE_TAG=v1.2.3
```

### Sidecar environment variables

Most sidecar config is driven automatically from the `WorkerPool` CR — the operator
writes a `hci-node-manager-config` ConfigMap on every reconcile and the sidecars read
from it via `envFrom`. You only need to set one value manually:

| Container | Variable | Source | Description |
|---|---|---|---|
| `csr-approver` | `NODE_NAME_PATTERN` | **ConfigMap** (from CR `spec.consumer.workers.namePrefix`) | Set automatically by operator |
| `csr-approver` | `MAIN_CLUSTER_DOMAIN` | **Deployment env var** — set in overlay patch | Cluster DNS domain (e.g. `cluster.example.com`) |
| `node-labeler` | `TARGET_NETWORK` | **ConfigMap** (from CR `spec.provider.networking.internalSubnet`) | Set automatically by operator |
| `node-labeler` | `NODE_NAME_PATTERN` | **ConfigMap** (from CR `spec.consumer.workers.namePrefix`) | Set automatically by operator; name guard |
| `node-labeler` | `TARGET_LABEL` | **Deployment env var** — fixed default | `node-role.kubernetes.io/hci-vm` |
| `node-labeler` | `TARGET_ARCH` | Optional env var — default `amd64` | Only nodes with this `kubernetes.io/arch` are labeled |

Both sidecars re-read the ConfigMap via the API every ~30 s, so they pick up the
config without a restart even if the pod started before the first reconcile.
The `node-labeler` labels a node only if **all** of these are true: the name
matches `<NODE_NAME_PATTERN>-<N>`, the arch is `TARGET_ARCH`, and the InternalIP is
in `TARGET_NETWORK`. While the ConfigMap is missing, labeling is suspended
(there is no hardcoded default network).

Set `MAIN_CLUSTER_DOMAIN` in your overlay patch before running `make deploy`:

```yaml
# deploy/overlays/internal-registry/sidecar-patch.yaml
- op: replace
  path: /spec/template/spec/containers/1/env/0/value
  value: "cluster.example.com"
```

Or patch it directly in the base Deployment if you only ever deploy to one cluster.

---

## Bastion Debug Workflow

The in-cluster operators replace the bastion shell workflow for production, but
`run-local.sh` in each operator directory remains useful for debugging role logic
without an image build cycle:

```bash
# Test hci-consumer reconcile against a live WorkerPool CR
cd operator/hci-consumer
./run-local.sh

# Test hci-provisioner reconcile against a live WorkerPoolProvisioning CR
cd operator/hci-provisioner
./run-local.sh
```

See the individual operator READMEs for prerequisites and detailed usage.
