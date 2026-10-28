#!/usr/bin/env bash
# create-provider-credentials.sh
#
# DEPRECATED — superseded by operator/setup-provider-credentials.sh
#
# This script has been replaced by the unified credential setup script that
# creates both the consumer and provisioner credentials in one step.
#
# Please use:
#   ../setup-provider-credentials.sh               # both credentials
#   ../setup-provider-credentials.sh --consumer    # consumer only (equivalent to this script)
#
# This file is kept to avoid breaking any existing documentation references.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SCRIPT="${SCRIPT_DIR}/../setup-provider-credentials.sh"

if [[ ! -f "${NEW_SCRIPT}" ]]; then
  echo "Error: ${NEW_SCRIPT} not found."
  exit 1
fi

echo "⚠ create-provider-credentials.sh is deprecated."
echo "  Forwarding to: setup-provider-credentials.sh --consumer"
echo ""

exec "${NEW_SCRIPT}" --consumer "$@"
