# Bastion Registry Proxy Solution

> Host names, networks and names in this document are the example values from
> [`templates/integration-setup.example.yaml`](../../templates/integration-setup.example.yaml).
> Replace them with the values of your own `integration-setup.yaml`.

## Problem Statement

In a multi-architecture deployment, we face a network partitioning challenge:

- **s390x workers** (main cluster network): Can access both s390x internal registry and HCI registry
- **x86 workers** (192.168.100.x, `provider.networking.internalSubnet`): Can only access s390x internal registry, NOT HCI registry
- **s390x internal registry**: Accessible from all workers but runs on **EmptyDir** (ephemeral storage)
- **HCI registry** (`default-route-openshift-image-registry.apps.hci.example.com`): Persistent storage but not accessible from x86 workers

This creates a dilemma:
- We need persistent storage → Must use HCI registry
- x86 workers need registry access → Cannot reach HCI registry directly
- s390x registry is accessible → But storage is ephemeral (lost on pod restart)

## Solution: Bastion as Registry Proxy

The bastion host already serves as the network bridge for the cluster, handling ingress traffic. We extend its HAProxy configuration to also proxy registry traffic, making the HCI registry accessible to all workers through a single endpoint.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ OpenShift Cluster (main-cluster)                                │
│                                                                 │
│  ┌──────────────────┐              ┌──────────────────┐        │
│  │ s390x Worker     │              │ x86 Worker       │        │
│  │ main cluster net │              │ 192.168.100.x    │        │
│  │                  │              │                  │        │
│  │ Can access:      │              │ Can access:      │        │
│  │ - Bastion ✓      │              │ - Bastion ✓      │        │
│  │ - HCI direct ✓   │              │ - HCI direct ✗   │        │
│  └────────┬─────────┘              └────────┬─────────┘        │
│           │                                 │                  │
│           │    Both pull images via bastion │                  │
│           └─────────────┬───────────────────┘                  │
│                         │                                      │
└─────────────────────────┼──────────────────────────────────────┘
                          │
                          │ HTTPS (port 5443)
                          ▼
              ┌─────────────────────────┐
              │  Bastion Host           │
              │  bastion.cluster...     │
              │                         │
              │  HAProxy Services:      │
              │  - API Server (6443)    │
              │  - Machine Config (22623)│
              │  - HTTP Ingress (80)    │
              │  - HTTPS Ingress (443)  │
              │  - Registry Proxy (5443)│ ← NEW
              └─────────────────────────┘
                          │
                          │ Forward to HCI
                          │ HTTPS (port 443)
                          ▼
              ┌─────────────────────────┐
              │  HCI Registry           │
              │  apps.hci.example.com   │
              │  (Persistent Storage)   │
              └─────────────────────────┘
```

## Implementation

### 1. HAProxy Configuration

`setup-registry-proxy.sh` appends a new frontend/backend pair to the bastion's HAProxy
configuration (shown here with the example values; the script substitutes the values from the
generated `setup_env.sh`):

```haproxy
# Frontend - terminates TLS with the bastion's self-signed certificate
frontend hci-registry-proxy
    bind *:5443 ssl crt /etc/pki/tls/certs/bastion.pem
    mode http
    option httplog
    timeout client 5m

    # Present the registry route's host name to the OpenShift router
    http-request set-header Host default-route-openshift-image-registry.apps.hci.example.com

    # Rewrite response headers so clients keep talking to the bastion, not the real registry
    http-response replace-header Location ^https://default-route-openshift-image-registry.apps.hci.example.com(.*) https://bastion.cluster.example.com:5443\1
    http-response replace-header WWW-Authenticate (.*https://)default-route-openshift-image-registry.apps.hci.example.com(.*) \1bastion.cluster.example.com:5443\2
    http-response replace-header Docker-Distribution-Api-Version (.*https://)default-route-openshift-image-registry.apps.hci.example.com(.*) \1bastion.cluster.example.com:5443\2

    default_backend hci-registry-backend

# Backend - forwards to the HCI registry route via the OpenShift router
backend hci-registry-backend
    mode http
    balance roundrobin
    timeout connect 10s
    timeout server 5m
    server hci-registry <HCI_REGISTRY_IP>:443 ssl verify none sni str(default-route-openshift-image-registry.apps.hci.example.com)
```

`<HCI_REGISTRY_IP>` is the address the script resolves from `provider.registryHostname`
(HAProxy runs in a chroot without DNS, so the IP is written into the configuration).

**Key points:**
- Uses port **5443** (`registry.proxyPort`) to avoid conflict with existing port 5000
- **HTTP mode** with TLS terminated on the bastion, because the `Host` header and the response headers must be rewritten
- The **header rewrites are required**: without them authentication fails for x86 workers
- **SSL verify none** towards the backend, with the route's host name as SNI so the OpenShift router can route the request

### 2. Cluster Configuration

The script adds the bastion proxy to the cluster's insecure registries (it uses a self-signed certificate):

```yaml
# image.config.openshift.io/cluster
spec:
  registrySources:
    insecureRegistries:
      - bastion.cluster.example.com:5443
```

This tells every node:
- Accept the self-signed certificate of the bastion proxy (internal network)
- No other registry is affected; all other registries still require valid certificates

The Machine Config Operator rolls the change out to the nodes, so the worker nodes restart
(MachineConfigPool rollout, typically 10–30 minutes).

### 3. Deployment Configuration

Application images are referenced through the bastion endpoint, for example with a Kustomize
`images:` override:

```yaml
images:
  - name: my-app
    newName: bastion.cluster.example.com:5443/my-project/my-app
    newTag: latest
```

All deployments reference the bastion endpoint, which transparently forwards to HCI.

## Deployment Workflow

### Initial Setup (One-time)

Run both scripts on the bastion of the main cluster, as your **normal user (not with `sudo`)**; they
call `sudo` themselves where needed. These are steps
[C.5](../../docs/getting-started.md#c5-configure-bastion-registry-proxy) and
[C.6](../../docs/getting-started.md#c6-create-the-registry-access-secret) of the Setup Guide.

```bash
# 1. Configure bastion HAProxy with registry proxy and mark it as an insecure
#    registry on the cluster (rolls out to all nodes via the MachineConfigPool,
#    10-30 minutes; wait until `oc get mcp` shows UPDATED=True)
./main-cluster/bastion-registry/setup-registry-proxy.sh

# 2. Create the push/pull secret from the registry-pusher token on the HCI cluster
./main-cluster/bastion-registry/setup-registry-access.sh
```

### Build and Deploy an Application

1. Build the image with a BuildConfig whose output points at
   `${BASTION_HOST}:${REGISTRY_PROXY_PORT}/<project>/<image>:<tag>` and whose push secret is
   `${REGISTRY_SECRET_NAME}` (`hci-registry-push` in the example).
2. Deploy with an image reference to the same bastion endpoint and the secret as `imagePullSecret`.

The HCI operators follow exactly this pattern; see
[Building and Deploying the Operators](../../docs/development/operator-build-deploy.md).

## Benefits

### ✅ Solves Network Partitioning
- All workers (x86 and s390x) can access registry through single endpoint
- No need to modify network infrastructure or routing
- Maintains existing network isolation

### ✅ Persistent Storage
- HCI registry remains the source of truth
- Images survive pod restarts (unlike s390x EmptyDir registry)
- Reliable for production deployments

### ✅ Leverages Existing Infrastructure
- Bastion already serves as network bridge
- HAProxy already handles cluster traffic
- No new components or services needed

### ✅ Centralized Control
- All registry traffic flows through bastion
- Easy to monitor and troubleshoot
- Can add caching layer if needed

### ✅ High Availability
- HAProxy can be made redundant
- Multiple bastion hosts possible
- Health checks ensure registry availability

### ✅ Transparent to Applications
- Pods don't know they're using a proxy
- Standard image pull mechanisms work
- No application code changes needed

## Comparison with Alternatives

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **Direct HCI Registry** | Simple, no proxy | x86 workers can't access | ❌ Doesn't work |
| **s390x Internal Registry** | All workers can access | Ephemeral storage (EmptyDir) | ❌ Not persistent |
| **In-Cluster Proxy** | Kubernetes-native | Adds cluster complexity | ⚠️ Possible but complex |
| **Bastion Proxy** | Uses existing infra, persistent | Requires bastion config | ✅ **Recommended** |
| **Network Routing Changes** | Solves at network layer | Complex, risky | ❌ Too invasive |

## Troubleshooting

The commands below use the variables from the generated `setup_env.sh` (`source setup_env.sh`).

### Images Not Pulling

**Symptom:** Pods stuck in `ImagePullBackOff`

**Check:**
```bash
# 1. Test bastion registry from worker
oc debug node/<worker-node>
chroot /host
curl -k https://bastion.cluster.example.com:5443/v2/

# 2. Check HAProxy on bastion
ssh bastion.cluster.example.com
sudo systemctl status haproxy
sudo ss -tlnp | grep :5443

# 3. Verify the insecure registry setting and that the MachineConfigPool rollout finished
oc --context ${MAIN_CLUSTER_CONTEXT} get image.config.openshift.io/cluster \
  -o jsonpath='{.spec.registrySources.insecureRegistries}' | tr ',' '\n'
oc --context ${MAIN_CLUSTER_CONTEXT} get mcp
```

### Authentication Failures

**Symptom:** 401 Unauthorized errors

**Check:**
```bash
# 1. Verify the push/pull secret exists on the main cluster
oc --context ${MAIN_CLUSTER_CONTEXT} get secret ${REGISTRY_SECRET_NAME} -n hci-node-manager

# 2. Test authentication with the token from the HCI cluster
TOKEN=$(oc --context ${HCI_CLUSTER_CONTEXT} get secret ${REGISTRY_SA_NAME}-token \
  -n ${HCI_INTEGRATION_NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
curl -u serviceaccount:${TOKEN} -k \
  https://${BASTION_HOST}:${REGISTRY_PROXY_PORT}/v2/
```

### HAProxy Not Forwarding

**Symptom:** Connection timeouts or refused

**Check:**
```bash
# 1. Check HAProxy logs
ssh bastion.cluster.example.com
sudo tail -f /var/log/haproxy.log

# 2. Test backend connectivity
curl -k https://${HCI_REGISTRY}/v2/

# 3. Verify HAProxy config
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

## Security Considerations

### TLS/SSL
- The bastion **terminates TLS** with a self-signed certificate and opens a new TLS connection to the HCI registry
- Both legs are encrypted, but the bastion can see the traffic (it must, to rewrite the headers)
- Certificate validation towards the HCI registry is skipped (`verify none`); the bastion is on the internal network

### Authentication
- Same credentials used as direct HCI access
- Service account tokens from HCI cluster
- Pull secrets managed by Kubernetes

### Network Isolation
- x86 workers remain isolated from HCI network
- All traffic flows through controlled bastion endpoint
- Firewall rules unchanged

## Performance Considerations

### Latency
- Adds one network hop (worker → bastion → HCI)
- Minimal impact due to local network speeds
- Can be measured with `curl -w "@curl-format.txt"`

### Bandwidth
- All image pulls flow through bastion
- Consider bastion network capacity for large deployments
- Can add multiple bastion hosts for load distribution

### Caching
- Optional: Add Varnish or Nginx cache in front of HAProxy
- Reduces load on HCI registry
- Improves pull times for frequently used images

## Future Enhancements

### Multiple Bastion Hosts
```haproxy
backend hci-registry-backend
    server bastion1 <HCI_REGISTRY_IP>:443 check ssl verify none
    server bastion2 <HCI_REGISTRY_IP_2>:443 check ssl verify none backup
```

### Registry Caching Layer
```
Worker → Bastion HAProxy → Varnish Cache → HCI Registry
```

### Monitoring and Metrics
- HAProxy stats endpoint for registry traffic
- Prometheus metrics export
- Grafana dashboards for visualization

## Related Documentation

- [Bastion Registry README](README.md)

## Scripts

- `setup-registry-proxy.sh` - Configure HAProxy on the bastion and the cluster's insecure-registry setting
- `setup-registry-access.sh` - Create the pull secret for workloads using the proxy
- `setup_env.sh` (repo root, generated by `generate-setup`) - Environment configuration, including bastion settings

## Made with Bob
