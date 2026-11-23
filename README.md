# MetalLB Static IP Demo on kind

This demo shows a Kubernetes `LoadBalancer` Service getting a **fixed, predictable external IP** from MetalLB, running on a local [kind](https://kind.sigs.k8s.io/) cluster.

| Item | Value |
|---|---|
| Cluster name | `metallb-demo` (1 control-plane + 2 workers) |
| MetalLB version | v0.14.9 (L2 mode) |
| IP pool | `172.18.255.200` – `172.18.255.250` |
| Static IP of the demo Service | `172.18.255.210` |
| App | `hashicorp/http-echo`, replies `Hello from MetalLB static IP` |

---

## Files

| File | Purpose |
|---|---|
| `kind-config.yaml` | kind cluster definition (3 nodes) |
| `metallb-pool.yaml` | `IPAddressPool` (range MetalLB may hand out) + `L2Advertisement` |
| `app-static-ip.yaml` | Deployment (2 replicas) + `LoadBalancer` Service pinned to `172.18.255.210` |
| `demo.sh` | Interactive, step-by-step script. It pauses before each step |

---

## Prerequisites

- Docker Desktop, running (`docker info` must succeed)
- `kind`, `kubectl` (`brew install kind kubectl`)
- Internet access (pulls the MetalLB manifest and container images)

---

## Work Instructions

### Option A: Scripted demo (recommended for presenting)

```bash
cd ~/metallb-demo
./demo.sh down    # optional: start from a clean slate
./demo.sh up      # full demo, press Enter to advance each step
./demo.sh test    # re-run only the access test + recreate check
./demo.sh down    # tear everything down
```

### Option B: Manual steps

**1. Create the cluster**
```bash
kind create cluster --config kind-config.yaml
kubectl get nodes
```

**2. Find the kind Docker network subnet**
```bash
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
# e.g. 172.18.0.0/16. The IP pool MUST sit inside this subnet
```

**3. Install MetalLB**
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait -n metallb-system --for=condition=ready pod -l app=metallb --timeout=180s
```

**4. Configure the IP pool and L2 advertisement**
```bash
kubectl apply -f metallb-pool.yaml
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

**5. Deploy the app and the static-IP Service**
```bash
kubectl apply -f app-static-ip.yaml
kubectl rollout status deploy/web
kubectl get svc web-static
# EXTERNAL-IP should show 172.18.255.210
```

Example output:
```text
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
web-static   LoadBalancer   10.96.219.219   172.18.255.210   80:31404/TCP   18m
```

The static IP comes from this annotation on the Service:
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 172.18.255.210
```

**6. Test access**
```bash
# From a client on the kind Docker network (always works)
docker run --rm --network kind curlimages/curl:8.10.1 -s http://172.18.255.210
```

Example output:
```text
Hello from MetalLB static IP
```
To reach it from your Mac, see [Accessing the IP from macOS](#accessing-the-ip-from-macos).

**7. Prove the IP is static**
```bash
kubectl delete svc web-static
kubectl apply -f app-static-ip.yaml
kubectl get svc web-static              # same 172.18.255.210
kubectl describe svc web-static | grep -A3 Events
```

Example output of the `describe` command:
```text
Events:
  Type    Reason        Age   From                Message
  ----    ------        ----  ----                -------
  Normal  IPAllocated   18m   metallb-controller  Assigned IP ["172.18.255.210"]
```

**8. Clean up**
```bash
docker rm -f metallb-proxy 2>/dev/null
kind delete cluster --name metallb-demo
```

---

## Accessing the IP from macOS

On macOS, `curl http://172.18.255.210` run directly from your terminal **times out**, even though the Service is healthy. See Caveat 1 below. There are two ways around this:

**Option 1: Local proxy (quick, no sudo)**
```bash
docker run -d --name metallb-proxy --network kind -p 8080:80 \
  alpine/socat tcp-listen:80,fork,reuseaddr tcp-connect:172.18.255.210:80
curl http://localhost:8080
```
Remove it with `docker rm -f metallb-proxy`.

**Option 2: Route the real IP to macOS (best for the demo, needs sudo)**
```bash
brew install chipmk/tap/docker-mac-net-connect
sudo brew services start chipmk/tap/docker-mac-net-connect
curl http://172.18.255.210
```
This sets up a small WireGuard tunnel from macOS into Docker's VM. Stop it with `sudo brew services stop chipmk/tap/docker-mac-net-connect`.

---

## Caveats

1. **macOS / Windows cannot reach the IP directly.** Docker Desktop runs containers inside a Linux VM, and the kind network (`172.18.0.0/16`) exists only inside that VM. The host has no route to it, so MetalLB IPs are reachable only from containers on the `kind` network unless you use a proxy or tunnel (see above). On a **Linux** host, `curl 172.18.255.210` works directly.

2. **The static IP must be inside a MetalLB pool.** If you request an IP outside every `IPAddressPool`, the Service stays at `EXTERNAL-IP <pending>`. Check `kubectl describe svc web-static` for the error event. (You can show this on purpose during the demo.)

3. **The pool must match the kind subnet.** The kind network subnet can differ between machines (e.g. `172.19.0.0/16` if `172.18` is taken). Always verify it with step 2 and edit `metallb-pool.yaml` and the Service annotation if needed.

4. **One IP per Service.** Two Services cannot claim the same IP unless both carry the same `metallb.io/allow-shared-ip` key *and* use non-conflicting ports. Otherwise the second one stays `<pending>`.

5. **Use the annotation, not `spec.loadBalancerIP`.** `spec.loadBalancerIP` is deprecated in Kubernetes; MetalLB still honours it, but `metallb.io/loadBalancerIPs` is the supported way.

6. **L2 mode is not true load balancing.** In L2 mode one node "owns" the IP (answers ARP) and all traffic enters through it before kube-proxy spreads it to pods. If that node fails, failover to another node takes a few seconds.

7. **The IP is static only while the pool exists.** It is reserved by the annotation, not by any external system. Deleting the pool, or the cluster, releases it. The kind cluster is local and disposable: restarting Docker Desktop can stop the nodes, and recreating the cluster starts from scratch.

8. **Docker must be running first.** If `kind` reports `failed to connect to the docker API`, start Docker Desktop (`open -a Docker`) and wait until `docker info` succeeds.

9. **`demo.sh` needs internet access.** It pulls the MetalLB manifest from GitHub and images from Docker Hub. For an offline demo, pre-pull the images or run `./demo.sh up` once beforehand.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `EXTERNAL-IP <pending>` | `kubectl get ipaddresspool -n metallb-system`; is the IP in range? `kubectl logs -n metallb-system deploy/controller` |
| IP assigned but no reply from the kind network | `kubectl get pods -l app=web` (Running?), `kubectl get endpoints web-static` (non-empty?) |
| No reply from Mac | Expected. See [Accessing the IP from macOS](#accessing-the-ip-from-macos) |
| MetalLB pods not ready | `kubectl get pods -n metallb-system`; wait or re-run the `kubectl wait` command |
