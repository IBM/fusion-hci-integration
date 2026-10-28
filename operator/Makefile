# operator/Makefile
#
# Targets for building and deploying both HCI integration operators.
# Follows operator-sdk Makefile conventions.
#
# Quick start:
#   1. Edit build/config.env     — set your registry coordinates
#   2. make apply-buildconfigs   — create BuildConfig + ImageStream objects in-cluster
#   3. make build                — build both images in-cluster (oc start-build)
#   4. make install              — apply CRDs to the cluster
#   5. make deploy               — deploy both operators (kustomize overlay)
#
# All targets that talk to the cluster require: oc login

# ── Configuration ─────────────────────────────────────────────────────────────
# Load build/config.env as Makefile variables (lines starting with # are ignored).
# Any variable already set in the environment takes precedence.
-include build/config.env

# Full image references used in the active overlay.
# Default: internal registry path includes namespace as path segment.
# For external registries where REGISTRY_PULL already contains the project path,
# set CONSUMER_IMG and PROVISIONER_IMG directly in config.env or on the command line.
CONSUMER_IMG    ?= $(REGISTRY_PULL)/$(CONSUMER_IMAGE_NAME):$(IMAGE_TAG)
PROVISIONER_IMG ?= $(REGISTRY_PULL)/$(PROVISIONER_IMAGE_NAME):$(IMAGE_TAG)

# Kustomize overlay for BuildConfig apply (build/overlays/...)
# Auto-selects external-registry when REGISTRY_PUSH is set; can be overridden explicitly.
BUILD_OVERLAY ?= $(if $(REGISTRY_PUSH),build/overlays/external-registry,build/overlays/internal-registry)

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: help \
        apply-buildconfigs \
        build build-consumer build-provisioner \
        install uninstall \
        deploy undeploy rollout \
        print-config

# ── help ──────────────────────────────────────────────────────────────────────
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-24s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ── apply-buildconfigs ────────────────────────────────────────────────────────
apply-buildconfigs: ## Create/update BuildConfigs and ImageStreams in-cluster (BUILD_OVERLAY=build/overlays/...)
	@echo "==> Ensuring namespace $(OPERATOR_NAMESPACE) exists"
	oc get namespace $(OPERATOR_NAMESPACE) 2>/dev/null || oc create namespace $(OPERATOR_NAMESPACE)
	@if [ "$(BUILD_OVERLAY)" = "build/overlays/internal-registry" ]; then \
	  echo "==> Ensuring ImageStreams exist (internal-registry mode)"; \
	  oc get imagestream $(CONSUMER_IMAGE_NAME)    -n $(OPERATOR_NAMESPACE) 2>/dev/null \
	    || oc create imagestream $(CONSUMER_IMAGE_NAME)    -n $(OPERATOR_NAMESPACE); \
	  oc get imagestream $(PROVISIONER_IMAGE_NAME) -n $(OPERATOR_NAMESPACE) 2>/dev/null \
	    || oc create imagestream $(PROVISIONER_IMAGE_NAME) -n $(OPERATOR_NAMESPACE); \
	else \
	  echo "==> Generating output-patch.yaml for $(BUILD_OVERLAY)"; \
	  sed -e 's|REGISTRY_PUSH_PLACEHOLDER|$(REGISTRY_PUSH)|g' \
	      -e 's|IMAGE_NAME_PLACEHOLDER|$(CONSUMER_IMAGE_NAME)|g' \
	      -e 's|IMAGE_TAG_PLACEHOLDER|$(IMAGE_TAG)|g' \
	      -e 's|PUSH_SECRET_PLACEHOLDER|$(REGISTRY_SECRET_NAME)|g' \
	      build/overlays/external-registry/output-patch.yaml \
	    > /tmp/hci-consumer-output-patch.yaml; \
	  sed -e 's|REGISTRY_PUSH_PLACEHOLDER|$(REGISTRY_PUSH)|g' \
	      -e 's|IMAGE_NAME_PLACEHOLDER|$(PROVISIONER_IMAGE_NAME)|g' \
	      -e 's|IMAGE_TAG_PLACEHOLDER|$(IMAGE_TAG)|g' \
	      -e 's|PUSH_SECRET_PLACEHOLDER|$(REGISTRY_SECRET_NAME)|g' \
	      build/overlays/external-registry/output-patch.yaml \
	    > /tmp/hci-provisioner-output-patch.yaml; \
	  cp /tmp/hci-consumer-output-patch.yaml build/overlays/external-registry/output-patch-consumer.yaml; \
	  cp /tmp/hci-provisioner-output-patch.yaml build/overlays/external-registry/output-patch-provisioner.yaml; \
	fi
	@echo "==> Applying BuildConfigs via $(BUILD_OVERLAY)"
	oc apply -k $(BUILD_OVERLAY)

# ── build ─────────────────────────────────────────────────────────────────────
build: build-consumer build-provisioner ## Build both operator images in-cluster

build-consumer: ## Build hci-consumer operator image in-cluster
	@echo "==> Starting cluster build: hci-consumer-operator"
	oc start-build hci-consumer-operator \
	  --from-dir=hci-consumer \
	  --follow --wait \
	  -n $(OPERATOR_NAMESPACE)

build-provisioner: ## Build hci-provisioner operator image in-cluster
	@echo "==> Starting cluster build: hci-provisioner-operator"
	oc start-build hci-provisioner-operator \
	  --from-dir=hci-provisioner \
	  --follow --wait \
	  -n $(OPERATOR_NAMESPACE)

# ── install / uninstall CRDs ──────────────────────────────────────────────────
install: ## Install CRDs into the cluster
	oc apply -f hci-consumer/config/crd/workerpool.yaml
	oc apply -f hci-provisioner/config/crd/workerpoolprovisioning.yaml

uninstall: ## Remove CRDs from the cluster (warning: deletes all CRs)
	oc delete -f hci-consumer/config/crd/workerpool.yaml --ignore-not-found
	oc delete -f hci-provisioner/config/crd/workerpoolprovisioning.yaml --ignore-not-found

# ── deploy / undeploy ─────────────────────────────────────────────────────────
# make deploy writes deploy/overlays/active/kustomization.yaml (gitignored) and
# applies it — the template overlays in the repo are never modified.
deploy: ## Deploy both operators — generates active overlay from config.env, then oc apply -k
	@echo "==> Generating deploy/overlays/active/kustomization.yaml"
	@mkdir -p deploy/overlays/active
	@printf '%s\n' \
	  'apiVersion: kustomize.config.k8s.io/v1beta1' \
	  'kind: Kustomization' \
	  '' \
	  'namespace: $(OPERATOR_NAMESPACE)' \
	  '' \
	  'resources:' \
	  '  - ../../base' \
	  '' \
	  'images:' \
	  '  - name: hci-consumer-operator' \
	  '    newName: $(subst :$(IMAGE_TAG),,$(CONSUMER_IMG))' \
	  '    newTag: $(IMAGE_TAG)' \
	  '  - name: hci-provisioner-operator' \
	  '    newName: $(subst :$(IMAGE_TAG),,$(PROVISIONER_IMG))' \
	  '    newTag: $(IMAGE_TAG)' \
	  > deploy/overlays/active/kustomization.yaml
	@if [ -n "$(REGISTRY_SECRET_NAME)" ]; then \
	  echo "==> Adding imagePullSecrets patch for $(REGISTRY_SECRET_NAME)"; \
	  printf '%s\n' \
	    '' \
	    'patches:' \
	    '  - patch: |' \
	    '      - op: replace' \
	    '        path: /spec/template/spec/imagePullSecrets' \
	    '        value:' \
	    '          - name: $(REGISTRY_SECRET_NAME)' \
	    '    target:' \
	    '      kind: Deployment' \
	    >> deploy/overlays/active/kustomization.yaml; \
	fi
	@echo "==> Applying deploy/overlays/active"
	oc apply -k deploy/overlays/active

undeploy: ## Remove operator Deployments (does not remove CRDs or namespace)
	oc delete -k deploy/overlays/active --ignore-not-found

# make deploy alone does NOT restart pods when the rendered manifest is unchanged
# (e.g. rebuilt :latest image) — use this target after `make build` to pick up the
# new image. Set ROLLOUT_TIMEOUT to override the wait (default 300s).
ROLLOUT_TIMEOUT ?= 300s
rollout: ## Restart both operator Deployments (pulls rebuilt image) and wait for completion
	@echo "==> Restarting operator Deployments in $(OPERATOR_NAMESPACE)"
	oc rollout restart deployment/hci-consumer-operator deployment/hci-provisioner-operator \
	  -n $(OPERATOR_NAMESPACE)
	oc rollout status deployment/hci-consumer-operator    -n $(OPERATOR_NAMESPACE) --timeout=$(ROLLOUT_TIMEOUT)
	oc rollout status deployment/hci-provisioner-operator -n $(OPERATOR_NAMESPACE) --timeout=$(ROLLOUT_TIMEOUT)

# ── print-config ──────────────────────────────────────────────────────────────
print-config: ## Print resolved configuration values
	@echo "OPERATOR_NAMESPACE   = $(OPERATOR_NAMESPACE)"
	@echo "BUILD_OVERLAY        = $(BUILD_OVERLAY)"
	@echo "CONSUMER_IMG         = $(CONSUMER_IMG)"
	@echo "PROVISIONER_IMG      = $(PROVISIONER_IMG)"
