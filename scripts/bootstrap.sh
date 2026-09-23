#!/usr/bin/env bash
# One-time setup of the local GitOps loop. Safe to re-run.
#   1. kind cluster (if missing)
#   2. Argo CD (pinned, see argocd/install)
#   3. the out-of-git Steam key Secret, if you have one
#   4. the Argo CD Application -> from here Argo CD deploys whatever is on
#      main in this repo; no more kubectl apply for the app.
#
#   ./scripts/bootstrap.sh [path-to-app-repo]   # app repo only used for .env
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/../gamebud}"
CLUSTER=gamebuddy

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config "$ROOT/cluster/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "Installing Argo CD..."
# Server-side apply: Argo CD's CRDs are too large for client-side apply
kubectl apply -k "$ROOT/argocd/install" --server-side --force-conflicts >/dev/null
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# Steam key: from the environment, else the app repo's .env. Kept out of git
# (and so out of Argo CD's hands); the backend reads it as optional.
STEAM_API_KEY="${STEAM_API_KEY:-$(grep -s '^STEAM_API_KEY=' "$APP/.env" | cut -d= -f2- || true)}"
kubectl create namespace gamebuddy --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [ -n "$STEAM_API_KEY" ]; then
  kubectl -n gamebuddy create secret generic steam-api-key \
    --from-literal=STEAM_API_KEY="$STEAM_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
else
  echo "No STEAM_API_KEY found: the app runs, Steam login returns 503."
fi

kubectl apply -f "$ROOT/argocd/application.yaml"

echo "Waiting for Argo CD to sync GameBuddy (first sync pulls images)..."
for _ in $(seq 1 60); do
  status=$(kubectl -n argocd get application gamebuddy \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  echo "  sync/health: ${status:-pending}"
  [ "$status" = "Synced/Healthy" ] && break
  sleep 10
done
kubectl -n gamebuddy get pods

PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
cat <<MSG

Argo CD UI:
  kubectl -n argocd port-forward svc/argocd-server 8080:80
  open http://localhost:8080   (user: admin, password: $PASSWORD)

GameBuddy:
  kubectl -n gamebuddy port-forward svc/frontend 3000:80 &
  kubectl -n gamebuddy port-forward svc/backend 3001:3001 4000:4000 &
  open http://localhost:3000
MSG
