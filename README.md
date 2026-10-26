# argocd-apps

App-of-apps GitOps control plane for Argo CD 3.x: one bootstrap Application pulls in AppProjects, RBAC and
ApplicationSets from this repository. CI installs a real Argo CD in a kind cluster and proves the whole thing syncs.

## What is here

```
argocd-apps/
├── bootstrap/root-app.yaml        # the ONE file you kubectl apply (project `default`, path apps/)
├── apps/                          # child Applications + kustomization.yaml, sync-waved: projects, rbac, applicationsets
├── projects/                      # AppProject `default-project` (source repos, destinations, roles)
├── rbac/                          # argocd-rbac-cm (3.x policy), synced with prune OFF
├── applicationsets/               # live ApplicationSets
│   ├── matrix-test-deploy-staging-production-appset.yml   # matrix: app x environment, deploys argocd-test-deploy
│   └── pr-preview-argocd-test-deploy-appset.yml           # pullRequest generator, one preview app per labelled PR
├── plugins/                       # envsubst Config Management Plugin: ConfigMap, repo-server sidecar patch, Dockerfile, example app
├── examples/                      # NOT synced: reference manifests (see below)
└── ci/                            # scripts used by .github/workflows/ci.yml
```

Why the layout looks like this:

- `bootstrap/root-app.yaml` is outside `apps/` so the root never manages itself, and it lives in Argo CD's built-in
  `default` project because `default-project` is created by `projects-app`, a child of the root.
- Sync waves (`projects-app` 0, `rbac-app` 1, `applicationsets-app` 2) make "projects first" true.
- Only manifests that work out of the box are synced. Anything that needs your tokens, org, cluster or secrets is in
  `examples/` or `plugins/`, so nothing with a placeholder can be pruned into a live cluster or overwrite Argo CD's own
  configuration.
- `rbac-app` has `prune: false`: it must never delete Argo CD's own ConfigMap.

## Run it

Needs a cluster (`kind create cluster`, k3s, ...) and `kubectl`. Destination is the cluster Argo CD runs in
(`https://kubernetes.default.svc`).

```bash
kubectl create namespace argocd
# --server-side: the ApplicationSet CRD is too large for client-side apply
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl apply -f bootstrap/root-app.yaml

kubectl -n argocd get applications     # root-app, projects-app, rbac-app, applicationsets-app,
                                       # test-deploy-staging, test-deploy-production
```

To use your own fork, change `repoURL` in `bootstrap/root-app.yaml`, `apps/child-applications.yml`, the AppSets and the
`sourceRepos` in `projects/`.

## What each live piece teaches

| File | Concept |
|---|---|
| `apps/child-applications.yml` | App-of-apps, sync waves, `prune: false` for config you must not lose |
| `projects/default-project-rbac-and-source-repos.yml` | AppProject: allowed repos, destinations, cluster-scoped resource whitelist, project roles and groups |
| `rbac/argocd-rbac-cm.yaml` | Argo CD 3.x RBAC: `update/*` and `delete/*` sub-resource policies, `applicationsets` resource, group mapping, `policy.default` |
| `applicationsets/matrix-...yml` | Matrix of two list generators, `goTemplate` with `missingkey=error`, per-environment `kustomize.replicas` |
| `applicationsets/pr-preview-...yml` | Pull request generator: `repo` is required (one AppSet per repo), the params it really emits (`number`, `branch_slug`, `head_sha`, ...), preview namespace per PR |

## Not synced: `examples/` and `plugins/`

| Path | Teaches |
|---|---|
| `examples/applicationsets/github-org-scm-provider-auto-discover-appset.yml` | SCM provider generator on a GitHub **organization** (it calls the org API, so it does not work for a personal account such as `docaohieu2808`) |
| `examples/applicationsets/gitlab-group-scm-provider-auto-discover-appset.yml` | SCM provider on a self-hosted GitLab `group` (required) with subgroups |
| `examples/applicationsets/cluster-generator-example.yml` | Cluster generator over registered clusters |
| `examples/rbac/cluster-registration-secret-example.yaml` | Registering a remote cluster with a Secret |
| `examples/sso/dex-gitlab-connector-argocd-cm-patch-example.yaml` | Dex + GitLab SSO as a `kubectl patch` of `argocd-cm`; secrets via `$dex.gitlab.clientSecret` from `argocd-secret`; the `oidc` connector needs `insecureEnableGroups: true` to emit groups |
| `examples/projects/production-sync-window-project-example.yml` | Sync windows with an explicit `timeZone` |
| `examples/plain-yaml-app-example.yml`, `examples/helm-and-kustomize-apps-example.yml` | Plain, Helm and Kustomize sources (`kustomize.images` is a list of `name=ref` strings; Ingress uses Traefik, ingress-nginx is archived) |
| `plugins/` | Config Management Plugin (CMP) |

### The envsubst CMP

A CMP is not a Kubernetes resource (the `ConfigManagementPlugin` CRD was removed in Argo CD 2.8). Its spec is a
`plugin.yaml` file read by a sidecar of `argocd-repo-server`:

1. `plugins/envsubst-cmp-plugin-configmap.yaml`: ConfigMap with key `plugin.yaml` (discover `**/*.yaml.tmpl`, generate with
   `envsubst`; only an allow-list of variables is substituted and nothing from the repo is sourced as shell).
2. `plugins/Dockerfile`: sidecar image (`alpine` + `gettext`). Build and push it, then set the image in the patch.
3. `plugins/envsubst-cmp-repo-server-sidecar-patch.yaml`: adds the sidecar using the volumes the stock install already has
   (`var-files` carries the `argocd-cmp-server` binary copied by repo-server's own init container, so it always matches the
   Argo CD version; `plugins` holds the socket).
4. `plugins/envsubst-cmp-example-application.yaml` + `plugins/example-app/`: an Application that only renders through the plugin.

## What CI checks

`.github/workflows/ci.yml`, on every push, pull request, weekly (Monday 02:37 UTC) and on demand:

- **lint**: actionlint, shellcheck, yamllint, hadolint, every action pinned to an existing commit SHA, and
  `kubeconform -strict` over every manifest with Kubernetes 1.37 schemas plus the Argo CD CRD schemas
  ([datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog)).
- **app-of-apps** (pinned Argo CD v3.5.6 and the newest upstream release): kind cluster, real Argo CD, `bootstrap/root-app.yaml`
  applied against this repository at the commit under test (the root and, through a kustomize patch, all child Applications),
  then it waits for `root-app`, `projects-app`, `rbac-app`, `applicationsets-app` and the generated `test-deploy-staging` and
  `test-deploy-production` to be Synced and Healthy and asserts: exactly those two apps were generated, they run 1 and 2
  ready replicas, the PR-preview AppSet has no `ErrorOccurred` condition and generates 0 apps (no PR is labelled), the 3.x
  RBAC policy was applied, and `default-project` has no sync window.
- **cmp** (same two Argo CD versions): builds the sidecar image, loads it into kind, installs the ConfigMap and the patch on
  repo-server, then syncs an app that can only render through the plugin and checks the replicas and image came from the
  templates.

## Honest limits

- Needs internet on the runner (Argo CD pulls this repo and `argocd-test-deploy` from GitHub); pull requests from forks
  cannot run the e2e jobs because their commit is not fetchable from this repository.
- The SCM-provider generators, SSO, and multi-cluster examples are validated against the CRD schemas only: they need a real
  organization, GitLab group, token or second cluster.
- Notification annotations are not used: no notifications controller configuration ships here.

## Updating Argo CD

`ARGOCD_PINNED` in the workflow and the version in the install commands above move together; the `latest` matrix leg
warns a week early when a new release breaks something.
