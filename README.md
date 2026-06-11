# argocd-apps

App-of-apps GitOps control plane for ArgoCD. Manages all ArgoCD resources declaratively: ApplicationSets, AppProjects, RBAC, and CMP plugins.

## Structure

```
argocd-apps/
├── apps/                  # App-of-apps entry point — bootstrap here
│   └── root-app-of-apps-entry-point.yml   # root-app + 3 child apps
├── applicationsets/       # ApplicationSet resources (auto-discover + PR preview)
├── projects/              # AppProject resources (RBAC, source repos, sync windows)
├── rbac/                  # ArgoCD RBAC ConfigMap, SSO/Dex config, ExternalSecret
├── plugins/               # Config Management Plugin (envsubst CMP) patches
└── examples/              # Reference Application manifests (not managed by root-app)
```

## Bootstrap (k3s + ArgoCD)

```bash
# 1. Install k3s (single-node)
curl -sfL https://get.k3s.io | sh -

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Apply root-app — this is the only manual apply needed
kubectl apply -f apps/root-app-of-apps-entry-point.yml

# ArgoCD will now sync all child apps (projects-app, rbac-app,
# applicationsets-app) and manage the full control plane declaratively.
```

After bootstrap, every change to this repo is picked up automatically via selfHeal + automated sync.

## App-of-apps wiring

```
root-app  (watches apps/)
├── projects-app       → projects/   (AppProject — synced first; apps reference these)
├── rbac-app           → rbac/       (RBAC ConfigMap, Dex SSO, ExternalSecret)
└── applicationsets-app → applicationsets/  (auto-discover + PR preview AppSets)
```

`projects/` and `rbac/` are now fully declarative — no manual `kubectl apply` needed after initial bootstrap.

## ApplicationSets

| File | Generator | Purpose |
|---|---|---|
| `github-docaohieu2808-auto-discover-repos-appset.yml` | `scmProvider` | Auto-deploy all GitHub repos tagged `argocd-managed` with `Chart.yaml` |
| `github-docaohieu2808-pr-preview-appset.yml` | `pullRequest` | Ephemeral preview env per PR labelled `preview` |
| `gitlab-docaohieu-self-hosted-auto-discover-repos-appset.yml` | `scmProvider` | Auto-deploy from self-hosted GitLab |
| `multi-env-staging-production-matrix-appset.yml` | `matrix` | Deploy same app to staging + production via matrix |

**Note:** `scmProvider` and `pullRequest` generators use different template variables and are kept in separate ApplicationSet resources to avoid `missingkey=error` render failures.

## Destination cluster

All resources target `https://rancher.example.com/k8s/clusters/local` (Rancher-proxied local cluster). For in-cluster ArgoCD (no Rancher), replace with `https://kubernetes.default.svc`.

## Sync windows

`default-project` has a production sync window restricting automated syncs to business hours (see `projects/default-project-rbac-and-source-repos.yml`). Manual sync is always available.
