# Cluster Admin Setup for HCI Workers

This directory contains cluster-scoped resources that must be created once by a cluster administrator before users can deploy a `WorkerPool`.

## Overview

The HCI workers architecture uses a **ClusterUserDefinedNetwork** to provide external network connectivity via OVN localnet topology. This is a cluster-scoped resource that should be managed separately from the per-namespace worker pool deployments.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Cluster Admin (once)                                        │
│ ├─ ClusterUserDefinedNetwork (router-external-network)     │
│ └─ Namespace labels (hci-gateway-enabled=true)             │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ Creates NADs in labeled namespaces
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Namespace: main-cluster-workers                             │
│ ├─ NetworkAttachmentDefinition (router-external-network)   │
│ ├─ UserDefinedNetwork (router-internal-network)            │
│ ├─ Gateway VM                                               │
│ └─ Worker VMs                                               │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Namespace: other-cluster-workers                            │
│ ├─ NetworkAttachmentDefinition (router-external-network)   │
│ ├─ UserDefinedNetwork (router-internal-network)            │
│ ├─ Gateway VM                                               │
│ └─ Worker VMs                                               │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Cluster administrator access
- OVN-Kubernetes with localnet support
- Physical network bridge mapping configured on nodes (localnet1)

## Installation Steps

### Step 1: Apply Cluster Network Setup

As a cluster administrator, apply the ClusterUserDefinedNetwork:

```bash
kubectl apply -f cluster-network-setup.yaml
```

This creates:
- `ClusterUserDefinedNetwork/router-external-network` - Shared external network

### Step 2: Label Namespaces

Label each namespace that should be allowed to use the external network:

```bash
# Label existing namespaces
kubectl label namespace main-cluster-workers hci-gateway-enabled=true
kubectl label namespace other-cluster-workers hci-gateway-enabled=true

# Or label when creating a new namespace
kubectl create namespace my-hci-namespace
kubectl label namespace my-hci-namespace hci-gateway-enabled=true
```

### Step 3: Verify Setup

Check that the ClusterUserDefinedNetwork is created:

```bash
kubectl get clusteruserdefinednetwork router-external-network -o yaml
```

Verify NADs are created in labeled namespaces:

```bash
kubectl get network-attachment-definitions -n main-cluster-workers router-external-network
kubectl get network-attachment-definitions -n other-cluster-workers router-external-network
```

### Step 4: Create Consumer RBAC and Hand Over Credentials

**Setup Guide:** [B.2](../docs/getting-started.md#b2-set-up-registry-rbac-on-the-hci-cluster)

`setup-consumer-rbac.sh` is the **handover tool** between the two admins. The HCI admin runs it
once per main cluster. It creates the identities for that main cluster in its own namespace on the HCI
cluster, and the `registry-pusher` credential it creates is the only one that cannot be minted from the
main cluster side. In the Setup Guide flow, the main cluster side then picks up the results:

- `main-cluster/bastion-registry/setup-registry-access.sh` ([C.6](../docs/getting-started.md#c6-create-the-registry-access-secret))
  reads the `registry-pusher` token it created (read-only on the HCI cluster), and
- `operator/setup-provider-credentials.sh` ([C.7](../docs/getting-started.md#c7-create-operator-credentials))
  creates the operator credential Secrets.

**Prerequisites**

- Steps 1–3 are done: the integration namespace exists and carries the `hci-gateway-enabled=true` label.
- `setup_env.sh` has been generated in the repo root by `generate-setup`. The script loads it itself and
  takes `HCI_CLUSTER_CONTEXT`, `HCI_INTEGRATION_NAMESPACE` and `REGISTRY_SA_NAME` from it.
- You are logged in to the HCI cluster with enough rights to create RBAC resources.

```bash
./hci-cluster/setup-consumer-rbac.sh
```

The script is idempotent. In `${HCI_INTEGRATION_NAMESPACE}` on the HCI cluster it creates:

| Resource | Purpose |
|---|---|
| ServiceAccount, Role and RoleBinding `hci-consumer-operator` | Namespace-scoped access for the operators: VirtualMachines and VirtualMachineInstances, DataVolumes and `UserDefinedNetwork` (create and delete), Secrets (full lifecycle), PVCs (read and delete) and ConfigMaps (read only). No write access outside this namespace. |
| ClusterRole and ClusterRoleBinding `hci-consumer-operator-cluster` | Read-only access to `ClusterUserDefinedNetwork`, for the provisioner's pre-flight check. |
| ServiceAccount `registry-pusher` (name from `registry.saName`) with a non-expiring token Secret `registry-pusher-token` | Image push credentials for the bastion registry proxy. Needed only for `registry.model: cross-cluster`; it is read later by `main-cluster/bastion-registry/setup-registry-access.sh`. |

**What is handed over**

After creating the resources, the script also generates a token for `hci-consumer-operator`
(valid for **1 year**) and prints a ready-to-run `oc create secret generic hci-provider-credentials`
command that contains the HCI API endpoint and the token as a kubeconfig. This is useful when the
main cluster admin has no access to the HCI cluster: the HCI admin passes the output on, and the main
cluster admin runs it in the operator namespace (`hci-node-manager` in the example inventory).

> **Secret name.** The printed command creates only `hci-provider-credentials`, while
> `spec.provider.credentialsSecret` in the `WorkerPool` CR defaults to `hci-provisioner-credentials`.
> The Setup Guide flow uses `operator/setup-provider-credentials.sh` (C.7) instead, which creates both
> operator Secrets in one run and needs access to both clusters. If you use the printed command, set
> `credentialsSecret` to the name of the Secret you created.

Treat the printed output like a password. It contains a bearer token, so do not paste it into tickets or chat.

**Renewing and removing**

The operator token expires after one year. Re-run the script to get a new one and hand over the
fresh output. To remove everything the script created (the resources listed above, plus the
`registry-pusher` token Secret), run it with `--delete`:

```bash
./hci-cluster/setup-consumer-rbac.sh --delete
```

## User Deployment

After cluster admin setup, users can deploy a `WorkerPool` for their labeled namespace by applying the CR rendered by `generate-setup`
(see the [Getting Started Guide](../docs/getting-started.md)):

```bash
oc apply -f workspace/workerpool-hci-workers.yaml
```

The operators will:
- ✅ Use the existing ClusterUserDefinedNetwork (external network)
- ✅ Create a UserDefinedNetwork (internal network) in their namespace
- ✅ Deploy gateway and worker VMs

## Namespace Selector Strategy

The ClusterUserDefinedNetwork uses a label-based selector:

```yaml
namespaceSelector:
  matchLabels:
    hci-gateway-enabled: "true"
```

**Benefits:**
- ✅ Explicit control over which namespaces can use the network
- ✅ Easy to add/remove namespaces by labeling
- ✅ No conflicts between multiple worker pool deployments
- ✅ Clear separation between cluster-admin and user responsibilities

## Troubleshooting

### NAD Not Created in Namespace

**Problem:** NetworkAttachmentDefinition not appearing in a namespace

**Solution:**
1. Check if namespace is labeled:
   ```bash
   kubectl get namespace <namespace> --show-labels
   ```
2. Add label if missing:
   ```bash
   kubectl label namespace <namespace> hci-gateway-enabled=true
   ```
3. Wait a few seconds for the controller to create the NAD

### Wrong NAD Configuration

**Problem:** NAD has incorrect `netAttachDefName` pointing to wrong namespace

**Solution:** This was the original bug. With the new architecture:
1. Delete the old ClusterUserDefinedNetwork if it exists:
   ```bash
   kubectl delete clusteruserdefinednetwork router-external-network
   ```
2. Apply the new cluster-admin setup:
   ```bash
   kubectl apply -f cluster-network-setup.yaml
   ```
3. The controller will recreate NADs with correct configuration

### Multiple ClusterUserDefinedNetworks

**Problem:** Multiple ClusterUserDefinedNetworks with same name created by different deployments

**Solution:**
1. Delete all duplicate ClusterUserDefinedNetworks
2. Apply the cluster-admin setup once
3. Redeploy the affected worker pools (they will use the existing ClusterUserDefinedNetwork)

## Uninstallation

### Remove Namespace Access

Remove label from namespace to revoke access:

```bash
kubectl label namespace <namespace> hci-gateway-enabled-
```

The NAD will be automatically removed from that namespace.

### Remove Cluster Network

⚠️ **Warning:** This will affect all namespaces using the external network

```bash
kubectl delete -f cluster-network-setup.yaml
```

## Security Considerations

- Only cluster administrators can create/modify ClusterUserDefinedNetwork
- Namespace access is controlled via labels (cluster-admin only)
- Users cannot modify the external network configuration
- Each namespace has isolated internal networks (UserDefinedNetwork)

## Image Registry Setup (Optional)

> **Optional.** This section is needed **only** for the cross-cluster registry model
> (`registry.model: cross-cluster` in `integration-setup.yaml`), where operator images
> built on the main cluster are pushed to this HCI cluster's image registry through the
> bastion registry proxy. Skip it for the `local-s2i` and `external` models.
>
> The proxy itself is set up on the main cluster side (Setup Guide
> [C.5](../docs/getting-started.md#c5-configure-bastion-registry-proxy) and
> [C.6](../docs/getting-started.md#c6-create-the-registry-access-secret)) — see
> [`main-cluster/bastion-registry`](../main-cluster/bastion-registry/README.md).

It is a once-per-HCI-cluster step (Setup Guide
[A.1](../docs/getting-started.md#a1-enable-the-hci-image-registry)). It requires ODF/NooBaa,
because the registry uses S3 storage.

### Enable Image Registry with S3

Run the provided script:

```bash
cd hci-cluster
./enable-image-registry-s3.sh
```

The script is idempotent and will:
1. ✅ Check NooBaa availability
2. ✅ Create ObjectBucketClaim for registry storage
3. ✅ Configure registry credentials
4. ✅ Enable and configure the image registry, including the external default route
5. ✅ Set `disableRedirect: true`, which cross-cluster push through the bastion requires
6. ✅ Wait for registry to be ready

The per-main-cluster push credentials (`registry-pusher` ServiceAccount) are not created
here; `setup-consumer-rbac.sh` creates them.

### Verify Registry

```bash
# Check registry status
oc get configs.imageregistry.operator.openshift.io/cluster

# Check registry pods
oc get pods -n openshift-image-registry

# External route exists and the registry answers (UNAUTHORIZED = up and reachable)
oc get route default-route -n openshift-image-registry
curl -k https://$(oc get route default-route \
  -n openshift-image-registry -o jsonpath='{.spec.host}')/v2/

# Required for cross-cluster push (expected output: true)
oc get configs.imageregistry.operator.openshift.io/cluster \
  -o jsonpath='{.spec.disableRedirect}'
```

## References

- [OVN-Kubernetes ClusterUserDefinedNetwork Documentation](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)
- [OpenShift Image Registry Documentation](https://docs.openshift.com/container-platform/latest/registry/configuring_registry_storage/configuring-registry-storage-baremetal.html)
- [Getting Started Guide](../docs/getting-started.md)