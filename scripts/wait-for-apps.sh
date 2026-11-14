#!/usr/bin/env bash
# Wait until the root Argo CD app and every child app are Synced + Healthy,
# and until the root's rendered set of children matches what exists.
# Used by local/argocd-up.sh and the deploy workflow's verify job.
#
#   wait-for-apps.sh [timeout-seconds]
#
# Prints a line whenever the state changes; exits non-zero on timeout with a
# dump of whatever is unhealthy.
set -uo pipefail
TIMEOUT=${1:-900}
deadline=$(( $(date +%s) + TIMEOUT ))
prev=""

# Ask Argo CD to re-read git now instead of on its next poll.
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

while :; do
  state=$(kubectl -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null | sort)
  if [ "$state" != "$prev" ]; then
    echo "[$(date +%H:%M:%S)] $(echo "$state" | tr '\n' ' ')"
    prev=$state
  fi

  root=$(echo "$state" | awk -F= '$1=="root"{print $2}')
  others=$(echo "$state" | grep -v '^root=' | grep -c . || true)
  bad=$(echo "$state" | grep -v '=Synced/Healthy$' | grep -c . || true)
  # Children the root currently wants (tier none -> 0).
  wanted=$(kubectl -n argocd get application root \
    -o jsonpath='{range .status.resources[?(@.kind=="Application")]}{.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)

  if [ "$root" = "Synced/Healthy" ] && [ "$bad" -eq 0 ] && [ "$others" -eq "$wanted" ]; then
    echo "All $((others + 1)) Argo CD application(s) Synced and Healthy."
    exit 0
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for Argo CD."
    kubectl -n argocd get applications.argoproj.io -o wide || true
    for app in $(echo "$state" | grep -v '=Synced/Healthy$' | cut -d= -f1); do
      echo "--- $app"
      kubectl -n argocd get application "$app" \
        -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}' || true
      kubectl -n argocd get application "$app" \
        -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name}: {.health.status} {.health.message}{"\n"}{end}' || true
    done
    exit 1
  fi
  sleep 10
done
