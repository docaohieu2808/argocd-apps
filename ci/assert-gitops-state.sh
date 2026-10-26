#!/usr/bin/env bash
# After the app-of-apps has converged, check what the controllers actually produced.
set -euo pipefail

fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected '$2', got '$3'" >&2; fail=1; fi
}

# 1. The matrix ApplicationSet rendered exactly the staging and production apps (1 app x 2 environments).
generated=$(kubectl -n argocd get applications -l app=test-deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | paste -sd, -)
check "matrix AppSet generated apps" "test-deploy-production,test-deploy-staging" "$generated"

# 2. Each generated app deployed its own replica count (kustomize.replicas set per environment) and is ready.
for env_replicas in staging:1 production:2; do
  env=${env_replicas%%:*}; want=${env_replicas##*:}
  ns="test-deploy-$env"
  check "$env desired replicas" "$want" "$(kubectl -n "$ns" get deployment demo-web -o jsonpath='{.spec.replicas}')"
  check "$env ready replicas" "$want" "$(kubectl -n "$ns" get deployment demo-web -o jsonpath='{.status.readyReplicas}')"
done

# 3. The PR-preview ApplicationSet is accepted by the controller and reached GitHub (no ErrorOccurred condition).
# No PR carries the "preview" label, so it correctly generates zero applications.
check "PR AppSet error condition" "False" \
  "$(kubectl -n argocd get applicationset pr-preview-argocd-test-deploy -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].status}')"
check "PR AppSet generated apps" "0" \
  "$(kubectl -n argocd get applications -l type=pr-preview --no-headers 2>/dev/null | wc -l | tr -d ' ')"

# 4. rbac-app applied the 3.x policy and the project it needs exists with no sync window blocking auto-sync.
policy=$(kubectl -n argocd get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}')
if grep -q 'applications, update/\*, \*/\*, allow' <<< "$policy"; then
  echo "ok   argocd-rbac-cm has update/* policy"
else
  echo "FAIL argocd-rbac-cm missing update/*" >&2; fail=1
fi
check "default-project sync windows" "" "$(kubectl -n argocd get appproject default-project -o jsonpath='{.spec.syncWindows}')"

exit "$fail"
