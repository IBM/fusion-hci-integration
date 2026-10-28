# Fusion HCI Multi-Architecture Integration

Welcome to the Fusion HCI Multi-Architecture Integration documentation. This project enables seamless integration of Fusion HCI x86 worker nodes into s390x/LinuxONE OpenShift clusters, creating true multi-architecture deployments.

!!! note "Architecture Flexibility"
    While this project focuses on s390x/LinuxONE as the main cluster architecture, the solution is designed to be architecture-agnostic. The same principles and components can be adapted for ARM or Power-based main clusters. The network integration, VM provisioning, and configuration management patterns are applicable across different CPU architectures.

## What is This?

This integration solution allows you to:

- **Extend s390x clusters** with x86 compute capacity from Fusion HCI
- **Run multi-architecture workloads** in a single OpenShift cluster
- **Leverage both architectures** for optimal workload placement
- **Maintain unified management** across different CPU architectures

## Architecture Overview

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

### Key Components

- **Main Cluster**: Your primary OpenShift cluster (s390x/LinuxONE, ARM, or Power)
- **HCI Cluster**: Fusion HCI cluster providing x86 compute resources
- **Gateway VM**: Network bridge providing DHCP, PXE, and routing
- **Worker VMs**: x86 RHCOS nodes that join the main cluster

## Quick Links

### Getting Started
- [Prerequisites](prerequisites.md) - What you need before starting
- [Getting Started Guide](getting-started.md) - Step-by-step deployment
- [Deployment Variants](deployment-variants.md) - Choose Mediated or Direct topology

### Architecture
- [Architecture Overview](architecture/architecture-overview.md) - System design
- [Network Design](architecture/network-design.md) - Network topology details
- [VM Provisioning](architecture/vm-provisioning.md) - How VMs are deployed

### Configuration
- [HCI Cluster Setup](configuration/hci-cluster.md) - Configure Fusion HCI
- [Main Cluster Setup](configuration/main-cluster.md) - Configure main cluster
- [Kustomize Overlays](configuration/kustomize-overlays.md) - Variant configuration

### Operations
- [Troubleshooting](operations/troubleshooting.md) - Common issues and solutions
- [Monitoring](operations/monitoring.md) - Monitor your deployment

### Development
- [Developer Notes](development/developer-notes.md) - Technical decisions and learnings
- [Contributing](CONTRIBUTING.md) - How to contribute
- [Operator Roadmap](development/operator-roadmap.md) - Automation roadmap and implementation status

### Operators
- [hci-consumer Operator](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-consumer/README.md) - Steady-state worker VM lifecycle operator
- [hci-provisioner Operator](https://github.com/IBM/fusion-hci-integration/blob/main/operator/hci-provisioner/) - Bootstrap and teardown of gateway VM, UDN, and ignition
- [Provider/Consumer Model](architecture/provider-consumer-model.md) - Three-actor architecture design

## Use Cases

### Multi-Architecture Workloads
Run applications that require both architectures:

- Legacy mainframe applications alongside modern x86 microservices
- CI/CD pipelines building for multiple architectures
- Hybrid workloads leveraging strengths of each architecture

### Capacity Expansion
Add x86 compute capacity to your main cluster:

- Scale out with cost-effective x86 hardware
- Maintain primary architecture for critical workloads
- Flexible resource allocation

### Development & Testing
Test multi-architecture deployments:

- Validate application portability
- Test architecture-specific optimizations
- Develop cross-platform solutions

## Features

✅ **Production Ready**: Comprehensive testing and documentation
✅ **Flexible Deployment**: Supports Mediated and Direct network topologies
✅ **Operator-Driven Provisioning**: Gateway VM, UDN, ignition, and worker VM lifecycle fully managed by `hci-provisioner` and `hci-consumer` operators
✅ **Network Integration**: Transparent networking via OVN-Kubernetes
✅ **Security**: Network isolation and access control
✅ **Architecture Agnostic**: Adaptable to ARM, Power, or other architectures
🚧 **HCI Provider Operator**: Epics 3–4 (HCI-side automation, negotiation flow) in backlog

## Deployment Variants

This solution supports two network topology variants:

### Mediated Topology (Private Network)
- Main cluster nodes in private network behind bastion
- Bastion provides routing and DNS
- Common in z/VM, LPAR, or highly secured environments

### Direct Topology (Public Network)
- Main cluster nodes on shared public network
- Direct connectivity to HCI gateway
- Requires static route on master nodes
- Common in KVM, bare metal, or less restricted environments

See [Deployment Variants](deployment-variants.md) for detailed comparison.

## Quick Start

1. **Prepare Main Cluster**
   ```bash
   oc adm upgrade --to-multiarch
   oc apply -k main-cluster/configuration/overlays/mediated/
   ```

2. **Prepare HCI Cluster (cluster-admin, one-time)**
   ```bash
   oc apply -f hci-cluster/cluster-network-setup.yaml
   oc label namespace <namespace> hci-gateway-enabled=true
   ```

3. **Set up credentials**
   ```bash
   ./operator/setup-provider-credentials.sh
   ```

4. **Apply a `WorkerPool` CR** — the operators provision everything automatically:
   ```bash
   oc apply -f operator/hci-consumer/config/samples/workerpool-sample.yaml
   ```
   The `hci-consumer` operator creates the `WorkerPoolProvisioning` CR for you.
   The `hci-provisioner` runs all bootstrap steps, then `hci-consumer` scales up.

See [Getting Started](getting-started.md) for detailed instructions.

## Support & Community

- **Documentation**: You're reading it!
- **Issues**: [GitHub Issues](https://github.com/IBM/fusion-hci-integration/issues)
- **Discussions**: [GitHub Discussions](https://github.com/IBM/fusion-hci-integration/discussions)
- **Source Code**: [GitHub Repository](https://github.com/IBM/fusion-hci-integration)

## License

This project is licensed under the Apache License 2.0.

## Acknowledgments

This project builds on:

- OpenShift's multi-architecture capabilities
- OpenShift Virtualization
- OVN-Kubernetes networking
- Kustomize for configuration management
- Ansible Operator (operator-sdk Ansible plugin)

---

**Ready to get started?** Head to the [Prerequisites](prerequisites.md) page to begin your journey!