#!/usr/bin/env bash
# Install Argo CD from the upstream manifest of one release and wait until its components are ready.
# Usage: install-argocd.sh <version, e.g. v3.5.6>
# --server-side: the ApplicationSet CRD is too large for the client-side apply annotation.
set -euo pipefail

version=$1
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${version}/manifests/install.yaml"
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-applicationset-controller argocd-redis argocd-dex-server; do
  kubectl -n argocd rollout status "deployment/$d" --timeout=300s
done
