# K3s Multi-Node Setup Guide (Single Host via k3d + Cilium)

This project can run on K3s with `1 control-plane + 2 worker nodes` on a single machine by using `k3d`. `k3d` runs real K3s nodes inside Docker containers, which is the practical option when you have one OCI instance instead of three separate machines.

## Why 2 workers is the right target here

On your current host:

- `2 vCPU`
- `11 GiB RAM`
- `38 GiB` free disk

That is enough for:

- `1` K3s server node
- `2` K3s worker nodes
- KubeLab
- one extra small project in another namespace

It is not a good host for `3+` worker nodes. More nodes on the same `2 vCPU` box only increase scheduling overhead and make the cluster slower without adding real capacity.

## Prerequisites

Install:

- Docker
- `kubectl`
- `k3d`
- `helm`

If you already installed native `k3s` on this host, remove it first. A native K3s server and a k3d cluster both want host networking and API ports.

Typical cleanup commands for native K3s:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

## What this setup uses

- `k3d` to run a multi-node K3s cluster on one machine
- `Cilium` as the CNI
- `Cilium` kube-proxy replacement
- `Cilium` ingress instead of Traefik
- `Hubble` metrics so Prometheus can scrape network-layer data

## Build the cluster

From the project root:

```bash
cd /home/ubuntu/projects/kubelab
chmod +x scripts/setup-k3s-cluster.sh
./scripts/setup-k3s-cluster.sh --agents 2
```

What the script does:

1. Checks Docker, `kubectl`, `k3d`, `helm`, disk, RAM, and CPU.
2. Refuses to overcommit the host unless you pass `--force`.
3. Creates a `k3d` cluster with:
   - `1` server
   - `2` agents
   - k3s `flannel`, `traefik`, `servicelb`, `network-policy`, and `kube-proxy` disabled
   - host port `80` mapped to the fixed Cilium ingress node port `32080` through the k3d load balancer
   - host port `443` mapped to the fixed Cilium ingress node port `32443` through the k3d load balancer
   - host port `6550` mapped to the Kubernetes API
4. Installs Cilium with kube-proxy replacement and pins the `cilium-ingress` service to stable node ports so k3d can expose it reliably on host `80/443`.
5. Enables Hubble metrics and Prometheus endpoints for Cilium components.
6. Switches your `kubectl` context to `k3d-kubelab`.
7. Waits until all nodes are `Ready`.

## Deploy KubeLab

```bash
cp k8s/secrets.yaml.example k8s/secrets.yaml
# edit k8s/secrets.yaml
./scripts/deploy-all.sh
```

Access:

- Frontend: `http://<your-instance-public-ip>/`
- Grafana: `http://<your-instance-public-ip>/grafana/`
- Hubble UI: `http://<your-instance-public-ip>/hubble/`

## Observability changes with Cilium

Because kube-proxy is replaced, network visibility now comes from Cilium and Hubble rather than the default K3s dataplane.

The project is updated so that:

- frontend and Grafana use the `cilium` ingress class
- Hubble UI is enabled and served under `/hubble/`
- network policies allow the kube-system ingress path to reach frontend and Grafana
- Prometheus scrapes annotated Cilium and Hubble targets in `kube-system`
- Prometheus egress allows the Cilium/Hubble metrics ports `9962` through `9965`

For k3d specifically, Cilium ingress is exposed through the `cilium-ingress` service. This repo pins that service to node ports `32080` and `32443`, and k3d forwards host `80/443` to those ports. The outside world still uses normal ports `80` and `443`.

## Add another project

Use a separate namespace:

```bash
kubectl create namespace other-project
```

Deploy the second app into `other-project`, not `kubelab`.

Keep these constraints in mind:

- Prefer `1` replica per component unless you truly need more.
- Avoid large memory requests.
- Reuse the existing cluster ingress instead of exposing many NodePorts.

## Tear it down

```bash
chmod +x scripts/teardown-k3s-cluster.sh
./scripts/teardown-k3s-cluster.sh
```
