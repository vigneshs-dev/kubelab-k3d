#!/usr/bin/env bash

# Build a single-host multi-node K3s lab using k3d.
# Why k3d: plain K3s needs separate machines or VMs for extra nodes.
# On one OCI instance, k3d is the practical way to run 1 server + N agents,
# because each node runs as a Docker container but still uses real K3s.

set -euo pipefail

CLUSTER_NAME="kubelab"
SERVER_COUNT=1
AGENT_COUNT="auto"
API_PORT=6550
HTTP_PORT=80
HTTPS_PORT=443
DELETE_EXISTING=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: ./scripts/setup-k3s-cluster.sh [options]

Options:
  --name <name>           Cluster name. Default: kubelab
  --agents <count>        Worker node count. Default: auto
  --api-port <port>       Host port for Kubernetes API. Default: 6550
  --http-port <port>      Host port for ingress HTTP. Default: 80
  --https-port <port>     Host port for ingress HTTPS. Default: 443
  --delete-existing       Delete an existing k3d cluster with the same name first
  --force                 Allow a worker count above the host recommendation
  -h, --help              Show this help

Examples:
  ./scripts/setup-k3s-cluster.sh
  ./scripts/setup-k3s-cluster.sh --agents 2 --delete-existing
  ./scripts/setup-k3s-cluster.sh --name lab --http-port 8080 --https-port 8443
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --agents)
            AGENT_COUNT="$2"
            shift 2
            ;;
        --api-port)
            API_PORT="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --https-port)
            HTTPS_PORT="$2"
            shift 2
            ;;
        --delete-existing)
            DELETE_EXISTING=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        return 1
    fi
}

port_in_use() {
    local port="$1"
    ss -ltn "( sport = :$port )" 2>/dev/null | awk 'NR>1 {print $4}' | grep -q .
}

get_mem_gib() {
    awk '/MemTotal/ {printf "%.0f\n", $2/1024/1024}' /proc/meminfo
}

get_disk_gib() {
    df -BG / | awk 'NR==2 {gsub(/G/, "", $4); print $4}'
}

recommend_agents() {
    local cpus mem_gib disk_gib
    cpus="$(nproc)"
    mem_gib="$(get_mem_gib)"
    disk_gib="$(get_disk_gib)"

    if (( cpus >= 4 && mem_gib >= 16 && disk_gib >= 50 )); then
        echo 3
    elif (( cpus >= 2 && mem_gib >= 10 && disk_gib >= 30 )); then
        echo 2
    elif (( cpus >= 2 && mem_gib >= 8 && disk_gib >= 20 )); then
        echo 1
    else
        echo 0
    fi
}

echo "🚀 K3s Multi-Node Lab Setup"
echo "==========================="
echo ""

require_command docker
require_command kubectl
require_command k3d
require_command ss

if ! docker info >/dev/null 2>&1; then
    echo "Docker is installed but not reachable. Start Docker first." >&2
    exit 1
fi

CPU_COUNT="$(nproc)"
MEM_GIB="$(get_mem_gib)"
DISK_GIB="$(get_disk_gib)"
RECOMMENDED_AGENTS="$(recommend_agents)"

echo "Host capacity:"
echo "  CPU: ${CPU_COUNT} vCPU"
echo "  RAM: ${MEM_GIB} GiB"
echo "  Free disk: ${DISK_GIB} GiB"
echo ""

if [[ "$AGENT_COUNT" == "auto" ]]; then
    AGENT_COUNT="$RECOMMENDED_AGENTS"
fi

if ! [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
    echo "--agents must be an integer or 'auto'." >&2
    exit 1
fi

if (( RECOMMENDED_AGENTS == 0 )); then
    echo "This host is too small for a useful multi-node K3s lab." >&2
    echo "Minimum practical target: 2 vCPU, 8 GiB RAM, 20 GiB free disk." >&2
    exit 1
fi

if (( AGENT_COUNT > RECOMMENDED_AGENTS )) && (( FORCE == 0 )); then
    echo "Requested ${AGENT_COUNT} workers, but this host only recommends ${RECOMMENDED_AGENTS}." >&2
    echo "Use --force if you want to overcommit intentionally." >&2
    exit 1
fi

if (( AGENT_COUNT > 2 )) && (( CPU_COUNT <= 2 )) && (( FORCE == 0 )); then
    echo "More than 2 workers on a 2 vCPU host is not a sensible default." >&2
    exit 1
fi

echo "Cluster shape:"
echo "  Control planes: ${SERVER_COUNT}"
echo "  Workers: ${AGENT_COUNT}"
echo ""

if command -v k3s >/dev/null 2>&1 || [[ -x /usr/local/bin/k3s ]] || [[ -f /etc/systemd/system/k3s.service ]]; then
    echo "Native k3s appears to be installed on this machine." >&2
    echo "Stop or uninstall it before creating a k3d-based multi-node cluster." >&2
    echo "Typical cleanup commands:" >&2
    echo "  sudo /usr/local/bin/k3s-uninstall.sh" >&2
    echo "  sudo /usr/local/bin/k3s-agent-uninstall.sh" >&2
    exit 1
fi

if k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
    if (( DELETE_EXISTING == 1 )); then
        echo "Deleting existing cluster: ${CLUSTER_NAME}"
        k3d cluster delete "$CLUSTER_NAME"
    else
        echo "Cluster '${CLUSTER_NAME}' already exists. Use --delete-existing to replace it." >&2
        exit 1
    fi
fi

for port in "$API_PORT" "$HTTP_PORT" "$HTTPS_PORT"; do
    if port_in_use "$port"; then
        echo "Port ${port} is already in use. Pick a different port or stop the conflicting service." >&2
        exit 1
    fi
done

echo "Creating cluster..."
k3d cluster create "$CLUSTER_NAME" \
    --servers "$SERVER_COUNT" \
    --agents "$AGENT_COUNT" \
    --api-port "$API_PORT" \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${HTTPS_PORT}:443@loadbalancer" \
    --wait

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null

echo ""
echo "✅ Cluster ready"
echo ""
kubectl get nodes -o wide
echo ""

PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo "Next steps:"
echo "  1. Verify context: kubectl config current-context"
echo "  2. Create your secrets file if needed: cp k8s/secrets.yaml.example k8s/secrets.yaml"
echo "  3. Deploy KubeLab: ./scripts/deploy-all.sh"
echo "  4. Frontend:  http://${PUBLIC_IP:-<public-ip>}/"
echo "  5. Grafana:   http://${PUBLIC_IP:-<public-ip>}/grafana/"
echo "  6. Another project: deploy it into a separate namespace"
echo ""
echo "Notes:"
echo "  - On this host, 2 workers is the recommended maximum."
echo "  - If you add another project, prefer a new namespace and modest resource requests."
echo "  - Prometheus/Grafana plus another app can still fit, but avoid high replica counts on 2 vCPU."
