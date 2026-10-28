#!/bin/bash
# Enable OpenShift Image Registry with NooBaa S3 Storage and prepare it for
# cross-cluster access via a bastion proxy.
#
# Tier A — run once per HCI cluster.  Idempotent: safe to re-run.
#
# What this script does:
#   1. Configures the registry to use ODF/NooBaa S3 storage
#   2. Enables the default external route
#   3. Sets disableRedirect=true so the registry proxies S3 uploads rather than
#      redirecting clients — required for cross-cluster push via bastion proxy
#
# Note: per-integration SA and token are created by setup-consumer-rbac.sh (Tier B),
# scoped to the per-main-cluster integration namespace on the HCI cluster.

set -e

# Configuration
REGISTRY_NAMESPACE="openshift-image-registry"
STORAGE_NAMESPACE="openshift-storage"
OBC_NAME="image-registry-storage"
STORAGE_CLASS="openshift-storage.noobaa.io"

echo "=========================================="
echo "Enable Image Registry with S3 Storage"
echo "=========================================="
echo "Registry Namespace: ${REGISTRY_NAMESPACE}"
echo "Storage Namespace: ${STORAGE_NAMESPACE}"
echo "Storage Class: ${STORAGE_CLASS}"
echo ""

# Check if NooBaa is available
echo "Checking NooBaa availability..."
if ! oc get noobaa -n ${STORAGE_NAMESPACE} &>/dev/null; then
    echo "✗ NooBaa not found in ${STORAGE_NAMESPACE} namespace"
    echo "  Please ensure ODF/NooBaa is installed"
    exit 1
fi

NOOBAA_STATUS=$(oc get noobaa noobaa -n ${STORAGE_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [ "${NOOBAA_STATUS}" != "Ready" ]; then
    echo "✗ NooBaa is not ready (status: ${NOOBAA_STATUS})"
    echo "  Please wait for NooBaa to be ready"
    exit 1
fi
echo "✓ NooBaa is ready"

# Check if storage class exists
if ! oc get storageclass ${STORAGE_CLASS} &>/dev/null; then
    echo "✗ Storage class ${STORAGE_CLASS} not found"
    echo "  Available storage classes:"
    oc get storageclass
    exit 1
fi
echo "✓ Storage class ${STORAGE_CLASS} exists"

# Create openshift-image-registry namespace if it doesn't exist
if ! oc get namespace ${REGISTRY_NAMESPACE} &>/dev/null; then
    echo ""
    echo "Creating ${REGISTRY_NAMESPACE} namespace..."
    oc create namespace ${REGISTRY_NAMESPACE}
    echo "✓ Namespace created"
else
    echo "✓ Namespace ${REGISTRY_NAMESPACE} exists"
fi

# Check if OBC already exists
if oc get obc ${OBC_NAME} -n ${REGISTRY_NAMESPACE} &>/dev/null; then
    echo ""
    echo "⚠ ObjectBucketClaim ${OBC_NAME} already exists"
    echo "  Checking status..."
    OBC_STATUS=$(oc get obc ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.status.phase}')
    if [ "${OBC_STATUS}" != "Bound" ]; then
        echo "✗ OBC is not bound (status: ${OBC_STATUS})"
        echo "  Please check OBC status: oc get obc ${OBC_NAME} -n ${REGISTRY_NAMESPACE}"
        exit 1
    fi
    echo "✓ OBC is bound"
else
    # Create ObjectBucketClaim
    echo ""
    echo "Creating ObjectBucketClaim for image registry..."
    cat <<EOF | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${REGISTRY_NAMESPACE}
spec:
  generateBucketName: image-registry
  storageClassName: ${STORAGE_CLASS}
EOF
    
    echo "Waiting for ObjectBucketClaim to be bound..."
    for i in {1..30}; do
        OBC_STATUS=$(oc get obc ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        if [ "${OBC_STATUS}" = "Bound" ]; then
            echo "✓ ObjectBucketClaim is bound"
            break
        fi
        echo "  Waiting... (${i}/30) Status: ${OBC_STATUS}"
        sleep 2
    done
    
    if [ "${OBC_STATUS}" != "Bound" ]; then
        echo "✗ ObjectBucketClaim did not become bound in time"
        echo "  Check status: oc get obc ${OBC_NAME} -n ${REGISTRY_NAMESPACE}"
        exit 1
    fi
fi

# Get bucket details from OBC
echo ""
echo "Getting S3 bucket details..."
BUCKET_NAME=$(oc get cm ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get cm ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.data.BUCKET_HOST}')

if [ -z "${BUCKET_NAME}" ] || [ -z "${BUCKET_HOST}" ]; then
    echo "✗ Failed to get bucket details from ConfigMap"
    echo "  Check ConfigMap: oc get cm ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o yaml"
    exit 1
fi

echo "✓ Bucket Name: ${BUCKET_NAME}"
echo "✓ Bucket Host: ${BUCKET_HOST}"

# Get credentials from OBC secret
echo ""
echo "Getting S3 credentials..."
ACCESS_KEY=$(oc get secret ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

if [ -z "${ACCESS_KEY}" ] || [ -z "${SECRET_KEY}" ]; then
    echo "✗ Failed to get credentials from Secret"
    echo "  Check Secret: oc get secret ${OBC_NAME} -n ${REGISTRY_NAMESPACE} -o yaml"
    exit 1
fi
echo "✓ Credentials retrieved"

# Create registry credentials secret
echo ""
echo "Creating image registry credentials secret..."
oc create secret generic image-registry-private-configuration-user \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="${ACCESS_KEY}" \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="${SECRET_KEY}" \
  --namespace ${REGISTRY_NAMESPACE} \
  --dry-run=client -o yaml | oc apply -f -
echo "✓ Credentials secret created"

# Configure image registry with HTTP (internal S3 service)
echo ""
echo "Configuring image registry to use S3 storage (HTTP for internal connection)..."
echo "Note: Using HTTP for internal S3 connection (secure within cluster)"
echo "      External access via route still uses HTTPS"
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  --patch "{
    \"spec\": {
      \"managementState\": \"Managed\",
      \"replicas\": 2,
      \"storage\": {
        \"s3\": {
          \"bucket\": \"${BUCKET_NAME}\",
          \"region\": \"us-east-1\",
          \"regionEndpoint\": \"http://s3.openshift-storage.svc\",
          \"virtualHostedStyle\": false,
          \"encrypt\": false
        }
      }
    }
  }"
echo "✓ Image registry configured"

# Remove any trustedCA reference if it exists
echo ""
echo "Ensuring no trustedCA reference exists..."
if oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.storage.s3.trustedCA}' 2>/dev/null | grep -q "name"; then
    echo "  Removing trustedCA reference..."
    oc patch configs.imageregistry.operator.openshift.io/cluster \
      --type json \
      --patch '[{"op": "remove", "path": "/spec/storage/s3/trustedCA"}]' 2>/dev/null || true
    echo "✓ trustedCA reference removed"
else
    echo "✓ No trustedCA reference found"
fi

# Enable default registry route and disable S3 redirects in one patch.
# disableRedirect=true is required for cross-cluster push via bastion proxy:
# without it the registry issues an S3 pre-signed redirect that the client
# cannot follow across the bastion boundary.
echo ""
echo "Enabling default route and disabling S3 redirects..."
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  --patch '{"spec":{"defaultRoute":true,"disableRedirect":true}}'
echo "✓ Default route enabled, S3 redirects disabled"

# Wait for default route to be created
echo ""
echo "Waiting for default route to be created..."
for i in {1..30}; do
    if oc get route default-route -n openshift-image-registry &>/dev/null; then
        echo "✓ Default route created"
        break
    fi
    echo "  Waiting... (${i}/30)"
    sleep 2
done

if ! oc get route default-route -n openshift-image-registry &>/dev/null; then
    echo "⚠ Default route not created yet, but registry should create it shortly"
fi

# Wait for registry to be ready
echo ""
echo "Waiting for image registry to be ready..."
for i in {1..60}; do
    AVAILABLE=$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [ "${AVAILABLE}" = "True" ]; then
        echo "✓ Image registry is available"
        break
    fi
    echo "  Waiting... (${i}/60) Status: ${AVAILABLE}"
    sleep 5
done

if [ "${AVAILABLE}" != "True" ]; then
    echo "⚠ Image registry did not become available in time"
    echo "  Check status: oc get configs.imageregistry.operator.openshift.io/cluster -o yaml"
    echo "  Check pods: oc get pods -n ${REGISTRY_NAMESPACE}"
else
    # Verify registry service
    echo ""
    echo "Verifying image registry service..."
    if oc get service image-registry -n ${REGISTRY_NAMESPACE} &>/dev/null; then
        echo "✓ Image registry service exists"
        
        # Get service details
        SERVICE_IP=$(oc get service image-registry -n ${REGISTRY_NAMESPACE} -o jsonpath='{.spec.clusterIP}')
        echo "  Service IP: ${SERVICE_IP}"
    else
        echo "⚠ Image registry service not found yet"
        echo "  It should be created shortly"
    fi
    
    # Check registry pods
    echo ""
    echo "Checking image registry pods..."
    oc get pods -n ${REGISTRY_NAMESPACE} -l docker-registry=default
fi

# ── Summary ───────────────────────────────────────────────────────────────────
DEFAULT_ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

echo ""
echo "=========================================="
echo "✓ Image Registry Configuration Complete!"
echo "=========================================="
echo ""
echo "  Internal:        image-registry.openshift-image-registry.svc:5000"
echo "  Default Route:   ${DEFAULT_ROUTE}"
echo "  S3 Bucket:       ${BUCKET_NAME}"
echo "  disableRedirect: true (required for bastion-proxy cross-cluster push)"
echo ""
echo "Verify:"
echo "  oc get pods -n ${REGISTRY_NAMESPACE}"
echo "  curl -k https://${DEFAULT_ROUTE}/v2/   # expect: UNAUTHORIZED"
echo ""
echo "Next step (Tier B): run setup-consumer-rbac.sh for each main cluster"
echo "  that will connect — it creates the per-integration registry SA and"
echo "  token in the integration namespace on this HCI cluster."
echo ""

# Made with Bob