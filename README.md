# gamebuddy-gitops

Kubernetes manifests for [GameBuddy](https://github.com/minnal-a/gamebud).
This repo describes **what runs in the cluster**; the app repo holds the
**code and Dockerfiles**. A GitOps tool (Argo CD) watches this repo and makes
the cluster match it.

```
base/                    environment-agnostic resources (one per file)
overlays/local/          local kind cluster: dev secrets, localhost URLs, image tags (set by CI)
argocd/install/          Argo CD v3.5.3 + local tweaks (60s git polling, plain-HTTP UI)
argocd/application.yaml  Argo CD Application: sync overlays/local on main, automated
cluster/kind-config.yaml
scripts/bootstrap.sh     one-time: kind cluster, Argo CD, Steam key Secret, Application
```

## Set up (once)

Prerequisites: Docker, [kind](https://kind.sigs.k8s.io/), kubectl.

```bash
git clone https://github.com/minnal-a/gamebuddy-gitops.git
cd gamebuddy-gitops
./scripts/bootstrap.sh ../gamebud     # app repo path is only used to read .env
```

After this, **Argo CD deploys the app**: nobody runs `kubectl apply` for it.
The Steam key is the one exception: it is created in the cluster by the
script (from `STEAM_API_KEY` or `../gamebud/.env`) as the `steam-api-key`
Secret, which is not in git and so is never stored or reverted by Argo CD.

## Open the dashboards

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
# http://localhost:8080  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

kubectl -n gamebuddy port-forward svc/frontend 3000:80 &
kubectl -n gamebuddy port-forward svc/backend 3001:3001 4000:4000 &
# http://localhost:3000
```

## How a deploy happens

1. A push to `main` in the app repo runs its CI workflow: tests, then builds
   `ghcr.io/minnal-a/gamebuddy-backend` and `-frontend` tagged with the commit SHA.
2. The last CI step commits here, setting `images:` in
   `overlays/local/kustomization.yaml` to that SHA
   (commit message `Deploy minnal-a/gamebud@<sha>`).
3. Argo CD polls this repo (every 60s), sees the new tag and syncs: the
   Deployments roll to the new images. `selfHeal` also reverts manual
   `kubectl` edits, and `prune` deletes resources removed from git.

The GHCR packages must be public for the cluster to pull them without
credentials.

## base/ vs overlays/

| | base/ | overlays/local/ |
|---|---|---|
| Deployments, StatefulSet, Services, PVC | yes | |
| Shared config (ports, DB name, NODE_ENV) | `configmap.yaml` | |
| Browser-facing URLs | | `configmap-urls.yaml` (patch) |
| Secrets (DB password, JWT secret) | | local dev values only |
| Image tags | untagged | `images:` set by CI to the commit SHA |

A new environment (e.g. `overlays/prod`) reuses `base/` and supplies its own
URLs, secrets (from a secret manager, not git) and image tags.

## Keeping in step with the app repo

`base/postgres-init-configmap.yaml` is a copy of `Backend/gb-schema.sql`;
a schema change in the app repo needs a matching commit here.

## Tear down

`kind delete cluster --name gamebuddy`
