# Fusion HCI Multi-Architecture Integration

[![Documentation](https://img.shields.io/badge/docs-mkdocs-blue)](https://pages.github.com/IBM/fusion-hci-integration/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Integration solution for adding Fusion HCI x86 worker nodes to s390x/LinuxONE OpenShift clusters, enabling true multi-architecture workload deployment.

## Overview

This project enables **multi-architecture OpenShift clusters** by integrating Fusion HCI (x86) as a compute provider for s390x/LinuxONE-based OpenShift clusters. Worker VMs running on Fusion HCI join the main cluster as x86 worker nodes, allowing workloads to be scheduled across both architectures.

### Key Features

- ✅ **Multi-Architecture Support**: Run x86 and s390x workloads in a single cluster
- ✅ **Network Integration**: Transparent networking via OVN-Kubernetes
- ✅ **Automated Provisioning**: Operator-driven VM deployment (`WorkerPool` CR) with PXE boot
- ✅ **Flexible Deployment**: Supports both private (z/VM) and public (KVM) network topologies
- ✅ **Production Ready**: Comprehensive documentation and troubleshooting guides
- ✅ **Future-Proof**: Operator roadmap for automated lifecycle management

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Main Cluster (s390x/LinuxONE)                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Control Plane│  │ s390x Worker │  │ s390x Worker │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                            │                                │
│                    ┌───────▼────────┐                       │
│                    │ Bastion Node   │                       │
│                    └───────┬────────┘                       │
└────────────────────────────┼──────────────────────────────┘
                             │
                    ┌────────▼─────────┐
                    │   Gateway VM     │ (Routing, DHCP, PXE)
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
      ┌───────▼────────┐           ┌───────▼────────┐
      │  x86 Worker 1  │           │  x86 Worker 2  │
      │  (Fusion HCI)  │           │  (Fusion HCI)  │
      └────────────────┘           └────────────────┘
```

### Components

- **Main Cluster**: s390x/LinuxONE OpenShift cluster (control plane + s390x workers)
- **HCI Cluster**: Fusion HCI cluster providing x86 compute resources
- **Gateway VM**: Bridges networks, provides DHCP/PXE services
- **Worker VMs**: x86 RHCOS nodes that join the main cluster

## Quick Start

### Prerequisites

- OpenShift 4.14+ on s390x/LinuxONE (main cluster)
- Fusion HCI cluster with OpenShift Virtualization
- Network connectivity between clusters
- Cluster-admin access on both clusters

### Installation

The steps below are a summary. See the [Getting Started Guide](docs/getting-started.md) for the full procedure.

0. **Generate workspace configuration**
   ```bash
   mkdir -p workspace
   cp templates/integration-setup.example.yaml workspace/integration-setup.yaml
   # Edit workspace/integration-setup.yaml with your configuration
   ./generate-setup workspace/integration-setup.yaml
   source setup_env.sh
   ```

1. **Prepare Main Cluster**
   ```bash
   # Enable multi-architecture support
   oc adm upgrade --to-multiarch
   
   # Apply MachineConfigs (choose variant: zvm or kvm)
   oc apply -k main-cluster/configuration/overlays/mediated/
   ```

2. **Prepare HCI Cluster**
   ```bash
   # Apply cluster-scoped network configuration (cluster-admin)
   oc apply -f hci-cluster/cluster-network-setup.yaml
   
   # Label namespace for HCI gateway
   oc label namespace <your-namespace> hci-gateway-enabled=true
   ```

3. **Deploy the Operators and Gateway VM**
   ```bash
   # Build and deploy the operators (see docs/development/operator-build-deploy.md)
   pushd operator && make apply-buildconfigs build install deploy && popd

   # Apply the generated WorkerPool CR (workers.count: 0 provisions the gateway only)
   oc apply -f workspace/workerpool-hci-workers.yaml
   ```

4. **Deploy Worker VMs**
   ```bash
   # After the pool is Ready, set spec.consumer.workers.count
   oc -n ${MAIN_INTEGRATION_NAMESPACE} edit workerpool hci-workers
   ```

5. **Verify Integration**
   ```bash
   # Check worker nodes joined
   oc get nodes -l node-role.kubernetes.io/worker
   
   # Verify multi-arch
   oc get nodes -o wide
   ```

## Documentation

Full documentation is available at [https://pages.github.com/IBM/fusion-hci-integration/](https://pages.github.com/IBM/fusion-hci-integration/)

- [Getting Started Guide](docs/getting-started.md) - Step-by-step setup
- [Prerequisites](docs/prerequisites.md) - Requirements and preparation
- [Deployment Variants](docs/deployment-variants.md) - z/VM vs KVM topologies
- [Architecture Overview](docs/architecture/architecture-overview.md) - System design
- [Troubleshooting](docs/operations/troubleshooting.md) - Common issues

### Build Documentation Locally

```bash
pip install mkdocs-material
mkdocs serve
# Open http://localhost:8000
```

## Repository Structure

```
fusion-hci-integration/          # Main source repo (this repo)
├── docs/                        # MkDocs documentation source
├── operator/                    # HCI operator (Ansible-based)
├── hci-cluster/                 # Fusion HCI cluster admin setup (network, registry, RBAC)
├── main-cluster/                # Main s390x cluster manifests
├── templates/                   # CR and config templates
│
├── ops/                         # fusion-hci-ops repo (separate git, .gitignore'd)
│   ├── docs/runbooks/           # Operational runbooks (own mkdocs site)
│   └── scripts/                 # Operational scripts
│
└── wiki/                        # fusion-hci-integration.wiki repo (separate git, .gitignore'd)
                                 # Incident post-mortems and operational knowledge
```

> **Note:** `ops/` and `wiki/` are separate git repositories checked out as subdirectories.
> They are listed in `.gitignore` and are not part of this repo's commit history.
> Runbooks in `ops/docs/runbooks/` are published by the ops repo's own mkdocs, not this site.
> Wiki pages in `wiki/` are published to the GHE project wiki.

## Deployment Variants

### z/VM Variant (Private Network)
- Main cluster nodes in private network
- Bastion provides routing and DNS
- Common in z/VM environments

### KVM Variant (Public Network)
- Main cluster nodes on shared network
- Direct connectivity to HCI
- Requires static route on master nodes

See [Deployment Variants](docs/deployment-variants.md) for details.

## Use Cases

### Multi-Architecture Workloads
Run applications that require both s390x and x86 architectures in a single cluster:
- Legacy s390x applications alongside modern x86 microservices
- CI/CD pipelines building for multiple architectures
- Hybrid workloads leveraging strengths of each architecture

### Capacity Expansion
Add x86 compute capacity to s390x clusters:
- Scale out with cost-effective x86 hardware
- Maintain s390x for critical workloads
- Flexible resource allocation

### Development & Testing
Test multi-architecture deployments:
- Validate application portability
- Test architecture-specific optimizations
- Develop cross-platform solutions

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Areas for Contribution
- Documentation improvements
- Bug fixes and enhancements
- Additional deployment variants
- Operator development (see [operator/README.md](operator/README.md))

## Future Roadmap

### Operator-Based Automation
We're planning an Ansible-based operator for automated lifecycle management. See [operator/README.md](operator/README.md) for the vision and roadmap.

### Additional Architectures
The architecture is designed to support additional platforms:
- ARM-based main clusters
- Power-based main clusters
- Additional HCI platforms

## Support

- **Documentation**: [https://pages.github.com/IBM/fusion-hci-integration/](https://pages.github.com/IBM/fusion-hci-integration/)
- **Issues**: [GitHub Issues](https://github.com/IBM/fusion-hci-integration/issues)
- **Discussions**: [GitHub Discussions](https://github.com/IBM/fusion-hci-integration/discussions)

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Acknowledgments

This project builds on OpenShift's multi-architecture capabilities and leverages:
- OpenShift Virtualization
- OVN-Kubernetes networking
- Kustomize for configuration management

---

**Status**: Alpha | **Version**: 0.2.0 | **Last Updated**: June 2026