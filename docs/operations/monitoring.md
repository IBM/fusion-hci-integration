# Monitoring Guide

This document describes how to monitor the Fusion HCI multi-architecture integration, including key metrics, dashboards, and alerting strategies.

!!! info "Monitoring integration components"
    Monitoring covers both the HCI cluster infrastructure (gateway VM, worker VMs,
    OVN networks) and the main cluster integration (x86 worker nodes, CSR approval,
    Node Manager operator).

    | Monitored Area | Cluster / Namespace | Key Components |
    |---|---|---|
    | Gateway VM & services | HCI cluster (`${HCI_INTEGRATION_NAMESPACE}`) | `vmi/hci-gateway`, `dnsmasq`, `nginx`, `rhcos-sync` |
    | Worker VMs | HCI cluster (`${HCI_INTEGRATION_NAMESPACE}`) | `vmi/worker-x86-*`, KubeVirt virt-launcher |
    | Worker Nodes | Main cluster | `node/worker-x86-*`, kubelet, CRI-O |
    | Integration Operator | Main cluster (`${MAIN_INTEGRATION_NAMESPACE}`) | `hci-consumer-operator`, `node-labeler`, `csr-approver` |

## Overview

Effective monitoring covers:

1. **Gateway VM** - Routing and services health (`dnsmasq`, `nginx`, `rhcos-sync`)
2. **Worker VMs** - VM and node status
3. **Network** - Connectivity and performance (internal UDN, gateway routing)
4. **Integration Health** - Overall system status, CSR approval, and WorkerPool reconciliation

## Monitoring Stack

### OpenShift Built-in Monitoring

**Components:**
- Prometheus - Metrics collection and storage
- Grafana - Visualization and dashboards
- Alertmanager - Alert routing and notification

**Access:**
```bash
# OpenShift console
https://console-openshift-console.apps.cluster.example.com

# Navigate to: Observe → Dashboards/Metrics/Alerts
```

### Custom Metrics

**ServiceMonitor for Gateway VM:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hci-gateway-monitor
  namespace: main-cluster-workers
spec:
  selector:
    matchLabels:
      app: worker-vm-router
  endpoints:
  - port: metrics
    interval: 30s
```

## Key Metrics

### Gateway VM Metrics

#### Network Throughput

**Metric:** `node_network_receive_bytes_total`, `node_network_transmit_bytes_total`

**Query:**
```promql
# Receive rate (bytes/sec)
rate(node_network_receive_bytes_total{device="eth1"}[5m])

# Transmit rate (bytes/sec)
rate(node_network_transmit_bytes_total{device="eth1"}[5m])
```

**Thresholds:**
- Normal: < 1 Gbps
- Warning: > 5 Gbps
- Critical: > 8 Gbps (approaching VM limit)

#### Packet Loss

**Metric:** `node_network_receive_drop_total`, `node_network_transmit_drop_total`

**Query:**
```promql
# Packet drop rate
rate(node_network_receive_drop_total{device="eth1"}[5m])
```

**Thresholds:**
- Normal: 0 drops/sec
- Warning: > 10 drops/sec
- Critical: > 100 drops/sec

#### CPU Utilization

**Metric:** `node_cpu_seconds_total`

**Query:**
```promql
# CPU usage percentage
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

**Thresholds:**
- Normal: < 50%
- Warning: > 70%
- Critical: > 90%

#### Memory Utilization

**Metric:** `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes`

**Query:**
```promql
# Memory usage percentage
100 - ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)
```

**Thresholds:**
- Normal: < 70%
- Warning: > 80%
- Critical: > 95%

#### DHCP Service

**Metric:** Custom metric from dnsmasq

**Query:**
```promql
# DHCP leases active
dnsmasq_leases_active
```

**Thresholds:**
- Normal: Matches expected worker count
- Warning: Unexpected lease count
- Critical: DHCP service down

### Worker VM Metrics

#### VM Status

**Metric:** `kubevirt_vmi_phase_count`

**Query:**
```promql
# Running VMs on HCI cluster
kubevirt_vmi_phase_count{phase="Running", namespace="main-cluster-workers"}
```

**Thresholds:**
- Normal: Matches expected count
- Warning: < expected count
- Critical: 0 VMs running

#### Node Status

**Metric:** `kube_node_status_condition`

**Query:**
```promql
# Ready nodes
kube_node_status_condition{condition="Ready", status="true", node=~"worker-x86-.*"}
```

**Thresholds:**
- Normal: All nodes Ready
- Warning: Any node NotReady
- Critical: Multiple nodes NotReady

#### Resource Utilization

**CPU:**
```promql
# Node CPU usage
100 - (avg by (node) (rate(node_cpu_seconds_total{mode="idle", node=~"worker-x86-.*"}[5m])) * 100)
```

**Memory:**
```promql
# Node memory usage
100 - ((node_memory_MemAvailable_bytes{node=~"worker-x86-.*"} / node_memory_MemTotal_bytes{node=~"worker-x86-.*"}) * 100)
```

**Thresholds:**
- Normal: < 80%
- Warning: > 85%
- Critical: > 95%

### Network Metrics

#### Latency

**Metric:** Custom metric from network probes

**Query:**
```promql
# Ping latency to gateway
probe_duration_seconds{target="192.168.100.1"}
```

**Thresholds:**
- Normal: < 2ms
- Warning: > 5ms
- Critical: > 10ms

#### Connectivity

**Metric:** `probe_success`

**Query:**
```promql
# Gateway reachability
probe_success{target="192.168.100.1"}
```

**Thresholds:**
- Normal: 1 (success)
- Critical: 0 (failure)

### Integration Health Metrics

#### CSR Approval Rate

**Metric:** `csr_approval_duration_seconds`

**Query:**
```promql
# Average CSR approval time
avg(csr_approval_duration_seconds{node=~"worker-x86-.*"})
```

**Thresholds:**
- Normal: < 60 seconds
- Warning: > 120 seconds
- Critical: > 300 seconds

#### Node Join Time

**Metric:** Custom metric tracking node join duration

**Query:**
```promql
# Time from VM start to node Ready
node_join_duration_seconds{node=~"worker-x86-.*"}
```

**Thresholds:**
- Normal: < 600 seconds (10 minutes)
- Warning: > 900 seconds (15 minutes)
- Critical: > 1800 seconds (30 minutes)

## Dashboards

### Gateway VM Dashboard

**Panels:**

1. **Network Throughput**
   - Line graph: Receive/transmit rates
   - Time range: Last 6 hours

2. **Resource Utilization**
   - Gauge: CPU usage
   - Gauge: Memory usage
   - Gauge: Disk usage

3. **Service Status**
   - Stat: dnsmasq status
   - Stat: nginx status
   - Stat: Active DHCP leases

4. **Packet Statistics**
   - Line graph: Packet drops
   - Line graph: Packet errors

**JSON Export:**
```json
{
  "dashboard": {
    "title": "Gateway VM Monitoring",
    "panels": [
      {
        "title": "Network Throughput",
        "targets": [
          {
            "expr": "rate(node_network_receive_bytes_total{device='eth1'}[5m])"
          }
        ]
      }
    ]
  }
}
```

### Worker Nodes Dashboard

**Panels:**

1. **Node Status**
   - Table: Node name, status, age
   - Color coding: Green (Ready), Red (NotReady)

2. **Resource Utilization**
   - Heatmap: CPU usage per node
   - Heatmap: Memory usage per node

3. **Pod Count**
   - Bar graph: Pods per node
   - Stacked by namespace

4. **Network Traffic**
   - Line graph: Network I/O per node

### Integration Health Dashboard

**Panels:**

1. **VM Status**
   - Stat: Total VMs
   - Stat: Running VMs
   - Stat: Failed VMs

2. **Node Status**
   - Stat: Total nodes
   - Stat: Ready nodes
   - Stat: NotReady nodes

3. **CSR Status**
   - Stat: Pending CSRs
   - Stat: Approved CSRs
   - Line graph: CSR approval rate

4. **Network Health**
   - Stat: Gateway reachability
   - Line graph: Latency to gateway
   - Line graph: Packet loss rate

## Alerting

### Alert Rules

#### Gateway VM Down

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hci-gateway-alerts
  namespace: main-cluster-workers
spec:
  groups:
  - name: hci-gateway
    interval: 30s
    rules:
    - alert: GatewayVMDown
      expr: kubevirt_vmi_phase_count{name="hci-gateway", phase="Running"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Gateway VM is down"
        description: "Gateway VM {{ $labels.name }} is not running"
```

#### High Network Utilization

```yaml
- alert: GatewayHighNetworkUtilization
  expr: rate(node_network_transmit_bytes_total{device="eth1"}[5m]) > 8e9
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Gateway VM network utilization high"
    description: "Network throughput > 8 Gbps for 5 minutes"
```

#### Worker Node NotReady

```yaml
- alert: WorkerNodeNotReady
  expr: kube_node_status_condition{condition="Ready", status="true", node=~"worker-x86-.*"} == 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Worker node not ready"
    description: "Node {{ $labels.node }} is NotReady for 5 minutes"
```

#### CSR Approval Delayed

```yaml
- alert: CSRApprovalDelayed
  expr: count(kube_certificatesigningrequest_condition{condition="Approved", status="false"}) > 0
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "CSR approval delayed"
    description: "{{ $value }} CSRs pending approval for > 10 minutes"
```

#### Network Connectivity Lost

```yaml
- alert: GatewayUnreachable
  expr: probe_success{target="192.168.100.1"} == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Gateway VM unreachable"
    description: "Cannot reach gateway VM at 192.168.100.1"
```

### Alert Routing

**Alertmanager Configuration:**
```yaml
route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'
  routes:
  - match:
      severity: critical
    receiver: 'pagerduty'
  - match:
      severity: warning
    receiver: 'slack'

receivers:
- name: 'default'
  email_configs:
  - to: 'team@example.com'

- name: 'pagerduty'
  pagerduty_configs:
  - service_key: '<pagerduty-key>'

- name: 'slack'
  slack_configs:
  - api_url: '<slack-webhook-url>'
    channel: '#hci-alerts'
```

## Logging

### Gateway VM Logs

**Access (via SSH to the gateway):**
```bash
# SSH into gateway VM
ssh core@172.16.1.100

# dnsmasq logs
sudo journalctl -u dnsmasq -f

# nginx logs (boot files & ignition requests)
sudo tail -f /var/log/nginx/access.log

# RHCOS sync timer logs
sudo journalctl -u rhcos-sync.service -f

# System logs
sudo journalctl -f
```

**Key Log Patterns:**

**DHCP Lease:**
```
DHCPACK(eth2) 192.168.100.10 52:54:01:00:00:10 worker-x86-1
```

**PXE Boot & iPXE Chaining:**
```
TFTP sent /var/lib/tftpboot/undionly.kpxe to 192.168.100.10
GET /boot.ipxe HTTP/1.1" 200 ...
GET /rhcos/rhcos-live-kernel-x86_64 HTTP/1.1" 200 ...
GET /rhcos/rhcos-live-initramfs.x86_64.img HTTP/1.1" 200 ...
GET /rhcos/worker-hci.ign HTTP/1.1" 200 ...
```

**DNS Query:**
```
query[A] api.cluster.example.com from 192.168.100.10
```

### Worker Node Logs

**Access:**
```bash
# Kubelet logs
oc --context ${MAIN_CLUSTER_CONTEXT} adm node-logs worker-x86-1 -u kubelet

# Machine config daemon logs
oc --context ${MAIN_CLUSTER_CONTEXT} adm node-logs worker-x86-1 -u machine-config-daemon

# CRI-O logs
oc --context ${MAIN_CLUSTER_CONTEXT} adm node-logs worker-x86-1 -u crio
```

### Centralized Logging

**Using OpenShift Logging (Vector / Loki):**
```bash
# Install logging operator
oc --context ${MAIN_CLUSTER_CONTEXT} create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-5.9
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Create ClusterLogForwarder instance
oc --context ${MAIN_CLUSTER_CONTEXT} create -f - <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  managementState: Managed
  serviceAccount:
    name: logcollector
  pipelines:
    - name: default-pipeline
      inputRefs:
        - application
        - infrastructure
      outputRefs:
        - default-loki
  outputs:
    - name: default-loki
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
        authentication:
          token:
            from: serviceAccount
EOF
```

## Performance Monitoring

### Network Performance

**Tools:**
```bash
# iperf3 between gateway and worker
# On gateway VM:
iperf3 -s

# On worker:
iperf3 -c 192.168.100.1 -t 60

# Expected: > 1 Gbps
```

**Latency Testing:**
```bash
# Ping test
ping -c 100 192.168.100.1 | tail -1

# Expected: avg < 2ms
```

### Resource Monitoring

**Node Exporter Metrics:**
```bash
# CPU usage
curl -s http://worker-x86-1:9100/metrics | grep node_cpu_seconds_total

# Memory usage
curl -s http://worker-x86-1:9100/metrics | grep node_memory

# Disk I/O
curl -s http://worker-x86-1:9100/metrics | grep node_disk
```

## Troubleshooting with Monitoring

### High Latency

**Check:**
1. Gateway VM CPU usage
2. Network throughput
3. Packet loss rate

**Queries:**
```promql
# CPU usage
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Network throughput
rate(node_network_transmit_bytes_total[5m])

# Packet loss
rate(node_network_transmit_drop_total[5m])
```

### Node NotReady

**Check:**
1. Node conditions
2. Kubelet status
3. Network connectivity

**Commands:**
```bash
# Node conditions
oc --context ${MAIN_CLUSTER_CONTEXT} describe node worker-x86-1 | grep Conditions -A 10

# Kubelet logs
oc --context ${MAIN_CLUSTER_CONTEXT} adm node-logs worker-x86-1 -u kubelet --tail=50

# Network test
oc --context ${MAIN_CLUSTER_CONTEXT} debug node/worker-x86-1 -- chroot /host ping -c 3 api.cluster.example.com
```

### VM Performance Issues

**Check:**
1. VM resource allocation
2. Host node resources
3. Storage performance

**Queries:**
```promql
# VM CPU usage
kubevirt_vmi_vcpu_seconds

# VM memory usage
kubevirt_vmi_memory_resident_bytes

# Storage latency
kubevirt_vmi_storage_iops_read_total
```

## Best Practices

### Monitoring Strategy

1. **Proactive monitoring** - Set up alerts before issues occur
2. **Baseline metrics** - Establish normal operating ranges
3. **Regular review** - Review dashboards and alerts weekly
4. **Capacity planning** - Monitor trends for growth planning

### Alert Management

1. **Meaningful alerts** - Only alert on actionable issues
2. **Appropriate severity** - Critical for immediate action, warning for investigation
3. **Clear descriptions** - Include context and remediation steps
4. **Avoid alert fatigue** - Tune thresholds to reduce noise

### Dashboard Design

1. **Purpose-driven** - One dashboard per role/task
2. **Key metrics first** - Most important metrics at top
3. **Consistent layout** - Similar panels in similar positions
4. **Appropriate time ranges** - Match to use case

### Log Management

1. **Structured logging** - Use consistent log formats
2. **Appropriate levels** - INFO for normal, ERROR for issues
3. **Retention policy** - Balance storage vs. history needs
4. **Regular review** - Check logs for patterns

## References

- [Troubleshooting Guide](troubleshooting.md)
- [Architecture Overview](../architecture/architecture-overview.md)
- [OpenShift Monitoring Documentation](https://docs.openshift.com/container-platform/latest/monitoring/monitoring-overview.html)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)