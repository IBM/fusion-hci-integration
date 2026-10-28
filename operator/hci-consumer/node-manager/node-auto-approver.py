#!/usr/bin/env python3
"""
Automatic Node CSR Approver and Labeler for HCI Workers

Watches for CSRs from new nodes, approves them, and labels nodes based on IP.
Handles the complete node joining workflow:
1. Approve bootstrap CSR (client cert)
2. Wait for node to appear
3. Label node if IP is in target network
4. Approve kubelet serving CSR (server cert)
"""

import logging
import sys
import time
import re
import os
from typing import Dict, Optional
from datetime import datetime, timedelta, timezone
from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger('node-auto-approver')

# ConfigMap written by sync_node_manager_config.yml that both sidecars read.
NODE_MANAGER_CONFIGMAP = 'hci-node-manager-config'


def get_node_name_pattern() -> str:
    """
    Read NODE_NAME_PATTERN from the hci-node-manager-config ConfigMap via the
    Kubernetes API. This is immune to the race where the pod starts before the
    ConfigMap is created by the operator's first reconcile — envFrom snapshots
    the env at pod-creation time and misses a ConfigMap that didn't exist yet.
    Falls back to the NODE_NAME_PATTERN env var only if the ConfigMap or key is
    absent (e.g. during local development without in-cluster config).
    """
    namespace = os.getenv('WATCH_NAMESPACE', os.getenv('POD_NAMESPACE', 'hci-node-manager'))
    try:
        v1 = client.CoreV1Api()
        cm = v1.read_namespaced_config_map(NODE_MANAGER_CONFIGMAP, namespace)
        pattern = (cm.data or {}).get('NODE_NAME_PATTERN')
        if pattern:
            logger.info(f"NODE_NAME_PATTERN from ConfigMap: {pattern}")
            return pattern
        logger.warning(f"NODE_NAME_PATTERN key absent in ConfigMap {NODE_MANAGER_CONFIGMAP}, using env fallback")
    except ApiException as e:
        logger.warning(f"Could not read ConfigMap {NODE_MANAGER_CONFIGMAP} ({e}), using env fallback")
    fallback = os.getenv('NODE_NAME_PATTERN', 'worker')
    logger.warning(f"NODE_NAME_PATTERN fallback: {fallback}")
    return fallback


def get_cluster_domain() -> str:
    """
    Derive the cluster base domain from the OpenShift DNS config object.
    Falls back to the MAIN_CLUSTER_DOMAIN env var (legacy) or 'cluster.local'
    only if the API call fails.
    """
    try:
        custom_api = client.CustomObjectsApi()
        dns = custom_api.get_cluster_custom_object(
            group="config.openshift.io",
            version="v1",
            plural="dnses",
            name="cluster",
        )
        base_domain = dns["spec"]["baseDomain"]
        logger.info(f"Cluster domain from DNS config: {base_domain}")
        return base_domain
    except Exception as e:
        fallback = os.getenv('MAIN_CLUSTER_DOMAIN', os.getenv('CLUSTER_DOMAIN', 'cluster.local'))
        logger.warning(f"Could not fetch DNS config ({e}), falling back to: {fallback}")
        return fallback

# CSR Signer Names
BOOTSTRAP_SIGNER = 'kubernetes.io/kube-apiserver-client-kubelet'
KUBELET_SERVING_SIGNER = 'kubernetes.io/kubelet-serving'

# State tracking timeout
STATE_TIMEOUT = timedelta(minutes=30)


class NodeJoinState:
    """Track the state of a node joining the cluster."""

    def __init__(self, node_name):
        self.node_name = node_name
        self.bootstrap_csr_approved = False
        self.node_appeared = False
        self.node_labeled = False
        self.serving_csr_approved = False
        self.first_seen = datetime.now()

    def is_complete(self):
        """Check if node joining is complete."""
        return self.serving_csr_approved

    def is_expired(self):
        """Check if state has expired."""
        return datetime.now() - self.first_seen > STATE_TIMEOUT


class NodeJoinTracker:
    """Track node joining progress."""
    
    def __init__(self):
        self.states: Dict[str, NodeJoinState] = {}
    
    def get_or_create(self, node_name: str) -> NodeJoinState:
        """Get or create state for a node."""
        if node_name not in self.states:
            self.states[node_name] = NodeJoinState(node_name=node_name)
            logger.info(f"Started tracking node join: {node_name}")
        return self.states[node_name]
    
    def cleanup_expired(self):
        """Remove expired state entries."""
        expired = [name for name, state in self.states.items() if state.is_expired()]
        for name in expired:
            logger.warning(f"Removing expired state for node: {name}")
            del self.states[name]
    
    def get_state(self, node_name: str) -> Optional[NodeJoinState]:
        """Get state for a node if it exists."""
        return self.states.get(node_name)


def extract_node_name_from_csr(csr) -> Optional[str]:
    """
    Extract node name from CSR certificate request.
    For bootstrap CSRs, the username is system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
    but the node name is in the certificate request CN field.
    For serving CSRs, the username is system:node:<nodename>
    """
    if not csr.spec:
        logger.debug(f"CSR {csr.metadata.name} has no spec")
        return None
    
    # Try username first (for serving CSRs)
    if csr.spec.username and csr.spec.username.startswith('system:node:'):
        node_name = csr.spec.username.replace('system:node:', '')
        logger.debug(f"Extracted node name from username: {node_name}")
        return node_name
    
    # For bootstrap CSRs, extract from certificate request
    if csr.spec.request:
        import base64
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.backends import default_backend
        try:
            # Decode base64 certificate request
            cert_req_bytes = base64.b64decode(csr.spec.request)
            
            # Parse the CSR using cryptography library (PEM format)
            cert_req = x509.load_pem_x509_csr(cert_req_bytes, default_backend())
            
            # Extract the Common Name (CN) from the subject
            for attribute in cert_req.subject:
                if attribute.oid == NameOID.COMMON_NAME:
                    cn_value = attribute.value
                    # Check if CN is in format system:node:<nodename>
                    if cn_value.startswith('system:node:'):
                        node_name = cn_value.replace('system:node:', '')
                        logger.debug(f"Extracted node name from CSR: {node_name}")
                        return node_name
            
            logger.debug(f"No system:node: CN found in CSR")
        except Exception as e:
            logger.debug(f"Could not extract node name from certificate request: {e}")
    
    return None


def matches_node_pattern(node_name: str, name_pattern: str, cluster_domain: str) -> bool:
    """Check if node name matches the configured pattern."""
    # Build full pattern: <prefix>-<number>.<domain>
    # Example: worker-x86-1.cluster.example.com
    pattern = f"^{re.escape(name_pattern)}-\\d+\\.{re.escape(cluster_domain)}$"
    matches = bool(re.match(pattern, node_name))
    logger.debug(f"Pattern matching: node='{node_name}', pattern='{pattern}', matches={matches}")
    return matches


def approve_csr(cert_api: client.CertificatesV1Api, csr_name: str, signer: str) -> bool:
    """Approve a CSR."""
    try:
        # Get current CSR
        csr = cert_api.read_certificate_signing_request(csr_name)
        
        # Check if already approved
        if csr.status and csr.status.conditions:
            for condition in csr.status.conditions:
                if condition.type == 'Approved':
                    logger.debug(f"CSR {csr_name} already approved")
                    return True
        
        # Approve the CSR
        approval = client.V1CertificateSigningRequestCondition(
            type='Approved',
            status='True',
            reason='AutoApproved',
            message=f'Auto-approved by node-auto-approver for {signer}',
            last_update_time=datetime.now(timezone.utc)
        )
        
        csr.status = client.V1CertificateSigningRequestStatus(conditions=[approval])
        cert_api.replace_certificate_signing_request_approval(csr_name, csr)
        
        logger.info(f"✓ Approved CSR: {csr_name} (signer: {signer})")
        return True
        
    except ApiException as e:
        logger.error(f"✗ Failed to approve CSR {csr_name}: {e}")
        return False


def process_csr(cert_api: client.CertificatesV1Api, v1: client.CoreV1Api,
                csr, tracker: NodeJoinTracker, name_pattern: str, cluster_domain: str) -> None:
    """Process a CSR and approve if node matches pattern."""
    csr_name = csr.metadata.name
    signer = csr.spec.signer_name if csr.spec else None
    
    logger.debug(f"Processing CSR {csr_name} with signer {signer}")
    
    # Extract node name from CSR
    node_name = extract_node_name_from_csr(csr)
    if not node_name:
        logger.debug(f"Could not extract node name from CSR {csr_name}")
        return
    
    logger.info(f"CSR {csr_name}: Extracted node name: {node_name}")
    
    # Check if node matches our pattern
    if not matches_node_pattern(node_name, name_pattern, cluster_domain):
        logger.info(f"CSR {csr_name} for node {node_name} doesn't match pattern, skipping")
        return
    
    # Get or create state for tracking
    state = tracker.get_or_create(node_name)
    
    # Handle bootstrap CSR - approve ALL bootstrap CSRs until node appears
    if signer == BOOTSTRAP_SIGNER:
        # Check if node already exists
        try:
            node = v1.read_node(node_name)
            state.node_appeared = True
            logger.debug(f"Node {node_name} already exists, skipping bootstrap CSR approval")
        except ApiException as e:
            if e.status == 404:
                # Node doesn't exist yet, approve the bootstrap CSR
                logger.info(f"Processing bootstrap CSR for node: {node_name} (node not yet present)")
                if approve_csr(cert_api, csr_name, signer):
                    state.bootstrap_csr_approved = True
                    logger.info(f"✓ Bootstrap CSR approved for {node_name}, waiting for node to appear...")
            else:
                logger.error(f"Error checking node existence: {e}")
    
    # Handle kubelet serving CSR - approve if node exists
    elif signer == KUBELET_SERVING_SIGNER:
        # Check if node exists
        try:
            node = v1.read_node(node_name)
            state.node_appeared = True
            
            # Approve serving CSR (node-labeler will handle labeling separately)
            logger.info(f"Processing kubelet serving CSR for node: {node_name}")
            if approve_csr(cert_api, csr_name, signer):
                state.serving_csr_approved = True
                logger.info(f"✓ Serving CSR approved for {node_name}!")
        except ApiException as e:
            if e.status == 404:
                logger.debug(f"Node {node_name} not found yet, cannot approve serving CSR")
            else:
                logger.error(f"Error processing serving CSR: {e}")


def watch_csrs(cert_api: client.CertificatesV1Api, v1: client.CoreV1Api,
               cluster_domain: str):
    """Watch for CSRs and process them.

    node_name_pattern is re-read from the ConfigMap on every watch restart
    (every ~30 s timeout cycle). This means the approver picks up the correct
    pattern as soon as the operator's first reconcile writes hci-node-manager-config
    — no pod restart required even when the pod starts before any WorkerPool CR
    exists.
    """
    logger.info("Starting CSR watch...")
    logger.info("Note: Node labeling is handled by the separate node-labeler service")

    tracker = NodeJoinTracker()
    w = watch.Watch()

    # Process existing CSRs first, reading the pattern once before the loop.
    name_pattern = get_node_name_pattern()
    logger.info(f"Node pattern: {name_pattern}-<N>.{cluster_domain}")
    try:
        csrs = cert_api.list_certificate_signing_request()
        logger.info(f"Processing {len(csrs.items)} existing CSRs...")
        for csr in csrs.items:
            process_csr(cert_api, v1, csr, tracker, name_pattern, cluster_domain)
    except ApiException as e:
        logger.error(f"Error processing existing CSRs: {e}")

    # Watch for new CSRs. Re-read the pattern on every watch restart so that
    # a pod that started before any WorkerPool CR existed will automatically
    # pick up the correct pattern within one timeout cycle (~30 s) once the
    # operator's first reconcile has written the ConfigMap — no manual restart
    # required.
    while True:
        try:
            for event in w.stream(cert_api.list_certificate_signing_request, timeout_seconds=30):
                event_type = event['type']
                csr = event['object']

                if event_type in ['ADDED', 'MODIFIED']:
                    process_csr(cert_api, v1, csr, tracker, name_pattern, cluster_domain)

            # Watch timed out — re-read pattern before next iteration.
            tracker.cleanup_expired()
            name_pattern = get_node_name_pattern()
            logger.debug(f"Watch restarted. Node pattern: {name_pattern}-<N>.{cluster_domain}")

        except ApiException as e:
            if e.status == 410:
                logger.warning("Watch expired (410), restarting...")
                name_pattern = get_node_name_pattern()
                logger.debug(f"Node pattern after 410 restart: {name_pattern}-<N>.{cluster_domain}")
                continue
            else:
                logger.error(f"API error during watch: {e}")
                time.sleep(5)
        except Exception as e:
            logger.error(f"Unexpected error during watch: {e}")
            time.sleep(5)


def main():
    """Main entry point."""
    logger.info("Starting node auto-approver...")

    # Load kubernetes config
    try:
        config.load_incluster_config()
        logger.info("Loaded in-cluster config")
    except config.ConfigException:
        try:
            config.load_kube_config()
            logger.info("Loaded kubeconfig")
        except config.ConfigException:
            logger.error("Could not load kubernetes config")
            sys.exit(1)

    # Create API clients
    cert_api = client.CertificatesV1Api()
    v1 = client.CoreV1Api()

    # Cluster domain is stable for the lifetime of the cluster — read once.
    # Node name pattern is read inside watch_csrs on every restart cycle so it
    # picks up ConfigMap changes without requiring a pod restart.
    cluster_domain = get_cluster_domain()

    # Start watching CSRs
    watch_csrs(cert_api, v1, cluster_domain)


if __name__ == "__main__":
    main()

# Made with Bob