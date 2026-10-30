# operator/hci-consumer/Dockerfile
#
# Image for the hci-consumer Ansible operator.
# Bundles the node-auto-approver and node-labeler scripts so the consumer
# Deployment can run all three processes as sidecars in a single pod.
#
# Base: registry.redhat.io/openshift4/ose-ansible-operator
# The base image already includes kubernetes.core and operator_sdk.util collections.
# Pin the tag to match your OCP cluster version.

FROM registry.redhat.io/openshift4/ose-ansible-operator:v4.17

# ── System dependencies ───────────────────────────────────────────────────────
# openssh-clients provides /usr/bin/ssh, required by BS-06b to write
# desired-version.txt to the gateway VM after a cluster version upgrade.
USER root
RUN dnf install -y openssh-clients && dnf clean all
USER 1001

# ── Operator roles and watches ────────────────────────────────────────────────
COPY watches.yaml ${HOME}/watches.yaml
COPY roles/       ${HOME}/roles/

# ── Node-manager sidecar scripts ─────────────────────────────────────────────
# The Deployment spec runs these as separate containers:
#   command: ["python3", "/opt/node-manager/node-auto-approver.py"]
#   command: ["python3", "/opt/node-manager/node-labeler.py"]
COPY node-manager/node-auto-approver.py /opt/node-manager/node-auto-approver.py
COPY node-manager/node-labeler.py       /opt/node-manager/node-labeler.py

# ── Entrypoint — ansible-operator watch loop ─────────────────────────────────
ENTRYPOINT ["/usr/local/bin/ansible-operator", "run", "--watches-file=./watches.yaml"]
