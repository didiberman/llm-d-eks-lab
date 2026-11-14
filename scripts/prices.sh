#!/usr/bin/env bash
# Re-measure spot prices for the instance types this project uses.
#
# Every cost figure in README.md and docs/COSTS.md came from this script. Spot
# prices move; re-run it rather than trusting the committed numbers.
set -euo pipefail

REGION="${1:-us-west-2}"

# us-west-2 is the default because that is where the G/VT spot quota was
# granted. Prices differ materially by region: L40S spot is ~45% dearer in
# us-west-2 than us-east-1, but quota is the binding constraint, not price.
TYPES=(
  t3.large      # system node group / T1 simulator host
  m7i.xlarge    # T1 alternative
  g4dn.xlarge   # T4 16GB — no bf16, no FP8
  g6.xlarge     # L4 22GB — the cheap iteration tier
  g5.xlarge     # A10G 22GB — Ampere, no FP8, avoid
  g6e.xlarge    # L40S 44GB — T2 default, 4 vCPU so two fit in an 8 vCPU quota
  g6e.2xlarge   # L40S 44GB — 8 vCPU, one GPU: burns the whole quota on one node
  g6e.12xlarge  # 4x L40S 178GB — needs 48 vCPU, out of reach at 8
  g6e.24xlarge  # 4x L40S 178GB — needs 96 vCPU; cheaper than 12xlarge, see COSTS.md
  m7i.16xlarge  # what the shipped CPU overlay needs, x2
)

START=$(date -u -v-3H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%S)

printf '%-16s %-6s %-12s %s\n' "INSTANCE" "vCPU" "SPOT/hr" "GPU"
printf '%-16s %-6s %-12s %s\n' "----------------" "------" "------------" "---"

for it in "${TYPES[@]}"; do
  spot=$(aws ec2 describe-spot-price-history \
    --region "$REGION" --instance-types "$it" \
    --product-descriptions "Linux/UNIX" --start-time "$START" \
    --query 'min_by(SpotPriceHistory,&to_number(SpotPrice)).SpotPrice' \
    --output text 2>/dev/null || echo "n/a")

  read -r vcpu gpu <<<"$(aws ec2 describe-instance-types \
    --region "$REGION" --instance-types "$it" \
    --query 'InstanceTypes[0].[VCpuInfo.DefaultVCpus,GpuInfo.Gpus[0].Name]' \
    --output text 2>/dev/null || echo "? ?")"

  printf '%-16s %-6s %-12s %s\n' "$it" "$vcpu" "\$${spot}" "${gpu:-none}"
done

echo
echo "EKS control plane is a flat \$0.10/hr per cluster on top of the above."
echo "NLB is ~\$0.0225/hr + LCUs. This project runs no NAT Gateway (\$0.045/hr each)."
