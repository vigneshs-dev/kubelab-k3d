#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${1:-kubelab}"

if ! command -v k3d >/dev/null 2>&1; then
    echo "k3d is not installed." >&2
    exit 1
fi

echo "⚠️  This will delete the k3d cluster: ${CLUSTER_NAME}"
read -r -p "Continue? (y/N): " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

k3d cluster delete "$CLUSTER_NAME"
echo "✅ Deleted cluster: ${CLUSTER_NAME}"
