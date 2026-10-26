#!/usr/bin/env bash
# Install Argo CD from the upstream manifest of one release into a kind cluster and wait until it is ready.
# Usage: install-argocd.sh <version, e.g. v3.5.6> <kind cluster name>
# - Images are pulled on the runner (with retries) and loaded into kind: pulls made by the node itself from
#   public.ecr.aws (the redis image) intermittently ended in ImagePullBackOff and stalled the whole job.
# - --server-side: the ApplicationSet CRD is too large for the client-side apply annotation.
set -euo pipefail

version=$1
cluster=$2
manifest=$(mktemp)
diagnose() {
  kubectl -n argocd get pods -o wide || true
  kubectl -n argocd describe pods | grep -E '^Name:|Events:|Warning|Failed|Back-off' || true
}
trap diagnose ERR

curl -sSfL -o "$manifest" "https://raw.githubusercontent.com/argoproj/argo-cd/${version}/manifests/install.yaml"
while read -r image; do
  for attempt in 1 2 3 4 5; do
    docker pull --quiet "$image" >/dev/null && break
    [ "$attempt" -lt 5 ] || { echo "could not pull $image" >&2; exit 1; }
    sleep $((attempt * 5))
  done
  kind load docker-image "$image" --name "$cluster"
done < <(grep -E '^\s+image: ' "$manifest" | awk '{print $2}' | sort -u)

kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f "$manifest"
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-applicationset-controller argocd-redis argocd-dex-server; do
  kubectl -n argocd rollout status "deployment/$d" --timeout=300s
done
