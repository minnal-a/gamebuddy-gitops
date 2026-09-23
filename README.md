# gamebuddy-gitops

Kubernetes manifests for [GameBuddy](https://github.com/minnal-a/gamebud).
This repo describes **what runs in the cluster**; the app repo holds the
**code and Dockerfiles**. A GitOps tool (Argo CD) watches this repo and makes
the cluster match it.

```
base/                  environment-agnostic resources (one per file)
overlays/local/        local kind cluster: dev secrets, localhost URLs, image tags
cluster/kind-config.yaml
scripts/kind-up.sh     build images from the app repo, load into kind, apply
```

## Run locally (kind)

Prerequisites: Docker, [kind](https://kind.sigs.k8s.io/), kubectl, and the
app repo checked out next to this one.

```bash
git clone https://github.com/minnal-a/gamebud.git
git clone https://github.com/minnal-a/gamebuddy-gitops.git
cd gamebuddy-gitops
./scripts/kind-up.sh ../gamebud
kubectl -n gamebuddy get pods
```

The Steam key is read from `STEAM_API_KEY` or `../gamebud/.env` and patched
into the cluster; it is never committed here.

Reach the app with port-forwards (the frontend calls the API and chat on
localhost:3001/4000):

```bash
kubectl -n gamebuddy port-forward svc/frontend 3000:80 &
kubectl -n gamebuddy port-forward svc/backend 3001:3001 4000:4000 &
```

Then open http://localhost:3000.

Apply manifest changes only: `kubectl apply -k overlays/local`
Preview what an overlay renders: `kubectl kustomize overlays/local`
Tear down: `kind delete cluster --name gamebuddy`

## base/ vs overlays/

| | base/ | overlays/local/ |
|---|---|---|
| Deployments, StatefulSet, Services, PVC | yes | |
| Shared config (ports, DB name, NODE_ENV) | `configmap.yaml` | |
| Browser-facing URLs | | `configmap-urls.yaml` (patch) |
| Secrets (DB password, JWT secret) | | local dev values only |
| Image tags | untagged | `images:` sets `:local` |

A new environment (e.g. `overlays/prod`) reuses `base/` and supplies its own
URLs, secrets (from a secret manager, not git) and image tags.

## Keeping in step with the app repo

`base/postgres-init-configmap.yaml` is a copy of `Backend/gb-schema.sql`;
`kind-up.sh` warns if they differ.
