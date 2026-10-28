#!/usr/bin/env bash
# reset-steps.sh — reset HCIProvisioning step statuses back to Pending for re-testing
#
# Resets steps by NAME, not array index — safe regardless of step ordering.
# Also clears status fields that are maintained alongside steps (bootfilesVersion,
# sshKeySecret) when the relevant steps are reset.
#
# Usage:
#   ./reset-steps.sh                                   # reset ALL steps + phase
#   ./reset-steps.sh GatewayVM Ignition Bootfiles      # reset specific steps only
#   ./reset-steps.sh --cr <name> GatewayVM             # target a specific CR
#   ./reset-steps.sh --namespace <ns> GatewayVM        # target a specific namespace
#
# Examples:
#   ./reset-steps.sh GatewayVM Ignition Bootfiles      # re-test full gateway bootstrap
#   ./reset-steps.sh Ignition                          # re-test ignition distribution only
#   ./reset-steps.sh Bootfiles                         # re-trigger bootfiles download

set -euo pipefail

CR_NAMESPACE="hci-node-manager"
CR_NAME=""
STEPS_TO_RESET=()

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr)
      CR_NAME="$2"
      shift 2
      ;;
    --namespace)
      CR_NAMESPACE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      STEPS_TO_RESET+=("$1")
      shift
      ;;
  esac
done

# ── Resolve CR name ───────────────────────────────────────────────────────────

if [[ -z "${CR_NAME}" ]]; then
  CR_NAME=$(oc get hciprovisioning -n "${CR_NAMESPACE}" -o name 2>/dev/null \
    | head -1 | cut -d/ -f2)
  if [[ -z "${CR_NAME}" ]]; then
    echo "ERROR: No HCIProvisioning CR found in namespace '${CR_NAMESPACE}'."
    echo "       Use --cr <name> to specify one explicitly."
    exit 1
  fi
  echo "==> Auto-detected CR: ${CR_NAME}"
fi

echo "==> Target: ${CR_NAMESPACE}/${CR_NAME}"

# ── Read current steps ────────────────────────────────────────────────────────

CURRENT_STEPS=$(oc get hciprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" \
  -o jsonpath='{range .status.steps[*]}{.name}{"\t"}{.status}{"\n"}{end}')

echo ""
echo "Current step statuses:"
echo "${CURRENT_STEPS}" | column -t
echo ""

# ── Build reset set ───────────────────────────────────────────────────────────

if [[ ${#STEPS_TO_RESET[@]} -eq 0 ]]; then
  # No args — reset all steps
  mapfile -t STEPS_TO_RESET < <(echo "${CURRENT_STEPS}" | awk '{print $1}')
  echo "==> Resetting ALL steps: ${STEPS_TO_RESET[*]}"
else
  echo "==> Resetting steps: ${STEPS_TO_RESET[*]}"
fi

# ── Build JSON patch via Python ───────────────────────────────────────────────
# Read the full current steps array, reset matching entries, write back as a
# single strategic merge patch so the entire steps array is replaced atomically.

PATCH=$(oc get hciprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" -o json | \
python3 -c "
import sys, json

data = json.load(sys.stdin)
steps_to_reset = set(sys.argv[1:])
steps = data.get('status', {}).get('steps', [])

for step in steps:
    if step['name'] in steps_to_reset:
        step['status'] = 'Pending'
        step.pop('message', None)
        step.pop('lastTransitionTime', None)
        step.pop('jobName', None)

print(json.dumps({'status': {'steps': steps}}))
" "${STEPS_TO_RESET[@]}")

# ── Patch step statuses ───────────────────────────────────────────────────────

oc patch hciprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" \
  --type=merge --subresource=status \
  -p "${PATCH}"

echo "==> Steps patched."

# ── Reset associated status fields ───────────────────────────────────────────

PHASE_PATCH="{}"

# If GatewayVM is being reset, also clear sshKeySecret so the keypair is
# re-evaluated (the Secret itself is NOT deleted — only the status pointer).
if printf '%s\n' "${STEPS_TO_RESET[@]}" | grep -q "^GatewayVM$"; then
  echo "==> GatewayVM reset: clearing status.sshKeySecret pointer (Secret retained)."
  PHASE_PATCH=$(echo "${PHASE_PATCH}" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['sshKeySecret'] = ''
print(json.dumps(p))")
fi

# If Bootfiles is being reset, clear bootfilesVersion so the consumer gate
# blocks scale-up until the new download completes.
if printf '%s\n' "${STEPS_TO_RESET[@]}" | grep -q "^Bootfiles$"; then
  echo "==> Bootfiles reset: clearing status.bootfilesVersion."
  PHASE_PATCH=$(echo "${PHASE_PATCH}" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['bootfilesVersion'] = ''
print(json.dumps(p))")
fi

# Reset phase to InProgress so the terminal-phase gate does not block reconcile.
PHASE_PATCH=$(echo "${PHASE_PATCH}" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['phase'] = 'InProgress'
print(json.dumps({'status': p}))")

oc patch hciprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" \
  --type=merge --subresource=status \
  -p "${PHASE_PATCH}"

echo "==> Phase reset to InProgress."

# ── Show final state ──────────────────────────────────────────────────────────

echo ""
echo "Final step statuses:"
oc get hciprovisioning "${CR_NAME}" -n "${CR_NAMESPACE}" \
  -o jsonpath='{range .status.steps[*]}{.name}{"\t"}{.status}{"\n"}{end}' | column -t
echo ""
echo "==> Done. Trigger a reconcile by touching the CR or waiting for the next resync."
echo "    To force immediate reconcile with run-local.sh:"
echo "    ./run-local.sh --cr ${CR_NAME}"
