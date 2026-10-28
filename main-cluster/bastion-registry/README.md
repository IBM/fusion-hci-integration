# Bastion Registry Proxy Setup

This directory contains infrastructure setup scripts and documentation for the main-cluster bastion registry proxy infrastructure.

## Overview

The bastion registry proxy enables multi-architecture container image builds across clusters by providing a secure proxy between the main-cluster and the HCI registry on the hci-cluster.

## Purpose

**Problem:** The main-cluster has workers on different networks. For example:
- s390x workers on the main cluster network (can reach HCI registry directly)
- amd64 workers on 192.168.100.x network (cannot reach HCI registry directly)

**Solution:** HAProxy on bastion host proxies registry traffic from both networks to the HCI registry, enabling multi-architecture builds.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ main-cluster                                                │
│                                                             │
│  ┌──────────────┐         ┌──────────────┐                │
│  │ s390x Worker │         │ amd64 Worker │                │
│  │ main cluster │         │ 192.168.100.x│                │
│  │ network      │         │              │                │
│  └──────┬───────┘         └──────┬───────┘                │
│         │                        │                         │
│         │  Build & Push          │  Build & Push          │
│         │  (HTTPS)               │  (HTTPS)               │
│         └────────┬───────────────┘                         │
│                  │                                         │
└──────────────────┼─────────────────────────────────────────┘
                   │
                   ▼
         ┌─────────────────┐
         │ Bastion Host    │
         │ HAProxy :5443   │
         │ (Self-signed)   │
         └────────┬────────┘
                  │
                  │ Proxy (HTTPS)
                  │ + Header Rewrites
                  │
                  ▼
         ┌─────────────────┐
         │ HCI Registry    │
         │ apps.hci.       │
         │ example.com     │
         │ (hci-cluster)   │
         └─────────────────┘
```

## Components

### 1. Bastion Registry Proxy

**Location:** `bastion.cluster.example.com:5443`

**Features:**
- HAProxy-based HTTPS proxy
- Self-signed SSL certificate
- HTTP mode with header rewriting for OpenShift authentication
- Firewall configuration for both networks

### 2. Cluster Configuration

**Insecure Registry:** Required for self-signed certificate acceptance

**Impact:** Worker nodes restart to apply configuration (MachineConfigPool rollout)

## Setup Instructions

The proxy is only needed for `registry.model: cross-cluster`. In the
[Setup Guide](../../docs/getting-started.md) these are steps
[C.5](../../docs/getting-started.md#c5-configure-bastion-registry-proxy) (proxy) and
[C.6](../../docs/getting-started.md#c6-create-the-registry-access-secret) (access secret).

### Prerequisites

- `setup_env.sh` generated in the repository root by `generate-setup` (the scripts load it themselves)
- A shell on the **bastion host of the main cluster**, as an unprivileged but `sudo`-capable user.
  **Do not run the scripts as root or with `sudo`.** They call `sudo` themselves for the HAProxy,
  certificate and firewall changes and run every `oc` command with your own login.
- An existing HAProxy configuration on the bastion (`/etc/haproxy/haproxy.cfg`); the script backs it up
  and appends to it
- Cluster-admin rights on the `${MAIN_CLUSTER_CONTEXT}` context (the script patches
  `image.config.openshift.io/cluster`). Without them the script still sets up the bastion and prints the
  remaining `oc` commands for someone who has the rights.
- Network connectivity between the bastion and the HCI registry endpoint
- On the HCI side: the image registry enabled with the external route
  ([A.1](../../docs/getting-started.md#a1-enable-the-hci-image-registry)) and, for step 2 below,
  the `registry-pusher` ServiceAccount
  ([B.2](../../docs/getting-started.md#b2-set-up-registry-rbac-on-the-hci-cluster))

### Installation

#### 1. Configure the proxy (C.5)

Check first. If the bastion is already registered as an insecure registry, there is nothing to do:

```bash
oc config use-context ${MAIN_CLUSTER_CONTEXT}
oc get image.config.openshift.io cluster \
  -o jsonpath='{.spec.registrySources.insecureRegistries}' \
  | grep -o "${BASTION_HOST}:${REGISTRY_PROXY_PORT}" \
  && echo "Registry proxy configured — nothing to do"
```

If it is absent, run, as your normal user:

```bash
./main-cluster/bastion-registry/setup-registry-proxy.sh
```

This script performs:

1. ✅ Generates a self-signed SSL certificate on the bastion (reused if it exists)
2. ✅ Backs up the current HAProxy configuration (the last 10 backups are kept)
3. ✅ Adds the registry proxy frontend and backend to HAProxy
4. ✅ Opens the proxy port (5443/tcp) in the bastion firewall
5. ✅ Validates the HAProxy configuration and reloads HAProxy
6. ✅ Adds the bastion proxy to the cluster's insecure registries

Step 6 starts a cluster-wide MachineConfigPool rollout: all worker nodes restart in sequence, which takes
10–30 minutes. The script does not wait for it. Follow it with `oc get mcp -w` and continue once all
pools show `UPDATED=True`.

#### 2. Create the registry access secret (C.6)

Check first. If the push/pull secret exists, there is nothing to do:

```bash
oc get secret ${REGISTRY_SECRET_NAME} -n hci-node-manager
```

If it is absent, run:

```bash
./main-cluster/bastion-registry/setup-registry-access.sh
```

This script only reads from the HCI cluster. It verifies that the proxy is registered as an insecure
registry, reads the token of the `registry-pusher` ServiceAccount (created by
`hci-cluster/setup-consumer-rbac.sh`, step B.2) and stores it as the docker-registry Secret
`${REGISTRY_SECRET_NAME}` in the `hci-node-manager` namespace of the main cluster.

### Verification

After setup completes, verify the configuration:

#### 1. Check Insecure Registry Configuration

```bash
oc get image.config.openshift.io/cluster -o yaml | grep -A 5 "insecureRegistries:"
```

Expected output:
```yaml
insecureRegistries:
- bastion.cluster.example.com:5443
```

#### 2. Check MachineConfigPool Status

```bash
oc get mcp
```

All nodes should show `UPDATED=True` and `DEGRADED=False`.

#### 3. Test Registry Connectivity

From a worker node:
```bash
oc debug node/<worker-node>
chroot /host
curl -k https://bastion.cluster.example.com:5443/v2/
```

Expected: HTTP 401 Unauthorized (authentication required) or registry API response.

#### 4. Test from Bastion

```bash
ssh bastion.cluster.example.com
curl -k https://localhost:5443/v2/
```

Expected: Registry API response or authentication challenge.

## Files

- `setup-registry-proxy.sh` — Bastion HAProxy + insecure registry setup (infrastructure, run once per main cluster; step C.5)
- `setup-registry-access.sh` — Creates the push/pull secret from the HCI registry token (re-run to refresh the token; step C.6)
- `registry-proxy.md` — Detailed technical documentation
- `README.md` — This file

## Using the Proxy for an Application

After infrastructure setup is complete, any application on the main cluster can build and pull
images through the bastion registry proxy. Three things are needed:

1. **A push/pull secret.** Run `./main-cluster/bastion-registry/setup-registry-access.sh`. It reads
   the registry token from the HCI cluster and creates a `docker-registry` secret
   (`${REGISTRY_SECRET_NAME}`) in the `hci-node-manager` namespace. For an application in another
   namespace, create the same secret there.
2. **A build that pushes through the proxy.** Point the BuildConfig output at
   `${BASTION_HOST}:${REGISTRY_PROXY_PORT}/<project>/<image>:<tag>` and set the push secret to the
   secret from step 1.
3. **Deployments that pull through the proxy.** Use the same
   `${BASTION_HOST}:${REGISTRY_PROXY_PORT}/<project>/<image>:<tag>` image reference and add the
   secret as an `imagePullSecret`.

The HCI operators are set up exactly this way. See
[Building and Deploying the Operators](../../docs/development/operator-build-deploy.md) for a worked
example (`REGISTRY_PUSH`, `REGISTRY_PULL` and `REGISTRY_SECRET_NAME` in `operator/build/config.env`).

## Troubleshooting

### Setup Fails with "Do not run this script as root"

**Cause:** The script was started as root or with `sudo`.

**Solution:** Run it as your normal user. It requests `sudo` itself for the privileged steps.

### Cluster Configuration Is Skipped

**Cause:** The `oc` command or the `${MAIN_CLUSTER_CONTEXT}` context is missing, or your user cannot patch
`image.config.openshift.io/cluster`. The bastion part is done, but the insecure-registry step is not.

**Solution:** Run the `oc` commands that the script prints from a system where you have cluster-admin
rights, then wait for the MachineConfigPool rollout.

### Workers Cannot Reach Bastion

**Cause:** Firewall or network connectivity issue

**Solution:**
1. Check firewall on bastion: `sudo firewall-cmd --list-ports`
2. Verify port 5443/tcp is open
3. Test from worker: `oc debug node/<worker> -- curl -k https://bastion.cluster.example.com:5443/v2/`

### MachineConfigPool Stuck

**Cause:** Worker nodes not restarting

**Solution:**
1. Check MCP status: `oc get mcp -o yaml`
2. Check node status: `oc get nodes`
3. Manually drain and reboot if needed

### Authentication Fails for amd64 Builds

**Cause:** HAProxy missing response header rewrites

**Solution:** Verify HAProxy configuration includes all three header rewrites:
- Location
- WWW-Authenticate
- Docker-Distribution-Api-Version

## Security Considerations

### Self-Signed Certificate

The bastion proxy uses a **self-signed certificate** because:

1. It's an internal infrastructure component
2. No public CA is needed for internal cluster communication
3. Insecure registry configuration provides the necessary trust

**Security Impact:**
- Traffic is encrypted (HTTPS)
- Certificate validation is skipped (insecure registry)
- Acceptable for internal infrastructure

**Alternative:** Use an internal CA to issue certificates, then add CA to cluster trust instead of using insecure registries.

### Insecure Registry Scope

The insecure registry configuration applies **cluster-wide** but only affects:

- Connections to `bastion.cluster.example.com:5443`
- No impact on other registries
- Other registries still require valid certificates

## Maintenance

### Updating HAProxy Configuration

1. SSH to bastion host
2. Edit `/etc/haproxy/haproxy.cfg`
3. Restart HAProxy: `sudo systemctl restart haproxy`
4. Verify: `curl -k https://localhost:5443/v2/`

### Renewing SSL Certificate

The self-signed certificate expires after 365 days. HAProxy loads the combined file
`/etc/pki/tls/certs/bastion.pem`. To renew:

```bash
ssh bastion.cluster.example.com
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/pki/tls/private/bastion.key \
  -out /etc/pki/tls/certs/bastion.crt \
  -subj "/CN=bastion.cluster.example.com"
sudo bash -c "cat /etc/pki/tls/certs/bastion.crt /etc/pki/tls/private/bastion.key > /etc/pki/tls/certs/bastion.pem"
sudo chmod 600 /etc/pki/tls/certs/bastion.pem /etc/pki/tls/private/bastion.key
sudo chown haproxy:haproxy /etc/pki/tls/certs/bastion.pem
sudo systemctl restart haproxy
```

### Monitoring

Check HAProxy status:
```bash
ssh bastion.cluster.example.com
sudo systemctl status haproxy
sudo journalctl -u haproxy -f
```

## Future Improvements

1. **Proper CA Infrastructure**
   - Internal CA for issuing certificates
   - Add CA to cluster trust
   - Remove insecure registry requirement

2. **Monitoring**
   - HAProxy statistics endpoint
   - Registry traffic metrics
   - Build success/failure rates

3. **High Availability**
   - Multiple bastion hosts
   - Load balancing
   - Failover configuration

## Support

For infrastructure issues:

- **Contact:** Infrastructure Team
- **Script Location:** `main-cluster/bastion-registry/setup-registry-proxy.sh`
- **Logs:** Check HAProxy logs on bastion host

For application deployment issues:

- **Contact:** Application Development Teams
- **Documentation:** See main project README

## References

- [Registry Proxy Technical Documentation](registry-proxy.md)
- [Building and Deploying the Operators](../../docs/development/operator-build-deploy.md)
- [OpenShift Image Configuration](https://docs.openshift.com/container-platform/latest/openshift_images/image-configuration.html)

---

**Note:** This infrastructure is shared across multiple projects. Changes to this setup may affect all teams using the bastion registry proxy.