#!/usr/bin/env bash
# Tear down the T0 kind cluster. Costs nothing either way, but leaving it
# running holds a few GB of RAM and Docker containers.
set -euo pipefail
CLUSTER=llm-d-eks-lab

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
  echo "T0 cluster deleted."
else
  echo "No kind cluster named '$CLUSTER'."
fi
