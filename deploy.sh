#!/usr/bin/env bash
# deploy.sh — Deploy Opslora stack by environment
# Usage:
#   ./deploy.sh dev
#   ./deploy.sh test
#   ./deploy.sh prod
#   ./deploy.sh test --uninstall

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS="$SCRIPT_DIR/opslora-helm"

ENVIRONMENT="${1:-dev}"
ACTION="${2:-}"

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) error "Invalid environment '$ENVIRONMENT'. Use: dev | test | prod" ;;
esac

APP_NS="opslora-${ENVIRONMENT}-app-ns"
GW_NS="opslora-${ENVIRONMENT}-gateway-ns"

command -v helm >/dev/null 2>&1 || error "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || error "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || error "kubectl cannot reach the cluster — check your kubeconfig"

get_values_args() {
  local chart="$1"
  local base="$chart/values.yaml"
  local env_file="$chart/values-${ENVIRONMENT}.yaml"

  local args=()

  [[ -f "$base" ]] && args+=("-f" "$base")

  if [[ "$ENVIRONMENT" != "dev" && -f "$env_file" ]]; then
    args+=("-f" "$env_file")
  fi

  echo "${args[@]}"
}

deploy() {
  local release="$1"
  local chart="$2"
  local ns="$3"

  info "Deploying $release → $chart (ns: $ns, env: $ENVIRONMENT)"

  local values_args
  values_args=$(get_values_args "$chart")

  # shellcheck disable=SC2086
  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    --create-namespace \
    $values_args

  echo ""
}

uninstall_release() {
  local release="$1"
  local ns="$2"

  helm uninstall "$release" -n "$ns" 2>/dev/null \
    && info "Uninstalled $release from $ns" \
    || warn "$release not found in $ns, skipping"
}

if [[ "$ACTION" == "--uninstall" ]]; then
  warn "Uninstalling Opslora stack for env: $ENVIRONMENT"

  for rel in opslora-frontend opslora-notification opslora-invoice \
             opslora-payment opslora-order opslora-customer opslora-auth \
             opslora-rabbitmq opslora-mysql opslora-gateway \
             opslora-storage opslora-gateway-namespace opslora-namespace; do

    ns="$APP_NS"
    [[ "$rel" == "opslora-gateway" ]] && ns="$GW_NS"
    [[ "$rel" == "opslora-namespace" ]] && ns="kube-system"
    [[ "$rel" == "opslora-gateway-namespace" ]] && ns="kube-system"

    uninstall_release "$rel" "$ns"
  done

  info "Uninstall complete."
  exit 0
fi

echo ""
info "════════════════════════════════════════════════════"
info " Opslora — Full Stack Deploy ($ENVIRONMENT)"
info "════════════════════════════════════════════════════"
echo ""

info "── Wave 1/3: Namespace & Storage ──"
deploy opslora-namespace          "$CHARTS/infra/app-namespace"      "kube-system"
deploy opslora-gateway-namespace  "$CHARTS/infra/gateway-namespace"  "kube-system"
deploy opslora-storage            "$CHARTS/infra/storage"            "$APP_NS"

info "── Wave 2/3: Gateway & Databases ──"
deploy opslora-gateway   "$CHARTS/infra/gateway"   "$GW_NS"
deploy opslora-mysql     "$CHARTS/infra/mysql"     "$APP_NS"
deploy opslora-rabbitmq  "$CHARTS/infra/rabbitmq"  "$APP_NS"

info "Waiting for MySQL and RabbitMQ to be ready..."
kubectl rollout status statefulset/mysql-db -n "$APP_NS" --timeout=60s || warn "mysql not ready yet — continuing anyway"
kubectl rollout status statefulset/rabbitmq -n "$APP_NS" --timeout=60s || warn "rabbitmq not ready yet — continuing anyway"
echo ""

info "── Wave 3/3: Application Services ──"
deploy opslora-auth         "$CHARTS/apps/auth"         "$APP_NS"
deploy opslora-customer     "$CHARTS/apps/customer"     "$APP_NS"
deploy opslora-order        "$CHARTS/apps/order"        "$APP_NS"
deploy opslora-payment      "$CHARTS/apps/payment"      "$APP_NS"
deploy opslora-invoice      "$CHARTS/apps/invoice"      "$APP_NS"
deploy opslora-notification "$CHARTS/apps/notification" "$APP_NS"
deploy opslora-frontend     "$CHARTS/apps/frontend"     "$APP_NS"

echo ""
info "════════════════════════════════════════════════════"
info " Deploy complete! 🎉"
info "════════════════════════════════════════════════════"
echo ""

kubectl get pods -n "$APP_NS"
echo ""
kubectl get httproutes -n "$APP_NS" || true