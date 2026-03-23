# ArgoCD Apps — ApplicationSets + App of Apps + RBAC

GitOps configuration for ArgoCD: auto-discovers repos, manages multi-env deployments, enforces RBAC per team, and supports SSO via GitLab Dex OIDC. One `root-app` bootstraps everything.

## Architecture

```
root-app (App of Apps)
    └── watches: argocd-apps/applicationsets/
            ├── github-auto-discover-appset      — SCM generator, discovers all GitHub repos with Chart.yaml
            ├── gitlab-auto-discover-appset      — SCM generator, self-hosted GitLab
            └── multi-env-staging-production-appset  — Matrix generator, cross-product repos × envs
```

Bootstrap flow: apply `root-app` once → ArgoCD self-manages all ApplicationSets → ApplicationSets auto-create Applications → Applications sync Helm charts to cluster.

---

## Levels

| Level | What you get |
|-------|-------------|
| **L1** | Apply a single Application manifest. One app, one cluster, manual sync. |
| **L2** | App of Apps pattern. One root app bootstraps all other apps from a git directory. |
| **L3** | ApplicationSets with SCM generator. Auto-discover and deploy all repos in a GitHub/GitLab org. |
| **L4** | Matrix ApplicationSet. Cross-product of repos × environments (staging + production) from one manifest. |
| **MAX** | RBAC + SSO. GitLab Dex OIDC maps groups to roles (admin/developer/viewer). Multi-cluster external secrets. |

---

## Prerequisites

- ArgoCD installed on Kubernetes (`kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`)
- `argocd` CLI installed
- Git repo accessible from the ArgoCD server (add repo credentials in ArgoCD if private)
- For SSO: GitLab instance with OAuth app configured

---

## Installation

### 1. Install ArgoCD (if not already)

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
```

### 2. Add this repo to ArgoCD

```bash
# Get initial admin password
argocd admin initial-password -n argocd

# Login
argocd login <ARGOCD_SERVER> --username admin --password <PASSWORD>

# Add repo (if private)
argocd repo add https://github.com/docaohieu2808/argocd-apps.git \
  --username <user> --password <token>
```

### 3. Apply the default project and RBAC

```bash
kubectl apply -f projects/default-project-rbac-and-source-repos.yml -n argocd
kubectl apply -f rbac/argocd-rbac-multi-team-config.yaml -n argocd
```

### 4. Bootstrap with root App of Apps

```bash
kubectl apply -f apps/root-app-of-apps-entry-point.yml -n argocd
```

ArgoCD now watches `applicationsets/` in this repo. Any ApplicationSet added there is auto-synced.

---

## Quick Start — Deploy a single app

### Plain YAML app

```yaml
# Copy from examples/simple-plain-yaml-single-app-example.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default-project
  source:
    repoURL: https://github.com/myorg/my-app.git
    targetRevision: main
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f my-app.yml -n argocd
```

### Helm app with values override

```bash
# See examples/helm-chart-app-with-values-override-example.yml
kubectl apply -f examples/helm-chart-app-with-values-override-example.yml -n argocd
```

---

## ApplicationSets Reference

### Auto-discover GitHub repos

`applicationsets/github-docaohieu2808-auto-discover-repos-appset.yml`

Discovers all repos in the `docaohieu2808` GitHub org that:
- Have a `Chart.yaml` (Helm apps)
- Are on `main` or `master` branch
- Have the `argocd-managed` label

Also deploys PRs labeled `preview` to ephemeral environments.

To add a repo to auto-discovery: add the `argocd-managed` label in GitHub → ArgoCD picks it up within 3 minutes.

### Auto-discover GitLab repos

`applicationsets/gitlab-docaohieu-self-hosted-auto-discover-repos-appset.yml`

Same pattern for self-hosted GitLab at `git.example.com`.

### Multi-env staging + production matrix

`applicationsets/multi-env-staging-production-matrix-appset.yml`

Cross-product generator: **3 repos × 2 environments = 6 Applications** created automatically.

```
app-frontend-staging      app-frontend-production
app-backend-staging       app-backend-production
app-api-staging           app-api-production
```

Each app gets environment-specific:
- `targetRevision`: `develop` (staging) or `main` (production)
- `valuesFile`: `values-staging.yaml` or `values-production.yaml`
- `replicaCount`: `1` (staging) or `2` (production)
- `ingress.hostname`: `<app>.staging.example.com` or `<app>.docaohieu.com`

To add a new app: add an entry to the `list` generator in the ApplicationSet — no other changes needed.

---

## RBAC

Three roles mapped to GitLab groups via Dex SSO:

| Role | Permissions | GitLab groups |
|------|-------------|---------------|
| `admin` | Full access — all apps, clusters, repos, accounts | `devops-team`, `platform-team` |
| `developer` | Create/update/sync apps, view logs. No delete, no cluster admin | `backend-team`, `frontend-team`, `dev-team` |
| `viewer` | Read-only across all resources | `qa-team`, `management` |

Default role for authenticated users who match no group: `viewer`.

To modify: edit `rbac/argocd-rbac-multi-team-config.yaml` and apply:

```bash
kubectl apply -f rbac/argocd-rbac-multi-team-config.yaml -n argocd
```

---

## SSO Setup (GitLab Dex OIDC)

1. Create GitLab OAuth app: `GitLab → User Settings → Applications`
   - Redirect URI: `https://<ARGOCD_HOST>/api/dex/callback`
   - Scopes: `openid`, `profile`, `email`, `groups`

2. Configure Dex connector:

```bash
# Edit rbac/argocd-sso-dex-oidc-gitlab-config.yaml
# Replace CLIENT_ID, CLIENT_SECRET, GITLAB_HOST placeholders
kubectl apply -f rbac/argocd-sso-dex-oidc-gitlab-config.yaml -n argocd
kubectl rollout restart deployment/argocd-server -n argocd
```

3. Users logging in via GitLab are automatically assigned roles based on their GitLab group membership.

---

## envsubst Config Management Plugin

For apps that use plain YAML with `$ENV_VAR` substitution instead of Helm:

```bash
# Patch argocd-repo-server to add envsubst sidecar
kubectl apply -f plugins/argocd-repo-server-sidecar-patch-envsubst-config-management-plugin.yaml -n argocd

# Register the plugin
kubectl apply -f plugins/argocd-custom-config-management-plugin-envsubst-template-yaml-files.yaml -n argocd
```

Then reference in your Application:

```yaml
source:
  plugin:
    name: envsubst
```

---

## Configuration Reference

### syncPolicy defaults (used in all ApplicationSets)

| Option | Value | Effect |
|--------|-------|--------|
| `automated.prune` | `true` | Delete K8s resources removed from git |
| `automated.selfHeal` | `true` | Revert manual cluster changes |
| `automated.allowEmpty` | `false` | Never sync an empty app |
| `CreateNamespace` | `true` | Auto-create namespace if missing |
| `PrunePropagationPolicy` | `foreground` | Wait for child resources to delete |
| `PruneLast` | `true` | Delete resources after new ones are healthy |
| retry `limit` | `5` | Retry failed syncs up to 5 times |
| retry backoff | `5s × 2, max 3m` | Exponential backoff between retries |

### ignoreDifferences (multi-env ApplicationSet)

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas   # allows HPA to manage replica count in production
```

---

## Repository Structure

```
argocd-apps/
├── apps/
│   └── root-app-of-apps-entry-point.yml          # Bootstrap: apply this once
├── applicationsets/
│   ├── github-docaohieu2808-auto-discover-repos-appset.yml
│   ├── gitlab-docaohieu-self-hosted-auto-discover-repos-appset.yml
│   └── multi-env-staging-production-matrix-appset.yml
├── projects/
│   └── default-project-rbac-and-source-repos.yml
├── rbac/
│   ├── argocd-rbac-multi-team-config.yaml         # Role definitions + group mappings
│   ├── argocd-sso-dex-oidc-gitlab-config.yaml     # GitLab SSO via Dex
│   └── argocd-multi-cluster-external-secret-template.yaml
├── plugins/
│   ├── argocd-custom-config-management-plugin-envsubst-template-yaml-files.yaml
│   └── argocd-repo-server-sidecar-patch-envsubst-config-management-plugin.yaml
└── examples/
    ├── simple-plain-yaml-single-app-example.yml
    └── helm-chart-app-with-values-override-example.yml
```
