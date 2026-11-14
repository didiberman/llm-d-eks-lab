#!/usr/bin/env bash
# Delete the local GitOps kind cluster (`make argocd-local-down`).
set -euo pipefail
kind delete cluster --name llm-d-argocd
