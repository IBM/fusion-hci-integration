# operator/hci-provisioner/Dockerfile
#
# Image for the hci-provisioner Ansible operator.
# Manages WorkerPoolProvisioning CRs — no node-manager sidecars.
#
# Base: registry.redhat.io/openshift4/ose-ansible-operator
# The base image already includes kubernetes.core and operator_sdk.util collections.
# Keep the tag in sync with operator/hci-consumer/Dockerfile.

FROM registry.redhat.io/openshift4/ose-ansible-operator:v4.17

# ── Install openssh-clients for ssh-keygen (used by ensure_provisioner_ssh_key) ─
USER root
RUN dnf install -y openssh-clients && dnf clean all
USER 1001

# ── Operator roles and watches ────────────────────────────────────────────────
COPY watches.yaml ${HOME}/watches.yaml
COPY roles/       ${HOME}/roles/

# ── Entrypoint — ansible-operator watch loop ─────────────────────────────────
ENTRYPOINT ["/usr/local/bin/ansible-operator", "run", "--watches-file=./watches.yaml"]
