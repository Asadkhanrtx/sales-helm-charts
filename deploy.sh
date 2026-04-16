#!/usr/bin/env bash
# deploy.sh — Deploy the full Opslora stack in order
# Run from: anywhere (script resolves its own path)
# Usage:  chmod +x deploy.sh && ./deploy.sh
# Uninstall: ./deploy.sh --uninstall

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS="$SCRIPT_DIR/opslora-helm"
APP_NS="opslora-app-ns"
GW_NS="opslora-gateway-ns"

# ── Guards ──────────────────────────────────────────────────────────────────
command -v helm  &>/dev/null || error "helm not found in PATH"
command -v kubectl &>/dev/null || error "kubectl not found in PATH"

kubectl cluster-info &>/dev/null || error "kubectl cannot reach the cluster — check your kubeconfig"

# ── Uninstall mode ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  warn "Uninstalling all Opslora releases..."
  for rel in opslora-frontend opslora-notification opslora-invoice \
              opslora-payment opslora-order opslora-customer opslora-auth \
              opslora-rabbitmq opslora-mysql opslora-gateway \
              opslora-storage opslora-namespace; do
    ns="$APP_NS"
    [[ "$rel" == "opslora-gateway" ]] && ns="$GW_NS"
    [[ "$rel" == "opslora-namespace" ]] && ns="kube-system"
    helm uninstall "$rel" -n "$ns" 2>/dev/null && info "Uninstalled $rel" || warn "$rel not found, skipping"
  done
  info "Done."
  exit 0
fi

deploy() {
  local release="$1" chart="$2" ns="$3"
  info "Deploying $release  →  $chart  (ns: $ns)"
  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    --wait \
    --timeout 3m \
    --atomic
  echo ""
}

# ── Pre-create namespaces (idempotent) ────────────────────────────────────
# info "Creating namespaces..."
# kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -
# kubectl create namespace "$GW_NS"  --dry-run=client -o yaml | kubectl apply -f -
# echo ""

# ──────────────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════"
info " Opslora — Full Stack Deploy"
info "════════════════════════════════════════════════════"
echo ""

# ── Wave -3: Namespace + StorageClass ─────────────────────────────────────
info "── Wave 1/3: Namespace & Storage ──"
deploy opslora-namespace  "$CHARTS/infra/app-namespace"  kube-system
deploy opslora-gateway-namespace  "$CHARTS/infra/gateway/templates/namespace.yaml"  kube-system
deploy opslora-storage    "$CHARTS/infra/storage"         "$APP_NS"

# ── Wave -2: Gateway + Databases ──────────────────────────────────────────
info "── Wave 2/3: Gateway & Databases ──"
deploy opslora-gateway   "$CHARTS/infra/gateway"   "$GW_NS"
deploy opslora-mysql     "$CHARTS/infra/mysql"     "$APP_NS"
deploy opslora-rabbitmq  "$CHARTS/infra/rabbitmq"  "$APP_NS"

info "Waiting for MySQL and RabbitMQ to be ready..."
kubectl rollout status statefulset/mysql-db  -n "$APP_NS" --timeout=120s || warn "mysql not ready yet — continuing anyway"
kubectl rollout status statefulset/rabbitmq  -n "$APP_NS" --timeout=120s || warn "rabbitmq not ready yet — continuing anyway"
echo ""

# ── Wave 0: Application services ──────────────────────────────────────────
info "── Wave 3/3: Application Services ──"
deploy opslora-auth         "$CHARTS/apps/auth"         "$APP_NS"
deploy opslora-customer     "$CHARTS/apps/customer"     "$APP_NS"
deploy opslora-order        "$CHARTS/apps/order"        "$APP_NS"
deploy opslora-payment      "$CHARTS/apps/payment"      "$APP_NS"
deploy opslora-invoice      "$CHARTS/apps/invoice"      "$APP_NS"
deploy opslora-notification "$CHARTS/apps/notification" "$APP_NS"
deploy opslora-frontend     "$CHARTS/apps/frontend"     "$APP_NS"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════"
info " Deploy complete! 🎉"
info "════════════════════════════════════════════════════"
echo ""
kubectl get pods -n "$APP_NS"
echo ""
kubectl get httproutes -n "$APP_NS"
