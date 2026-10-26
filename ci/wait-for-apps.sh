#!/usr/bin/env bash
# Wait until every named Argo CD Application is Synced and Healthy (read from .status, no argocd CLI login needed).
# Usage: wait-for-apps.sh <timeout-seconds> <app> [<app>...]
# On timeout, prints each app's status and conditions plus the controller log tail, then exits 1.
set -euo pipefail

timeout_s=$1
shift
deadline=$((SECONDS + timeout_s))

status_of() {
  kubectl -n argocd get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "missing/missing"
}

for app in "$@"; do
  while true; do
    st=$(status_of "$app")
    if [ "$st" = "Synced/Healthy" ]; then
      echo "ok   $app $st"
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL $app is $st after ${timeout_s}s" >&2
      kubectl -n argocd get applications -o wide || true
      kubectl -n argocd get application "$app" -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}' || true
      kubectl -n argocd logs statefulset/argocd-application-controller --tail=60 || true
      kubectl -n argocd logs deployment/argocd-repo-server --all-containers --tail=60 || true
      exit 1
    fi
    sleep 5
  done
done
