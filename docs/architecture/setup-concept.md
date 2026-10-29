# Setup Concept — Direction C: `integration-setup.yaml`-Driven Day-0 Setup

## Status

**Implemented** — the `generate-setup` script and `templates/integration-setup.example.yaml`
are the production realisation of this concept.  The description below remains
accurate as design rationale; refer to [Prerequisites — Environment Configuration](../prerequisites.md#environment-configuration)
and the [Getting Started guide](../getting-started.md) for the operational
how-to.

---

## The Problem

The hci-consumer and hci-provisioner operators are happy once a `WorkerPool` CR
exists and the prerequisites are in place. The CR is the right abstraction for
runtime — it is the single source of truth the operators act on.

But getting to that first `oc apply -f workerpool.yaml` requires a non-trivial
amount of day-0 setup that is currently manual:

- **Main cluster (s390x/LinuxONE)**: MachineConfigPool + MachineConfig manifests
  applied by the main cluster admin; hci-node-manager built and deployed;
  operator images available
- **HCI cluster**: `router-external-network` CUDN exists; consumer namespace +
  quota created; `hci-provisioner-credentials` Secret produced by
  `setup-consumer-rbac.sh`
- **Joint**: registry model chosen and configured; WorkerPool CR fields agreed
  between HCI admin and main cluster admin

These setup steps involve decisions that must be negotiated between two admins
who own different clusters. Today that negotiation is implicit and the results
are scattered across `setup_env.sh`, hardcoded values in kustomize overlays, and
README instructions.

---

## The Concept: `integration-setup.yaml`

A single YAML file — the **cluster-pair configuration** — captures all the
decisions that precede operator deployment. It is filled in jointly by the HCI
admin (provider) and the main cluster admin (consumer) during the setup
negotiation, and is the input to the generator script.

One file per HCI ↔ main cluster pair. Individual WorkerPools are instances
within that relationship; their pool-specific parameters live in the WorkerPool
CR, not here.

```yaml
# integration-setup.yaml
# Cluster-pair configuration — negotiated once between HCI admin and main cluster admin.
# Captures the decisions that precede any operator deployment.
# Input to generate-setup.

provider:
  context: hci-cluster               # oc context for the HCI cluster
  apiEndpoint: https://api.hci.example.com:6443
  namespace: main-cluster-workers
  gateway:
    ip: 172.16.1.100
    prefixLength: 16
    defaultRouter: 172.16.0.1
  networking:
    macPrefix: "52:54:01"
    internalSubnet: 192.168.100.0/24

consumer:
  context: main-cluster              # oc context for the main cluster
  domain: cluster.example.com
  operatorNamespace: hci-node-manager
  bastion:
    host: bastion.cluster.example.com
    user: root
  networking:
    topology: mediated               # direct | mediated
    dnsServer: 172.16.0.1

registry:
  model: cross-cluster               # local-s2i | cross-cluster | external
  proxyPort: 5443
  saName: registry-pusher
  secretName: hci-registry-push
```

**What belongs here vs in the WorkerPool CR:**

| Decision | Where |
|---|---|
| Which two clusters | `integration-setup.yaml` |
| Network topology (direct/mediated) | `integration-setup.yaml` |
| MachineConfigPool name | `integration-setup.yaml` |
| Image registry model | `integration-setup.yaml` |
| HCI namespace for this pool | `WorkerPool.spec.provider.namespace` |
| Internal subnet for this pool | `WorkerPool.spec.provider.networking.internalSubnet` |
| Gateway IP | `WorkerPool.spec.provider.gateway.ip` |
| Max pool size | `WorkerPool.spec.provider.maxPoolSize` |
| Worker name prefix | `WorkerPool.spec.consumer.workers.namePrefix` |
| Desired worker count | `WorkerPool.spec.consumer.workers.count` |

The rule: if it varies per WorkerPool, it belongs in the CR. If it is a
cluster-pair-level decision made once, it belongs in `integration-setup.yaml`.

---

## Generator Script

### `generate-setup workspace/integration-setup.yaml`

Produces all **cluster-pair-level** day-0 artifacts. Run once when establishing
a new HCI ↔ main cluster relationship.

**Outputs:**

| Artifact | Description |
|---|---|
| `setup_env.sh` | Shell environment variables — sourced by all scripts and Makefiles. |
| `workspace/workerpool-hci-workers.yaml` | Initial `WorkerPool` CR (`workers.count: 0`). Main cluster admin applies, then edits to scale workers. |
| `operator/build/config.env` | Makefile variables for `make build` / `make deploy`. |
| `main-cluster/configuration/overlays/direct/` | Route MachineConfig YAMLs (direct topology only). Main cluster admin applies with `oc apply -k`. |
| `workspace/<domain>.zone` | Forward DNS zone section. Main cluster admin appends to bastion DNS. |
| `workspace/<subnet>.in-addr.arpa.zone` | Reverse DNS zonefile. Main cluster admin appends to bastion DNS. |

All outputs are created with mode `0600` (readable by the owner only), and
`generate-setup` refuses to write a file whose content looks like a credential
(tokens, private keys). No secrets belong in these files; credentials are created
on the cluster. If you hand a file to someone else, such as the zone files for the
DNS admin, adjust its permissions or copy it with `scp` or `oc`.

The WorkerPool skeleton pre-fills:
- `spec.consumer.machineConfigPool` ← from `consumer.machineConfigPool`
- `spec.consumer.networking.topology` ← from `consumer.networking.topology`
- `spec.consumer.networking.dnsServer` ← from `consumer.networking.dnsServer`
- `metadata.namespace` ← from `consumer.operatorNamespace`
- `spec.provider.credentialsSecret` ← default name

### `generate-pool-setup` (not yet implemented)

A second generator for **per-pool** day-0 artifacts is planned but not yet
implemented.  When implemented it will consume an agreed WorkerPool CR and
produce the HCI namespace + ResourceQuota manifest, CUDN manifest, and a
pre-filled `setup-consumer-rbac.sh` invocation.

---

## Relationship to the Operator

The operators are unaffected by this concept. The hci-consumer operator is
entirely happy with a `WorkerPool` CR — it does not know or care how the
prerequisites were set up. The configuration file and generator are a **developer
experience** layer that sits entirely outside the operator runtime.

```
workspace/integration-setup.yaml
        │
        └─ generate-setup ─────────────► setup_env.sh
                                         workspace/workerpool-hci-workers.yaml
                                         operator/build/config.env
                                         main-cluster/configuration/overlays/<topology>/
                                         workspace/<domain>.zone
                                         workspace/<subnet>.in-addr.arpa.zone
                        │
                        ▼
              oc apply -f workspace/workerpool-hci-workers.yaml
                        │
                        ▼
              hci-consumer + hci-provisioner operators
              (runtime — no knowledge of setup phase)
```

---

## Image Registry Models

Three models are supported, selected via `registry.model`:

| Model | Build | Push | Pull | Day-0 setup |
|---|---|---|---|---|
| `local-s2i` | Main cluster S2I | Main cluster ImageStream | Main cluster | `buildconfig.yaml` + S2I build script |
| `cross-cluster` | Main cluster S2I | HCI registry via bastion proxy | Main cluster pulling from HCI | Registry proxy on bastion + cross-cluster push credentials |
| `external` | CI/CD or developer machine | quay.io / Artifactory / … | Both clusters | Registry credentials, image mirror policy |

All three models apply equally to: hci-node-manager, hci-consumer operator
image, hci-provisioner operator image. `generate-setup` resolves the correct
`config.env` variables and registry URLs from the chosen model.

---

## What This Is Not

- **Not a runtime component** — no new CRD, no new operator, no controller loop
- **Not a replacement for the WorkerPool CR** — the CR remains the operator's
  single source of truth

---

## Remaining Work

1. Implement `generate-pool-setup` — per-pool HCI + main cluster artifacts
   (namespace+quota, CUDN, rbac script invocation)
2. Formalise `integration-setup.yaml` schema with JSON Schema for validation

---

**Document Version**: 1.1
**Last Updated**: 2026-07-22
**Status**: Implemented (`generate-setup`). `generate-pool-setup` not yet implemented.
