# Next-Gen Configuration Design Notes

**Status:** Implemented (`generate-setup`); single-file model since session 41.
**Session:** 38 (2026-10-13), revised session 41

This document captures the design thinking behind `integration-setup.example.yaml`
and the `workerpool.yaml.j2` template. It is a working document — add questions,
decisions, and open items here as the design evolves.

> **Revision (session 41):** the original design used two inventory files
> (`integration-setup.yaml` + a hand-maintained `workerpool-*.yaml`). That was
> replaced by a **single** input file. The WorkerPool CR is now an *initial*
> artifact rendered by `generate-setup` from `templates/workerpool.yaml.j2`
> with `workers.count: 0` (gateway only). Scaling is done on the live resource
> (`oc edit workerpool`); a live pool can be persisted with `oc get -o yaml`.
> Sections "Two-file model" and "What a generate-setup script would produce"
> below describe the original design and are kept for history; where they
> conflict with this note, this note wins.

---

## The problem being solved

The current `setup_env.sh` is hand-edited per cluster pair and contains a mix
of things that are already encoded in the WorkerPool CR and things that are
genuinely its own. This means configuration is scattered across:

- `setup_env.sh` — hand-edited, not versioned with the cluster
- `operator/build/config.env` — hand-edited, registry coordinates
- `main-cluster/configuration/overlays/*/` — YAML with hardcoded IPs
- The WorkerPool CR — applied by hand, not stored anywhere canonical

The goal is a **single versioned source** per consumer cluster from which
everything else can be derived and generated.

### Single-file field mapping (current)

`integration-setup.yaml` mirrors the WorkerPool CR's `spec.provider` and
`spec.consumer` sections inside its own `provider:` and `consumer:` sections.

| WorkerPool CR field | integration-setup.yaml | Required |
|---|---|---|
| `metadata.namespace` | `consumer.operatorNamespace` | yes |
| `metadata.name` | constant `hci-workers` | — |
| `spec.provider.apiEndpoint` | `provider.apiEndpoint` | yes |
| `spec.provider.namespace` | `provider.namespace` | yes |
| `spec.provider.credentialsSecret` | constant `hci-provisioner-credentials` | — |
| `spec.provider.maxPoolSize` | `provider.maxPoolSize` | default 10 |
| `spec.provider.gateway.{ip,prefixLength,defaultRouter}` | `provider.gateway.*` | yes |
| `spec.provider.gateway.resources` | `provider.gateway.resources` | optional |
| `spec.provider.networking.internalSubnet` | `provider.networking.internalSubnet` | yes |
| `spec.provider.networking.macPrefix` | `provider.networking.macPrefix` | default `52:54:00` |
| `spec.consumer.machineConfigPool` | `consumer.machineConfigPool` | default `hci-vm` |
| `spec.consumer.networking.topology` | `consumer.networking.topology` | default `direct` |
| `spec.consumer.networking.dnsServer` | `consumer.networking.dnsServer` | yes |
| `spec.consumer.networking.internalNetwork/Gateway` | `consumer.networking.*` | mediated only |
| `spec.consumer.workers.count` | constant `0` | — |
| `spec.consumer.workers.namePrefix` | `consumer.workers.namePrefix` | default `worker-x86` |
| `spec.consumer.workers.resources` | `consumer.workers.resources` | optional |

Defaults mirror the CRD defaults and are applied (and required fields
validated, including the mediated-topology rule) by `generate-setup` before
anything is written.

---

## Two-file model

### File 1: `integration-setup.yaml`  ← cluster-pair level

One file per consumer (LO/s390x) cluster. Lives in the cluster's Ansible
inventory directory. Stable once the cluster pair is established — changes
only when you rewire clusters or change the registry model.

**Contains exactly what `setup_env.sh` holds that the WorkerPool CR does not:**

| Field | Replaces | Used by |
|---|---|---|
| `consumer.context` | `MAIN_CLUSTER_CONTEXT` | all `oc --context` calls in scripts |
| `consumer.domain` | `MAIN_CLUSTER_DOMAIN` | URL construction in scripts |
| `consumer.operatorNamespace` | hardcoded `hci-node-manager` | `build/config.env`, kustomize overlay |
| `consumer.bastion.host` | `BASTION_HOST` | `setup-registry-proxy.sh`, `01-add-route.sh` |
| `consumer.bastion.user` | `BASTION_USER` | same |
| `provider.context` | `HCI_CLUSTER_CONTEXT` | `setup-consumer-rbac.sh`, `setup-registry-access.sh` |
| `provider.apiEndpoint` | — (was never in setup_env.sh) | cross-validates WorkerPool CR |
| `provider.registryHostname` | `HCI_REGISTRY` | `setup-registry-proxy.sh` (HAProxy backend) |
| `registry.model` | — (was never declared anywhere) | selects `BUILD_OVERLAY` in Makefile |
| `registry.proxyPort` | `REGISTRY_PROXY_PORT` | `build/config.env`, `setup-registry-proxy.sh` |
| `registry.saName` | `REGISTRY_SA_NAME` | `setup-consumer-rbac.sh`, `setup-registry-access.sh` |
| `registry.secretName` | `REGISTRY_SECRET_NAME` | `build/config.env`, kustomize imagePullSecrets |

**Does NOT contain** (these belong in the WorkerPool CR, not here):
- Internal subnet, gateway IP, MAC prefix — pool-specific networking
- Worker count, name prefix, resources — pool-specific capacity
- MachineConfigPool name — consumer cluster config, already in CR

### File 2: `workerpool-<name>.yaml`  ← per-pool level

One file per WorkerPool. Lives in the same inventory directory as
`integration-setup.yaml`. This is the actual WorkerPool CR applied verbatim
to the consumer cluster — no transformation needed.

The WorkerPool CR already carries the full split between provider admin
(`spec.provider.*`) and consumer admin (`spec.consumer.*`) sections.

---

## Relationship to the existing WorkerPool CR split

The WorkerPool CR has a clear two-domain model:

```
spec.provider.*   ← filled by HCI admin, handed to LO admin
spec.consumer.*   ← filled by LO admin
```

`integration-setup.yaml` adds a **third layer** below both:

```
integration-setup.yaml    ← cluster-pair decisions (contexts, bastion, registry model)
    ↓
workerpool-<name>.yaml    ← pool decisions (networking, capacity, topology)
    ↓
WorkerPool CR on cluster  ← runtime state watched by the operator
```

---

## What a `generate-setup` script would produce

Input:
```
integration-setup.yaml          (from inventory)
workerpool-<name>.yaml          (from inventory)
```

Outputs written into a fusion-hci-integration checkout:

| Output | Content | Derived from |
|---|---|---|
| `setup_env.sh` | All `MAIN_CLUSTER_*`, `HCI_CLUSTER_*`, `BASTION_*`, `REGISTRY_*` vars | `integration-setup.yaml` + derivable fields from WorkerPool CR |
| `operator/build/config.env` | `OPERATOR_NAMESPACE`, `REGISTRY_PUSH`, `REGISTRY_SECRET_NAME`, `REGISTRY_PULL` | `integration-setup.yaml` registry section |
| `main-cluster/configuration/overlays/<topology>/` | MachineConfig route YAMLs with correct subnet + gateway IP | WorkerPool CR `internalSubnet` + `gateway.ip` + `topology` |
| `workspace/<domain>.zone` | Forward DNS zone section for worker A records | `consumer.domain` + WorkerPool CR `namePrefix`, `internalSubnet`, `maxPoolSize` |
| `workspace/<subnet>.in-addr.arpa.zone` | Reverse DNS zonefile for worker PTR records | `consumer.domain` + WorkerPool CR `namePrefix`, `internalSubnet`, `maxPoolSize` |
| WorkerPool CR skeleton (optional) | Pre-filled with provider + consumer fields, `count: 0` | Both files merged |

`setup_env.sh` becomes a **generated artifact** in this model, not a hand-edited
file. The scripts that source it (`01-add-route.sh`, `setup-consumer-rbac.sh`,
etc.) are unchanged.

---

## Inventory directory layout (proposed)

```
<cluster-inventory>/
    hosts.yml                             ← existing Ansible inventory
    group_vars/
        all.yml                           ← existing Ansible vars
    integration-setup.yaml                ← NEW — the only integration config input
```

The inventory is the natural home because:
- All other cluster config (IP addresses, domain, bastion) already lives there
- It is versioned (git) per-cluster
- It is the authoritative source admins already edit when the cluster changes
- No secrets are stored in these files (credentials are created on the cluster
  by `setup-consumer-rbac.sh`, not stored in config files)

---

## Derived / eliminated variables

Variables from `setup_env.sh` that become **derived** in the new model and
do not need to appear in any config file:

| Variable | Derivation |
|---|---|
| `ROUTER_VM_EXTERNAL` | `workerpool.spec.provider.gateway.ip` |
| `ROUTER_VM_INTERNAL` | `internalSubnet` network address + `.1` |
| `INTERNAL_NETWORK` | `workerpool.spec.provider.networking.internalSubnet` |
| `MAC_PREFIX` | `workerpool.spec.provider.networking.macPrefix` |
| `HCI_INTEGRATION_NAMESPACE` | `workerpool.spec.provider.namespace` |
| `WORKER_MAX_POOL_SIZE` | `workerpool.spec.provider.maxPoolSize` |
| `WORKER_START_IP` | `internalSubnet` network address + `.10` |
| `WORKER_NAME_PREFIX` | `workerpool.spec.consumer.workers.namePrefix` |

Variables that are **dropped** (test artifacts or script-local paths):

| Variable | Reason |
|---|---|
| `TEST_WORKER_IPS` | Test-only; can be derived at script runtime from `internalSubnet` |
| `OUTPUT_IGN_FILE` / `BASE_WORKER_IGN` | Internal script artifact names |
| `HAPROXY_CFG` / `HAPROXY_BACKUP_DIR` | Local bastion paths; script-local defaults |
| Protocol port constants | Truly constant; defined once in the script itself |

---

## Open questions / decisions needed

1. **Naming convention for the WorkerPool file.**
   **Superseded (session 41):** the CR is generated, not an inventory file.
   Output is `workspace/workerpool-hci-workers.yaml` (name = `hci-workers`).

2. **`generate-setup` implementation language.**
   **Decision:** Python, using Jinja2 templates. Rendering `setup_env.sh` and
   the WorkerPool CR skeleton from Jinja2 templates is a natural fit — Python +
   Jinja2 is already used by the Ansible roles in this project, and it avoids
   the fragility of `yq` pipelines for non-trivial template logic.
   The Makefile can integrate it as a target (still open):
   `make configure SETUP=path/to/integration-setup.yaml`

3. **Multiple WorkerPools per cluster pair.** `integration-setup.yaml` is
   one-per-consumer-cluster. A consumer cluster could have multiple pools
   (e.g. one for GPU workers, one for standard workers). The model supports
   this naturally. With the single-file model it would mean turning the
   pool-specific keys into a list of pools; deferred along with the feature.
   **Decision:** deferred — not in scope for the current project version.
   The two-file model already supports it structurally; no design change needed
   when the time comes.
   **Caveat:** the consumer-side MachineConfigPool/MachineConfig machinery has
   dependencies that do not scale to several pools yet (hardcoded `hci-vm` manifests,
   fixed-name routing MCs, node-labeler config). See OPS-09 and
   "Multi-pool dependencies" in
   [`docs/architecture/operator-backlog.md`](../docs/architecture/operator-backlog.md).

4. **Population of `consumer.bastion.*` and `consumer.domain`.**
   These values are typically already known on the bastion host itself
   (hostname, domain) or can be extracted from the live cluster.
   **Decision:** two complementary approaches:
   - **Convention:** `generate-setup` assumes it is run on the consumer cluster's
     bastion host. `consumer.bastion.host` defaults to the local hostname if not
     explicitly set in `integration-setup.yaml`; `consumer.domain` can be queried
     from the cluster (`oc get dns cluster -o jsonpath='{.spec.baseDomain}'`) as
     a fallback when not set.
   - **Helper script:** provide a `extract-cluster-info.sh` (or a `generate-setup
     --extract` mode) that queries the live cluster and prints the values to be
     pasted into `integration-setup.yaml`. This makes the population step
     explicit and auditable without requiring the generator to reach out to the
     cluster at generation time.
   The `integration-setup.yaml` values always take precedence — the convention
   and helper are aids for first-time population, not runtime dependencies.

5. **Storage class and OS image datasource.** Currently hardcoded in
   `operator/hci-provisioner/roles/hci_provisioner/defaults/main.yml`.
   **Decision:** these are **HCI cluster-wide one-time setup** — chosen by the
   HCI admin when the cluster is first prepared and shared by all consumer
   integrations on that cluster. They are not integration configuration and do
   not belong in `integration-setup.yaml`. They stay as operator defaults and
   should be documented as HCI cluster prerequisites (Tier A setup), not as
   something an integration deployer needs to decide.

6. **CUDN `physicalNetworkName` and MTU.** Hardcoded as `localnet1` / `1500`
   in `hci-cluster/cluster-network-setup.yaml`.
   **Decision:** same rationale as #5 — this is HCI cluster-wide one-time setup
   by the HCI admin, done once regardless of how many consumer clusters connect.
   Stays hardcoded; documented as an HCI cluster prerequisite, not an integration
   decision.

7. **`setup_env.sh` transition.**
   **Decision:** `generate-setup` writes a materialised `setup_env.sh` into the
   repo root. The file is gitignored (environment-specific generated artifact).
   Admins source it into their shell session when they want to work with a
   specific cluster:

   ```bash
   ./generate-setup path/to/inventory/main-cluster/integration-setup.yaml
   source setup_env.sh
   # now: oc, make, and all scripts talk to main-cluster
   ```

   The existing scripts (`01-add-route.sh`, `setup-consumer-rbac.sh`, etc.)
   are unchanged — they continue to `source setup_env.sh` exactly as today.
   `setup_env.sh` in the repo root is a generated file, not a hand-edited
   template. The former hand-edited template copy `templates/setup_env.sh`
   has been removed.

---

## Future optional enhancements

### FE-1: Operator build strategy selection and day-0/1 deployment

**Context:** The current model assumes a manual, local build workflow:
the operator images are built on a running consumer cluster via
`make build` (`oc start-build --from-dir`) after the cluster exists.

**Longer-term direction:** When operator deployment becomes a day-0/1
step — i.e. operators must be running at or before consumer cluster
join time — this workflow has a circular dependency: the cluster must
exist before the build can run, but the build is needed before the
cluster is fully operational.

That constraint implies a future `build` section in `integration-setup.yaml`:

```yaml
build:
  strategy: local      # local | bastion | cluster | ci
  imageTag: latest
```

**Strategies in order of operational maturity:**

- `local` — current model: developer runs `make build` (`oc start-build
  --from-dir`) from their workstation after the cluster exists.
  Development/test convenience; requires a running cluster and a local
  `oc` session.

- `bastion` — build is initiated from the s390x consumer cluster's
  bastion host (where `openshift-installer`, HAProxy, and DNS already
  run) as a step in the existing Ansible-driven cluster creation
  playbook. The bastion already has `oc`, the registry proxy, and the
  inventory files — everything `generate-setup` expects to find there.
  This is the natural **day-0/1 path without a pipeline**: the Ansible
  role that finishes cluster bootstrap calls `make build` + `make deploy`
  on the bastion immediately after the cluster API becomes reachable,
  before the consumer cluster is handed over.

- `cluster` — Git-source BuildConfig with webhook trigger; build runs
  on the cluster but is initiated by a repo push, not a local `oc` call.
  Suitable when the cluster is long-lived and operator updates should
  track the repo automatically.

- `ci` — pipeline pre-builds and pushes images to the registry before
  cluster provisioning starts; `integration-setup.yaml` supplies registry
  coordinates only; no BuildConfig is applied to the cluster.
  **Implied production model for fully automated fleet provisioning**:
  images are registry-resident independent of any individual cluster's
  lifecycle.

`generate-setup` would use `build.strategy` to decide whether to emit
`config.env` only (`ci`), apply a Git-source kustomize overlay
(`cluster`), or apply the existing binary-source overlay (`local` /
`bastion` — identical Makefile invocation, differing only in where and
when it is called).

**Not in scope for the current project version.** The `BUILD_OVERLAY`
hook in the Makefile and the `registry.*` fields in `integration-setup.yaml`
are already structured to support this extension without redesign.
