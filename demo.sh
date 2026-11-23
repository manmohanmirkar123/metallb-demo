#!/usr/bin/env bash
# MetalLB static-IP demo on kind.  Usage: ./demo.sh [up|test|down]
set -euo pipefail
cd "$(dirname "$0")"
step(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; read -rp "  (enter) " _; }

up(){
  step "1. Create kind cluster (1 control-plane, 2 workers)"
  kind create cluster --config kind-config.yaml
  docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'

  step "2. Install MetalLB"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
  kubectl wait -n metallb-system --for=condition=ready pod -l app=metallb --timeout=180s

  step "3. Give MetalLB an IP pool from the kind network + L2 advertisement"
  cat metallb-pool.yaml; kubectl apply -f metallb-pool.yaml

  step "4. Deploy app + LoadBalancer Service pinned to 172.18.255.210"
  cat app-static-ip.yaml; kubectl apply -f app-static-ip.yaml
  kubectl rollout status deploy/web
  kubectl get svc web-static
}
verify(){
  step "5. Call the static IP from a client on the kind network"
  docker run --rm --network kind curlimages/curl:8.10.1 -s http://172.18.255.210

  step "6. Delete & recreate the Service -> same IP comes back"
  kubectl delete svc web-static
  kubectl apply -f app-static-ip.yaml; sleep 3
  kubectl get svc web-static
}
case "${1:-up}" in
  up) up; verify ;;
  test) verify ;;
  down) kind delete cluster --name metallb-demo ;;
esac
