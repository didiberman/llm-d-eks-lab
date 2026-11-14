#!/usr/bin/env bash
# Pre-pull every image the local GitOps stack needs on the host — in parallel —
# and side-load them into the kind nodes.
#
# Why: kubelet pulls one image per pod under Helm/Argo CD timeouts, and some
# registries (ghcr.io especially) can be slow from a laptop. Pulling once on the
# host and loading into the nodes turns a 20+ minute flaky bring-up into a few
# minutes, and a re-run costs nothing because the host keeps the images.
#
#   kind-prepull.sh <kind-cluster-name>
#
# Keep in sync with the pinned charts (regenerate with `helm template ... | grep image:`).
set -uo pipefail
CLUSTER=${1:?kind cluster name}
PLATFORM="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

IMAGES=(
  ghcr.io/kedacore/keda:2.21.0
  ghcr.io/kedacore/keda-metrics-apiserver:2.21.0
  ghcr.io/kedacore/keda-admission-webhooks:2.21.0
  quay.io/prometheus-operator/prometheus-operator:v0.94.2
  quay.io/prometheus-operator/prometheus-config-reloader:v0.94.2
  quay.io/prometheus/prometheus:v3.15.1-distroless
  ghcr.io/jkroepke/kube-webhook-certgen:1.11.0
  quay.io/argoproj/argocd:v3.6.1
  ecr-public.aws.com/docker/library/redis:8.6.4-alpine
  docker.io/envoyproxy/envoy:distroless-v1.33.2
  ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0
  ghcr.io/llm-d/llm-d-inference-sim:v1.0.0
  ghcr.io/open-webui/open-webui:0.13.3
)

NODES=$(kind get nodes --name "$CLUSTER")

# Import into every node. `kind load docker-image` breaks on Docker Desktop's
# containerd image store: the exported index references platforms that were
# never downloaded ("content digest ... not found"). Saving just this machine's
# platform and importing with ctr avoids that.
load() {
  local img=$1 node
  for node in $NODES; do
    docker save --platform "$PLATFORM" "$img" \
      | docker exec -i "$node" ctr -n k8s.io images import --snapshotter=overlayfs - >/dev/null 2>&1 || return 1
  done
}

echo "    pulling + loading ${#IMAGES[@]} images for $PLATFORM in parallel (cached images return instantly)"
pids=()
for img in "${IMAGES[@]}"; do
  (
    if docker pull -q --platform "$PLATFORM" "$img" >/dev/null 2>&1 && load "$img"; then
      echo "    ready   $img"
    else
      echo "    skipped $img (kubelet will pull it itself)"
    fi
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
