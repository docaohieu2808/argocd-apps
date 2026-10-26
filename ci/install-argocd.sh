#!/usr/bin/env bash
# Install Argo CD from the upstream manifest of one release into a kind cluster and wait until it is ready.
# Usage: install-argocd.sh <version, e.g. v3.5.6> <kind cluster name>
# - Images are pulled on the runner (with retries) and loaded into kind: anonymous pulls from public.ecr.aws (the
#   redis image) are rate-limited on GitHub runners ("toomanyrequests: Data limit exceeded"), so those fall back to
#   the Docker Hub library image through mirror.gcr.io, then docker.io.
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
# pull_with_fallback <image>: try the manifest's image first, then mirrors of the same Docker Hub library image,
# and tag whatever worked with the original name so the manifest needs no edit.
pull_with_fallback() {
  local image=$1 candidates=("$1") name
  if [[ $image == public.ecr.aws/docker/library/* ]]; then
    name=${image#public.ecr.aws/docker/library/}
    candidates+=("mirror.gcr.io/library/$name" "docker.io/library/$name")
  fi
  for attempt in 1 2 3; do
    for candidate in "${candidates[@]}"; do
      if docker pull --quiet "$candidate" >/dev/null; then
        [ "$candidate" = "$image" ] || docker tag "$candidate" "$image"
        return 0
      fi
    done
    sleep $((attempt * 5))
  done
  echo "could not pull $image" >&2
  return 1
}

while read -r image; do
  pull_with_fallback "$image"
  kind load docker-image "$image" --name "$cluster"
done < <(grep -E '^\s+image: ' "$manifest" | awk '{print $2}' | sort -u)

kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f "$manifest"
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-applicationset-controller argocd-redis argocd-dex-server; do
  kubectl -n argocd rollout status "deployment/$d" --timeout=300s
done
