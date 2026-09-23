#!/usr/bin/env bash
# Local end-to-end: create the kind cluster (if needed), apply overlays/local
# and wait for it. Safe to re-run.
#
#   ./scripts/kind-up.sh ../gamebud        # path to the app repo checkout
#
# Images: once CI has set the overlay's tags to ghcr.io/...:<sha>, the cluster
# pulls them from GHCR. While the overlay still says newTag: local, this
# script builds the images from the app repo and loads them into kind.
set -euo pipefail

GITOPS="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "${1:?usage: $0 <path-to-app-repo>}" && pwd)"
CLUSTER=gamebuddy
NS=gamebuddy

[ -f "$APP/Backend/Dockerfile" ] || { echo "$APP does not look like the app repo"; exit 1; }

if ! diff -q <(sed '/^$/d' "$APP/Backend/gb-schema.sql") \
             <(sed -n '/01-schema.sql: |/,$p' "$GITOPS/base/postgres-init-configmap.yaml" | tail -n +2 | sed 's/^    //; /^$/d') >/dev/null; then
  echo "WARNING: base/postgres-init-configmap.yaml differs from $APP/Backend/gb-schema.sql"
fi

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config "$GITOPS/cluster/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null


# Copy a locally built image into the kind node. Not `kind load docker-image`:
# it imports --all-platforms, which fails ("content digest ... not found")
# when Docker Desktop's containerd image store holds only this machine's
# platform. Importing just the node's platform works with either store.
# postgres:16-alpine is not loaded; the node pulls it from Docker Hub.
load_image() {
  echo "Loading $1 into the kind node..."
  docker save "$1" | docker exec -i "$CLUSTER-control-plane" \
    ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -
}
if grep -q 'newTag: local' "$GITOPS/overlays/local/kustomization.yaml"; then
  docker build -t gamebuddy-backend:local "$APP/Backend"
  docker build -t gamebuddy-frontend:local "$APP/Frontend"
  load_image gamebuddy-backend:local
  load_image gamebuddy-frontend:local
else
  echo "Overlay uses CI-built images from ghcr.io; skipping local build."
fi

kubectl apply -k "$GITOPS/overlays/local"

# Real Steam key (never committed) into the backend Secret: from the
# environment, else from the app repo's .env
STEAM_API_KEY="${STEAM_API_KEY:-$(grep -s '^STEAM_API_KEY=' "$APP/.env" | cut -d= -f2- || true)}"
if [ -n "$STEAM_API_KEY" ]; then
  kubectl -n "$NS" patch secret backend-secret --type merge \
    -p "{\"stringData\":{\"STEAM_API_KEY\":\"$STEAM_API_KEY\"}}"
else
  echo "No STEAM_API_KEY set: the app runs, Steam login returns 503."
fi

# Restart so pods pick up a rebuilt :local image or a re-patched Steam key
kubectl -n "$NS" rollout restart deployment/backend deployment/frontend
kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s
kubectl -n "$NS" rollout status deployment/backend --timeout=180s
kubectl -n "$NS" rollout status deployment/frontend --timeout=120s
kubectl -n "$NS" get pods

cat <<MSG

GameBuddy is running. To reach it, port-forward in another terminal:
  kubectl -n $NS port-forward svc/frontend 3000:80 &
  kubectl -n $NS port-forward svc/backend 3001:3001 4000:4000 &
then open http://localhost:3000
MSG
