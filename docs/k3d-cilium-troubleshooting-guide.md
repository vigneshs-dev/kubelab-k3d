# K3d + Cilium Troubleshooting Guide

This document captures the main problems we hit while moving KubeLab to a single-host `k3d` cluster with `Cilium`, plus the fixes that made the setup stable.

Use it as a practical runbook, not just a postmortem.

## 1. Frontend was not reachable outside the instance

### Symptom

- Pods were `Running`
- Services existed
- Port-forward worked or NodePort worked locally
- `http://<public-ip>/` did not open from a remote browser

### Root cause

There were two different causes at different stages:

1. OCI networking was not allowing inbound web traffic.
2. Later, after moving to `Cilium`, the public `k3d` listener was forwarding to the wrong internal ports.

### How we proved it

- Verified the app locally on the instance with `curl`.
- Compared `nginx-demo` behavior against KubeLab behavior.
- Checked OCI security rules.
- Inspected the `k3d-kubelab-serverlb` container port publishing.
- Confirmed the cluster was healthy with:

```bash
kubectl get pods -A
kubectl get ingress -A -o wide
kubectl get svc -A -o wide
docker inspect k3d-kubelab-serverlb
```

### Final fix

- Opened inbound `80/443` in OCI.
- Exposed the frontend through ingress instead of relying only on port-forward.
- For the Cilium-based cluster, mapped host `80/443` to stable `cilium-ingress` node ports behind the `k3d` load balancer.

### Lasting repo change

- `scripts/setup-k3s-cluster.sh` now pins Cilium ingress node ports and maps host `80/443` to them.
- `scripts/deploy-all.sh` now runs ingress curl probes after deployment.

## 2. Private IP worked, public IP did not

### Symptom

- `http://10.x.x.x/` worked from inside the environment
- `http://140.245.196.14/` did not work from outside

### Root cause

The cluster and manifests were fine. External access was blocked by OCI networking before the ingress path even reached Kubernetes.

### How we proved it

- Curl from the instance itself succeeded.
- Remote access did not.
- Another app on the same machine became reachable once the OCI rules were opened.

### Fix

- Add OCI ingress rules for at least:
  - TCP `80`
  - TCP `443` if HTTPS is used later

### Lesson

If an app works on the host but not from the internet, validate the network edge before changing Kubernetes manifests.

## 3. Port-forward confusion on the frontend

### Symptom

- `kubectl port-forward -n kubelab svc/frontend 8080:80` was running
- Browser still could not load the UI

### Root cause

Port-forward is only reliable if:

- the command stays open
- the browser is on the same machine
- the selected local port is actually free

It was also the wrong tool for the final goal, because the real requirement was public access.

### Fix

- Switched the main access path to ingress on the instance public IP.
- Kept port-forward as a fallback and documented alternate host bindings.

### Lesson

Use port-forward for debugging. Use ingress or a load balancer for stable access.

## 4. Moving from Traefik assumptions to Cilium ingress

### Symptom

- Existing ingress manifests were created during the Traefik-based phase.
- After enabling Cilium ingress, traffic stopped behaving like before.

### Root cause

The setup moved from a Traefik-centric ingress path to `Cilium` ingress, but parts of the repo still assumed the old path.

### Fix

- Changed ingress manifests to use `ingressClassName: cilium`
- Added `Hubble UI` ingress
- Updated security rules so traffic from the Cilium ingress path could reach app workloads

### Files

- `k8s/base/frontend-ingress.yaml`
- `k8s/observability/grafana-ingress.yaml`
- `k8s/observability/hubble-ui-ingress.yaml`
- `k8s/security/network-policies.yaml`
- `k8s/security/cilium-ingress-policies.yaml`

### Lesson

Changing the ingress controller is not only an ingress YAML change. It also affects service exposure, policy, and observability assumptions.

## 5. Cilium worked, but the website still returned an empty reply

### Symptom

- All pods were healthy
- `Cilium` and `Hubble` were healthy
- Ingress objects existed
- `curl http://<public-ip>/` returned `Empty reply from server`

### Root cause

The `k3d` public load balancer was forwarding host `80` to internal node port `8080`, but in this cluster the working public path was actually the `cilium-ingress` service node port, not node `:8080`.

The important detail was this:

- Cilium Envoy config existed
- But `docker exec k3d-kubelab-serverlb curl http://<node>:8080/` failed
- `docker exec k3d-kubelab-serverlb curl http://<node>:31136/` succeeded

### How we proved it

```bash
kubectl get svc -n kube-system cilium-ingress -o wide
docker exec k3d-kubelab-serverlb curl -I http://k3d-kubelab-server-0:31136/
docker exec k3d-kubelab-serverlb curl -I http://k3d-kubelab-server-0:8080/
kubectl get ciliumenvoyconfig -A -o yaml
```

### Final fix

- Patched the live `k3d-kubelab-serverlb` Nginx config to point at the actual Cilium ingress node ports
- Then made the fix permanent by pinning stable node ports in the repo:
  - HTTP `32080`
  - HTTPS `32443`

### Lesson

Do not assume the shared Cilium ingress listener is directly exposed the same way every time in `k3d`. Validate the real reachable path with curls from the `serverlb` container.

## 6. Cilium ingress node ports were dynamic after each rebuild

### Symptom

- A manual fix worked once
- Recreating the cluster broke public access again

### Root cause

The `cilium-ingress` service was getting auto-assigned node ports on each cluster creation, but the `k3d` public listener expected stable targets.

### Fix

- Pin `cilium-ingress` node ports after installing Cilium:
  - `32080`
  - `32443`
- Map host `80/443` to those fixed ports in `k3d`

### Lesson

If a bootstrap depends on a service node port, make that node port explicit. Dynamic node ports and static upstreams do not mix.

## 7. kube-proxy replacement required observability updates

### Symptom

- Core app worked
- But observability needed adjustment after enabling `Cilium` with kube-proxy replacement

### Root cause

The dataplane changed. Metrics and traffic visibility shifted from the old assumptions to `Cilium` and `Hubble`.

### Fix

- Added Cilium and Hubble scrape targets in Prometheus
- Allowed Prometheus egress to Cilium/Hubble metrics ports
- Kept Grafana dashboards and Prometheus working with the new network path

### Files

- `k8s/observability/prometheus.yaml`
- `k8s/security/network-policies.yaml`
- `setup/cilium-values.yaml`

### Lesson

When you replace kube-proxy, revisit:

- ingress path
- service exposure
- policy path
- metrics endpoints

Do not treat CNI replacement as a networking-only change.

## 8. kube-state-metrics caused noise during the migration

### Symptom

- Observability stack created issues while the rest of the app was being stabilized

### Root cause

`kube-state-metrics` was not the main public-access problem, but it increased noise while troubleshooting because it sits in the monitoring path and can make the stack look partially unhealthy.

### Fix

- Keep it in the stack, but troubleshoot access independently from observability add-ons.
- Verify frontend reachability first, then verify Grafana, then deeper metrics paths.

### Lesson

Split problems by layer:

1. external reachability
2. ingress routing
3. app health
4. metrics/monitoring

If you debug all four at once, you lose time.

## 9. Hubble UI needed its own public path

### Symptom

- Frontend and Grafana had public paths
- Hubble UI was running but not externally exposed

### Fix

- Added a dedicated ingress at `/hubble/`

### Files

- `k8s/observability/hubble-ui-ingress.yaml`

### Lesson

If a tool is part of the operator workflow, expose it intentionally and test it like any other app path.

## 10. The deployment script needed active validation, not just apply output

### Symptom

- Manifests applied cleanly
- Pods became `Running`
- But the user still could not use the app from outside

### Root cause

`kubectl apply` success does not prove that ingress is reachable.

### Fix

Added curl probes in `scripts/deploy-all.sh` for:

- `/`
- `/grafana/`
- `/hubble/`

### Lesson

Every deploy script should validate the user-facing path, not just Kubernetes object creation.

## Recommended troubleshooting order for future issues

When public access breaks again, use this order:

1. Check OCI or cloud firewall rules.
2. Check host port publishing on the `k3d` load balancer.
3. Check `cilium-ingress` service ports and node ports.
4. Curl from the `k3d-kubelab-serverlb` container to the node ports.
5. Check ingress objects and Cilium Envoy config.
6. Check backend service and pod health.
7. Check Prometheus, Grafana, Hubble only after traffic works.

## Commands worth remembering

```bash
kubectl get pods -A
kubectl get svc -A -o wide
kubectl get ingress -A -o wide
kubectl get ciliumenvoyconfig -A -o yaml
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=200
docker inspect k3d-kubelab-serverlb
docker exec k3d-kubelab-serverlb cat /etc/nginx/nginx.conf
docker exec k3d-kubelab-serverlb curl -I http://k3d-kubelab-server-0:32080/
curl -I http://<public-ip>/
curl -I http://<public-ip>/grafana/
curl -I http://<public-ip>/hubble/
```

## Final stable design

The stable shape for this repo is now:

- `k3d`
- `1` control plane
- `2` workers
- `Cilium` CNI
- `kubeProxyReplacement: true`
- `Cilium` ingress
- `Hubble UI` exposed at `/hubble/`
- `Grafana` exposed at `/grafana/`
- frontend exposed at `/`
- host `80/443` forwarded by `k3d` to fixed `cilium-ingress` node ports

That combination is what finally removed the repeated ingress regressions.
