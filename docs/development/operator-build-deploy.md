# Building and Deploying the Operators

The integration relies on two Ansible operators that run on the **main cluster**:

| Operator | CRD watched | Responsibility |
|---|---|---|
| **hci-consumer** | `WorkerPool` | Scale worker VMs up/down; CSR approval and node labeling via sidecars |
| **hci-provisioner** | `WorkerPoolProvisioning` | Bootstrap/teardown: UDN, gateway VM, ignition, MachineConfig validation |

Both operators must be built and deployed before you create a `WorkerPool` CR.
This page covers everything from configuring the registry to verifying the running pods.

!!! note "Prerequisite"
    You must be logged in to the **main cluster** with `cluster-admin` and have
    `kustomize` on your `PATH`.

!!! tip "Reconnecting an existing cluster?"
    If the operators were previously deployed on this main cluster:

    - **Step 2 (BuildConfigs)** — skip unless the `BuildConfig` definitions changed
    - **Step 4 (CRDs)** — skip unless the CRD schemas changed
    - **Step 1 (registry config)** — verify `config.env` still matches your
      `setup_env.sh` values (rendered from `integration-setup.yaml`); confirm the push secret exists with
      `oc get secret ${REGISTRY_SECRET_NAME} -n ${OPERATOR_NAMESPACE}`

    For a code-only rebuild the minimum is: **Step 3 → Step 5** (add
    `make rollout` if the image tag did not change — see
    [Updating the Operators](#updating-the-operators)).

---

## Step 1 — Configure the Registry

All image coordinates live in a single file: [`operator/build/config.env`](https://github.com/IBM/fusion-hci-integration/blob/main/operator/build/config.env).
Open it and fill in the values that match your environment:

```bash
# Namespace where everything lives (BuildConfigs, ImageStreams, operator Deployments)
OPERATOR_NAMESPACE ?= hci-node-manager

# ── Push target (build output) ────────────────────────────────────────────────
# Leave REGISTRY_PUSH empty to use the cluster's internal registry (default).
# Set it to an external / bastion-proxy registry hostname + project if needed.
REGISTRY_PUSH        ?=
REGISTRY_SECRET_NAME ?=

# ── Pull source (Deployment image references) ────────────────────────────────
# Internal registry — the namespace is added as a path segment automatically:
REGISTRY_PULL ?= image-registry.openshift-image-registry.svc:5000/hci-node-manager
```

`REGISTRY_SECRET_NAME` is the single push+pull secret — the same credential
used by the BuildConfig (push) and the operator Deployments (pull).  It matches
the variable of the same name exported by `setup_env.sh` (rendered from `integration-setup.yaml`), so if your shell
environment is already set up, no manual editing of this file is needed.

### Registry strategy

=== "Internal registry (default)"
    Leave `REGISTRY_PUSH` empty and keep the `REGISTRY_PULL` default.
    The build writes directly into the cluster's ImageStream and the Deployment
    pulls through the in-cluster registry service.

    No push secret is required.

=== "External / bastion-proxy registry"
    Set your bastion coordinates in `config.env` — or just export them in
    your shell before running `make` and the `?=` defaults will be overridden
    automatically:

    ```bash
    REGISTRY_PUSH        = bastion.example.com:5443/myproject
    REGISTRY_SECRET_NAME = hci-registry-push
    REGISTRY_PULL        = bastion.example.com:5443/myproject
    ```

    The push+pull secret (`REGISTRY_SECRET_NAME`) must already exist in
    `${OPERATOR_NAMESPACE}` on the main cluster.  It is created by
    `setup-registry-access.sh` (Getting Started step C.6) — if you have
    completed that step, the secret is already in place.

You can override any variable on the `make` command line without editing the file:

```bash
make build IMAGE_TAG=v1.2.3
make deploy IMAGE_TAG=v1.2.3
```

---

## Step 2 — Apply BuildConfigs (one-time)

```bash
cd operator/
make apply-buildconfigs
```

This single command:

1. Creates the `hci-node-manager` namespace (if absent)
2. Creates `ImageStream` objects for both operator images (internal-registry mode)
   **or** generates the external push patch (external-registry mode)
3. Applies both `BuildConfig` objects to the cluster

!!! tip "You only need to re-run this step when the BuildConfig definition itself changes."
    Day-to-day rebuilds of the operator images skip straight to Step 3.

---

## Step 3 — Build the Images

```bash
make build
```

This runs `oc start-build --from-dir` for both operators. The build executes
**on a cluster node** (s390x architecture), so no local container toolchain is needed.

Build a single image if only one operator changed:

```bash
make build-consumer     # hci-consumer only
make build-provisioner  # hci-provisioner only
```

Monitor a running build:

```bash
oc logs -f bc/hci-consumer-operator   -n hci-node-manager
oc logs -f bc/hci-provisioner-operator -n hci-node-manager
```

---

## Step 4 — Install the CRDs

```bash
make install
```

Applies the `WorkerPool` and `WorkerPoolProvisioning` CRD manifests to the cluster.
Run this once per cluster, or again after a CRD schema update.

Verify:

```bash
oc get crd | grep hci
# workerpoolprovisionings.hci.openshift.io
# workerpools.hci.openshift.io
```

---

## Step 5 — Deploy the Operators

```bash
make deploy
```

`make deploy` generates `deploy/overlays/active/kustomization.yaml` (git-ignored)
from your shell environment and runs `oc apply -k` against it.  There is nothing
to edit — the active overlay is produced entirely from the variables already set
in your environment.

To inspect what will be applied before committing:

```bash
make print-config
```

If `REGISTRY_SECRET_NAME` is set, `make deploy` automatically adds an
`imagePullSecrets` patch for both Deployments.  No `OVERLAY` flag is needed.

!!! warning "`make deploy` does not restart running pods on its own"
    `make deploy` is a declarative `oc apply`: it only changes the cluster if the
    rendered manifests differ from what is already there.  `imagePullPolicy: Always`
    only takes effect when a pod is (re)created.  If you rebuilt the `:latest`
    image and re-run `make deploy`, the Deployment spec is identical, so
    **nothing happens and the old image keeps running**.  Run `make rollout`
    afterwards (or deploy with a new `IMAGE_TAG`, which changes the spec and
    triggers a rollout automatically).

!!! note "MAIN_CLUSTER_DOMAIN — no action required"
    The `csr-approver` sidecar derives the cluster domain automatically at startup
    by querying the `DNS/cluster` config object on the main cluster.  No env var
    or patch file needs to be set before deploying.  `MAIN_CLUSTER_DOMAIN` exists
    only as a fallback if that API call fails.

!!! info "What gets deployed"
    - `Deployment/hci-consumer-operator` — three containers: `operator`, `csr-approver`, `node-labeler`
    - `Deployment/hci-provisioner-operator` — one container: `operator`
    - `ClusterRole` + `ClusterRoleBinding` for both operators (RBAC)

---

## Step 6 — Verify

```bash
oc get pods -n hci-node-manager
# NAME                                    READY   STATUS    RESTARTS   AGE
# hci-consumer-operator-xxxx-yyyy         3/3     Running   0          2m
# hci-provisioner-operator-xxxx-yyyy      1/1     Running   0          2m
```

Inspect individual container logs:

```bash
# hci-consumer — three containers
oc logs deployment/hci-consumer-operator   -c operator      -n hci-node-manager
oc logs deployment/hci-consumer-operator   -c csr-approver  -n hci-node-manager
oc logs deployment/hci-consumer-operator   -c node-labeler  -n hci-node-manager

# hci-provisioner — one container
oc logs deployment/hci-provisioner-operator -c operator     -n hci-node-manager
```

Both operators start idle (no `WorkerPool` CR exists yet). Once you
[apply the `WorkerPool` CR](../getting-started.md#c9-apply-the-workerpool-cr), the
operators begin their automated reconcile loop.

---

## All Make Targets

Run `make help` inside `operator/` for a quick reference at any time.

| Target | What it does |
|---|---|
| `apply-buildconfigs` | Create namespace, ImageStreams, BuildConfigs in-cluster (one-time) |
| `build` | Build both operator images in-cluster via `oc start-build` |
| `build-consumer` | Build `hci-consumer` image only |
| `build-provisioner` | Build `hci-provisioner` image only |
| `install` | Apply both CRDs to the cluster |
| `uninstall` | Remove both CRDs (**deletes all CRs**) |
| `deploy` | Generate active overlay from `config.env`, then `oc apply -k` (does not restart unchanged Deployments) |
| `rollout` | `oc rollout restart` both operator Deployments and wait for completion (use after `make build` with an unchanged tag) |
| `undeploy` | Delete operator Deployments (CRDs and namespace kept) |
| `print-config` | Show resolved image references and overlay path |

---

## Updating the Operators

To roll out a code change to either operator:

```bash
# 1. Build the new image (no need to re-apply BuildConfigs)
make build                 # or build-consumer / build-provisioner

# 2. Restart both Deployments to pull the new :latest image, wait until ready
make rollout
```

`make rollout` runs `oc rollout restart` followed by `oc rollout status` for
both operators (timeout via `ROLLOUT_TIMEOUT`, default `300s`).  To restart only
one operator:

```bash
oc rollout restart deployment/hci-consumer-operator -n hci-node-manager
oc rollout status  deployment/hci-consumer-operator -n hci-node-manager
```

For a tagged release:

```bash
make build IMAGE_TAG=v1.2.3
make deploy IMAGE_TAG=v1.2.3
```

---

## Tearing Down

```bash
# Remove Deployments (leaves CRDs and namespace intact)
make undeploy

# Also remove CRDs (WARNING: deletes all WorkerPool and WorkerPoolProvisioning objects)
make uninstall

# Remove the namespace entirely
oc delete namespace hci-node-manager
```

!!! warning "Removing CRDs while WorkerPools exist"
    Running `make uninstall` while active `WorkerPool` CRs exist bypasses the
    finalizer that drains nodes and deletes VMs. Always scale down / delete
    all `WorkerPool` objects first:
    ```bash
    oc delete workerpool --all
    # wait for finalizer to complete, then:
    make uninstall
    ```

---

## Local Debug Workflow (No Image Build)

Each operator directory contains a `run-local.sh` that runs the Ansible role
directly on the bastion against a live cluster — useful for iterating on role logic
without a full image build cycle:

```bash
# Test hci-consumer reconcile against a live WorkerPool CR
cd operator/hci-consumer
./run-local.sh

# Test hci-provisioner reconcile against a live WorkerPoolProvisioning CR
cd operator/hci-provisioner
./run-local.sh
```

See the individual operator READMEs for prerequisites.
