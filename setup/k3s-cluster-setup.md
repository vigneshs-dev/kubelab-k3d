# K3s Multi-Node Setup Guide (Single Host via k3d)

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

If you already installed native `k3s` on this host, remove it first. A native K3s server and a k3d cluster both want host networking and API ports.

Typical cleanup commands for native K3s:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

## Build the cluster

From the project root:

```bash
cd /home/ubuntu/projects/kubelab
chmod +x scripts/setup-k3s-cluster.sh
./scripts/setup-k3s-cluster.sh --agents 2
```

What the script does:

1. Checks Docker, `kubectl`, `k3d`, disk, RAM, and CPU.
2. Refuses to overcommit the host unless you pass `--force`.
3. Creates a `k3d` cluster with:
   - `1` server
   - `2` agents
   - host port `80` mapped to cluster ingress
   - host port `443` mapped to cluster ingress
   - host port `6550` mapped to the Kubernetes API
4. Switches your `kubectl` context to `k3d-kubelab`.
5. Waits until all nodes are `Ready`.

## Deploy KubeLab

```bash
cp k8s/secrets.yaml.example k8s/secrets.yaml
# edit k8s/secrets.yaml
./scripts/deploy-all.sh
```

Access:

- Frontend: `http://<your-instance-public-ip>/`
- Grafana: `http://<your-instance-public-ip>/grafana/`

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
