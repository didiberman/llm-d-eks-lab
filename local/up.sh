#!/usr/bin/env bash
# T0 — bring up the whole llm-d + KEDA autoscaling stack locally, for $0.
#
# Installs the same components and the same versions as the EKS path, against
# llm-d-inference-sim instead of vLLM on a GPU. Use this to debug the router
# config, EPP plugins and the KEDA ScaledObject before spending a cent.
#
# What T0 CANNOT test: Karpenter (it provisions EC2), spot interruption, the
# NLB, and real token throughput. Everything else is faithful.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

CLUSTER=llm-d-eks-lab
NS=llm-d
MON_NS=llm-d-monitoring
RELEASE=llm-d

# Keep aligned with terraform/10-cluster/variables.tf.
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.6.2}
GAIE_VERSION=${GAIE_VERSION:-v1.6.2}
KEDA_VERSION=${KEDA_VERSION:-2.21.0}
PROM_VERSION=${PROM_VERSION:-92.16.0}
ROUTER_VERSION=${ROUTER_VERSION:-v1.0.0}
SIM_IMAGE=${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v1.0.0}
MODEL=${MODEL:-Qwen/Qwen3.5-4B}

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }

need kind; need kubectl; need helm

step "Creating kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    already exists, reusing"
else
  kind create cluster --config local/kind-config.yaml --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

step "Installing Gateway API CRDs ($GATEWAY_API_VERSION)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

step "Installing Gateway API Inference Extension CRDs ($GAIE_VERSION)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"

step "Installing KEDA ($KEDA_VERSION)"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --version "$KEDA_VERSION" --wait --timeout 5m

# Release name and namespace must match what the ScaledObject queries:
#   llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc:9090
step "Installing Prometheus ($PROM_VERSION) — KEDA reads EPP metrics from it"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install llmd prometheus-community/kube-prometheus-stack \
  --namespace "$MON_NS" --create-namespace --version "$PROM_VERSION" \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set nodeExporter.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set kubeApiServer.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false \
  --set kubeEtcd.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  --set prometheus.prometheusSpec.retention=2h \
  --wait --timeout 10m

step "Creating namespace and HF token secret"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# The llm-d charts mount HF_TOKEN unconditionally. An empty value is fine for
# the ungated models used here.
kubectl -n "$NS" create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

step "Installing llm-d router ($ROUTER_VERSION)"
# Same values the EKS path uses; substitute the one template variable.
sed "s|\${inference_pool}|${RELEASE}|g" manifests/router/values.yaml.tftpl > /tmp/llmd-router-values.yaml
helm upgrade --install "$RELEASE" oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
  --version "$ROUTER_VERSION" --namespace "$NS" \
  -f /tmp/llmd-router-values.yaml --wait --timeout 10m

# Plain sed rather than envsubst: envsubst ships with GNU gettext and is not
# present on a stock macOS, and the substitutions here are trivial.
render() {
  sed -e "s|\${MODEL}|${MODEL}|g" \
      -e "s|\${SIM_IMAGE}|${SIM_IMAGE}|g" \
      -e "s|\${RELEASE}|${RELEASE}|g" \
      -e "s|\${NS}|${NS}|g" "$1"
}

step "Deploying the simulator model server"
render manifests/sim/modelserver.yaml | kubectl apply -f -

step "Applying the KEDA ScaledObject (queue-depth signal)"
render manifests/sim/scaledobject.yaml | kubectl apply -f -

step "Exposing the router on localhost:8080"
render manifests/sim/nodeport.yaml | kubectl apply -f -

step "Waiting for the model server to become Ready"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-vllm-decode" --timeout=5m

cat <<EOF

$(printf '\033[1;32mT0 is up — cost: $0.00\033[0m')

  Try it:
    curl -s http://localhost:8080/v1/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"${MODEL}","prompt":"Hello","max_tokens":16}' | jq

  Watch autoscaling:
    kubectl -n ${NS} get scaledobject,hpa,pods -w

  Generate load (drives queue depth up, should scale 1 -> 2+):
    make load

  Verify KEDA is actually seeing the metric:
    kubectl -n ${MON_NS} port-forward svc/llmd-kube-prometheus-stack-prometheus 9090:9090 &
    open 'http://localhost:9090/graph?g0.expr=llm_d_epp_flow_control_queue_size'

  Tear down:
    make sim-local-down       # or: kind delete cluster --name ${CLUSTER}

EOF
