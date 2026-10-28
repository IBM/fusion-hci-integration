#!/usr/bin/env python3
"""
Automatic Node Labeler for workers-hci
Watches for new nodes and labels them based on their IP address network.
"""

import logging
import os
import re
import sys
import time
from typing import Optional, Tuple
from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger('node-labeler')

# ConfigMap written by sync_node_manager_config.yml that both sidecars read.
NODE_MANAGER_CONFIGMAP = 'hci-node-manager-config'

TARGET_LABEL = os.getenv('TARGET_LABEL', 'node-role.kubernetes.io/hci-vm')
LABEL_VALUE = ""

# Only nodes of this architecture are ever labeled. Labeling a node of another
# architecture (e.g. an s390x compute/control node) would move it into the
# hci-vm MachineConfigPool and apply x86-VM kernel arguments → unbootable node.
TARGET_ARCH = os.getenv('TARGET_ARCH', 'amd64')

# Watch timeout: the runtime config is re-read from the ConfigMap after every
# watch cycle, so a pod that started before the ConfigMap existed self-corrects
# within this many seconds (same approach as node-auto-approver, OPS-06).
WATCH_TIMEOUT_SECONDS = 30


def _read_config_value(key: str) -> Optional[str]:
    """
    Read a key from the hci-node-manager-config ConfigMap via the Kubernetes API.
    Falls back to the env var of the same name (populated via envFrom when the
    ConfigMap already existed at pod creation). Returns None when neither is set
    — there is deliberately no hardcoded default, so the labeler never acts on
    a guessed value.
    """
    namespace = os.getenv('WATCH_NAMESPACE', os.getenv('POD_NAMESPACE', 'hci-node-manager'))
    try:
        cm = client.CoreV1Api().read_namespaced_config_map(NODE_MANAGER_CONFIGMAP, namespace)
        value = (cm.data or {}).get(key)
        if value:
            return value
        logger.warning(f"{key} key absent in ConfigMap {NODE_MANAGER_CONFIGMAP}")
    except ApiException as e:
        logger.warning(f"Could not read ConfigMap {NODE_MANAGER_CONFIGMAP} (HTTP {e.status} {e.reason})")
    value = os.getenv(key)
    if value:
        logger.warning(f"{key} env fallback: {value}")
    return value or None


def get_runtime_config() -> Tuple[Optional[str], Optional[str]]:
    """
    Return (target_network, node_name_pattern). Either may be None if not yet
    configured — in that case labeling is suspended until the next re-read.
    """
    return _read_config_value('TARGET_NETWORK'), _read_config_value('NODE_NAME_PATTERN')


def matches_name_pattern(node_name: str, name_pattern: str) -> bool:
    """Check node name is <pattern>-<N> or <pattern>-<N>.<domain>."""
    return bool(re.match(f"^{re.escape(name_pattern)}-\\d+(\\..+)?$", node_name))


def is_in_target_network(node_ip: str, target_network: str) -> bool:
    """Check if node IP is in the target network."""
    import ipaddress
    try:
        ip = ipaddress.ip_address(node_ip)
        network = ipaddress.ip_network(target_network)
        return ip in network
    except ValueError as e:
        logger.warning(f"Invalid IP address: {node_ip}: {e}")
        return False


def get_node_internal_ip(node) -> str:
    """Extract internal IP from node status."""
    if not node.status or not node.status.addresses:
        return None
    
    for addr in node.status.addresses:
        if addr.type == "InternalIP":
            return addr.address
    return None


def should_label_node(node, target_network: str, name_pattern: str) -> Tuple[bool, str]:
    """
    Determine if node should be labeled. ALL of the following must hold:
      • node does not already carry TARGET_LABEL
      • node name matches <name_pattern>-<N>[.<domain>]
      • node architecture is TARGET_ARCH
      • node InternalIP is within target_network
    Returns: (should_label, reason)
    """
    node_name = node.metadata.name
    labels = node.metadata.labels or {}

    # Check if already labeled
    if TARGET_LABEL in labels:
        return False, f"already has {TARGET_LABEL} label"

    # Guard 1: name must match the worker pool prefix
    if not matches_name_pattern(node_name, name_pattern):
        return False, f"name does not match pattern {name_pattern}-<N>"

    # Guard 2: architecture must match (protects s390x nodes from hci-vm MCP)
    arch = labels.get('kubernetes.io/arch')
    if arch != TARGET_ARCH:
        return False, f"arch {arch} is not {TARGET_ARCH}"

    # Get node IP
    node_ip = get_node_internal_ip(node)
    if not node_ip:
        return False, "no internal IP found"

    # Check if IP is in target network
    if not is_in_target_network(node_ip, target_network):
        return False, f"IP {node_ip} not in target network {target_network}"

    return True, f"IP {node_ip} is in target network {target_network}, arch {arch}, name matches {name_pattern}"


def label_node(v1: client.CoreV1Api, node_name: str) -> bool:
    """Label a node with the workers-hci role."""
    try:
        # Patch the node with the label
        body = {
            "metadata": {
                "labels": {
                    TARGET_LABEL: LABEL_VALUE
                }
            }
        }
        v1.patch_node(node_name, body)
        logger.info(f"✓ Successfully labeled node {node_name}")
        return True
    except ApiException as e:
        logger.error(f"✗ Failed to label node {node_name}: {e}")
        return False


def watch_nodes(v1: client.CoreV1Api):
    """Watch for nodes and label them.

    The runtime config (TARGET_NETWORK, NODE_NAME_PATTERN) is re-read from the
    ConfigMap before every watch cycle (~30 s) and after every 410 reconnect.
    A pod that started before the operator's first reconcile wrote the
    ConfigMap therefore self-corrects without a restart. Each new watch begins
    with ADDED events for all existing nodes, so previously skipped nodes are
    re-evaluated with the fresh config. While config is incomplete, labeling
    is suspended — nothing is labeled based on a guessed value.
    """
    w = watch.Watch()
    active_config = None

    while True:
        target_network, name_pattern = get_runtime_config()
        if not target_network or not name_pattern:
            logger.warning(
                "Labeling suspended: TARGET_NETWORK and NODE_NAME_PATTERN must both be "
                f"configured (network={target_network}, pattern={name_pattern}). "
                f"Retrying in {WATCH_TIMEOUT_SECONDS}s.")
            active_config = None
            time.sleep(WATCH_TIMEOUT_SECONDS)
            continue

        if (target_network, name_pattern) != active_config:
            logger.info(f"Labeling active: network={target_network}, "
                        f"name pattern={name_pattern}-<N>, arch={TARGET_ARCH}")
            active_config = (target_network, name_pattern)

        try:
            for event in w.stream(v1.list_node, timeout_seconds=WATCH_TIMEOUT_SECONDS):
                event_type = event['type']
                node = event['object']
                node_name = node.metadata.name

                # Only process ADDED and MODIFIED events
                if event_type not in ['ADDED', 'MODIFIED']:
                    continue

                should_label, reason = should_label_node(node, target_network, name_pattern)

                if should_label:
                    logger.info(f"Event {event_type}: Node {node_name}: {reason}")
                    label_node(v1, node_name)
                else:
                    logger.debug(f"Event {event_type}: Node {node_name}: {reason}")

        except ApiException as e:
            if e.status == 410:
                # Resource version too old, restart watch (config re-read at loop top)
                logger.warning("Watch expired (410), restarting...")
                continue
            else:
                logger.error(f"API error during watch: HTTP {e.status} {e.reason}")
                time.sleep(5)
        except Exception as e:
            logger.error(f"Unexpected error during watch: {e}")
            time.sleep(5)


def main():
    """Main entry point."""
    logger.info("Starting workers-hci node labeler...")
    logger.info(f"Target label: {TARGET_LABEL}")

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

    # Create API client
    v1 = client.CoreV1Api()
    logger.info(f"Target arch: {TARGET_ARCH}")

    # Watch nodes. Runtime config is (re-)read from the ConfigMap on every watch
    # cycle; every cycle starts with ADDED events for all existing nodes.
    watch_nodes(v1)


if __name__ == "__main__":
    main()

# Made with Bob
