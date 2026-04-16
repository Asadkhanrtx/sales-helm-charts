#!/usr/bin/env bash
# uninstall.sh — Tear down the full Opslora stack in reverse order
# Usage: chmod +x uninstall.sh && ./uninstall.sh

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

APP_NS="opslora-app-ns"
GW_NS="opslora-gateway-ns"

command -v helm    &>/dev/null || error "helm not found in PATH"
command -v kubectl &>/dev/null || error "kubectl not found in PATH"
kubectl cluster-info &>/dev/null || error "kubectl cannot reach the cluster — check your kubeconfig"

echo ""
info "════════════════════════════════════════════════════"
info " Opslora — Full Stack Uninstall"
info "════════════════════════════════════════════════════"
echo ""

uninstall() {
  local release="$1" ns="$2"
  if helm status "$release" -n "$ns" &>/dev/null; then
    info "Uninstalling $release  (ns: $ns)"
    helm uninstall "$release" -n "$ns"
  else
    warn "$release not found in $ns — skipping"
  fi
  echo ""
}

# Apps first (reverse deploy order)
info "── Step 1/3: Application Services ──"
uninstall opslora-frontend     "$APP_NS"
uninstall opslora-notification "$APP_NS"
uninstall opslora-invoice      "$APP_NS"
uninstall opslora-payment      "$APP_NS"
uninstall opslora-order        "$APP_NS"
uninstall opslora-customer     "$APP_NS"
uninstall opslora-auth         "$APP_NS"

# Databases + gateway
info "── Step 2/3: Gateway & Databases ──"
uninstall opslora-rabbitmq  "$APP_NS"
uninstall opslora-mysql     "$APP_NS"
uninstall opslora-gateway   "$GW_NS"

# Infra
info "── Step 3/3: Storage & Namespace ──"
uninstall opslora-storage    "$APP_NS"
uninstall opslora-namespace  "kube-system"

info "════════════════════════════════════════════════════"
info " Uninstall complete."
info "════════════════════════════════════════════════════"
echo ""
info "Remaining pods in $APP_NS:"
kubectl get pods -n "$APP_NS" 2>/dev/null || warn "namespace $APP_NS already gone"
