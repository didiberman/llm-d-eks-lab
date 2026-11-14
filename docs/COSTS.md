# Cost model

Every number here was measured, not estimated. Re-measure with `make prices`.

- **Region:** `us-west-2` — this is where the GPU quota was granted
- **Sampled:** 2026-10-29, 6-hour spot price window
- **Method:** `aws ec2 describe-spot-price-history`, minimum across AZs

## The actual constraint: 8 vCPU of spot

Everything in this document is downstream of one number.

| Quota | Requested | **Granted** |
|-------|-----------|-------------|
| `L-3819A6DF` — G/VT **Spot** | 32 | **8 vCPU** ✅ |
| `L-DB2E81BA` — G/VT On-Demand | 8 | **0 vCPU** ❌ |

Eight vCPUs of spot, and **no on-demand fallback at all**. Since a GPU
`xlarge` is 4 vCPU, that is **exactly two single-GPU nodes** — and because the
smallest multi-GPU G shape is 48 vCPU, multi-GPU is simply unavailable.

Three consequences that shape the whole project:

1. **Max 2 replicas.** The autoscaling demo is 1→2. That is the minimum that
   proves the mechanism, and it is enough.
2. **Max 44 GB VRAM per replica** (one L40S). No tensor parallelism, so no
   model larger than ~35 GB of weights.
3. **Spot-only.** If spot capacity is unavailable there is no on-demand
   fallback, and nothing launches. The Karpenter NodePool therefore spreads
   across all four us-west-2 AZs to maximise the odds.

### What 8 vCPU buys

| Shape | vCPU | GPU | VRAM | $/hr | Nodes @ 8 vCPU | Both nodes $/hr |
|-------|------|-----|------|------|----------------|-----------------|
| **`g6e.xlarge`** | 4 | **L40S** | **44 GB** | 1.8475 | **2** | **3.695** |
| `g6.xlarge` | 4 | L4 | 22 GB | 0.4330 | **2** | 0.866 |
| `g5.xlarge` | 4 | A10G | 22 GB | 0.5601 | 2 | 1.120 |
| `g4dn.xlarge` | 4 | T4 | 16 GB | 0.2540 | 2 | 0.508 |
| `g6e.2xlarge` | 8 | L40S | 44 GB | 2.2421 | 1 | 2.242 |
| `g6.2xlarge` | 8 | L4 | 22 GB | 0.4385 | 1 | 0.439 |

The `2xlarge` rows are traps: they cost the entire quota for **one** GPU, which
kills the autoscaling demo. Always prefer two `xlarge` nodes over one
`2xlarge`.

> **Note on region pricing.** `g6e.xlarge` spot is **$1.8475** in us-west-2
> versus **$1.2728** in us-east-1 — 45% dearer. Quota is where it is, so that
> is the price. If the remaining quota ever lands in us-east-1 instead, revisit.

## vCPU quota vs. GPUs: not a fixed ratio

The G/VT quota (`L-3819A6DF`) counts **vCPUs**, but what you need is **GPUs**,
and the conversion rate swings from 4 to 64 depending on shape:

| shape | vCPU | GPUs | VRAM | host RAM | vCPU/GPU |
|-------|------|------|------|----------|----------|
| `g6e.xlarge` | 4 | 1 | 44 GB | 32 GB | 4 |
| `g6e.2xlarge` | 8 | 1 | 44 GB | 64 GB | 8 |
| `g6e.4xlarge` | 16 | 1 | 44 GB | 128 GB | 16 |
| `g6e.8xlarge` | 32 | 1 | 44 GB | 256 GB | 32 |
| `g6e.12xlarge` | 48 | **4** | 178 GB | 384 GB | 12 |
| `g6e.16xlarge` | 64 | **1** | 44 GB | 512 GB | 64 |
| `g6e.24xlarge` | 96 | **4** | 178 GB | 768 GB | 24 |
| `g6e.48xlarge` | 192 | **8** | 357 GB | 1536 GB | 24 |

Two traps:

**The ladder is non-monotonic.** `12xlarge` (48 vCPU) has four GPUs;
`16xlarge` (64 vCPU) has one. Everything from `xlarge` to `16xlarge` is the
same single L40S with more CPU bolted on. Sizing up by instance name can buy
you *fewer* GPUs for more quota.

**48 vCPU is the threshold that matters.** Below it you can hold many GPUs
(32 vCPU = eight `g6e.xlarge`) but never more than one per node, so model size
is hard-capped at 44 GB regardless of quota. At 48 you unlock 4-GPU nodes,
178 GB, and tensor parallelism.

vLLM is GPU-bound and needs only ~4-8 vCPU per GPU for text, so the CPU in the
larger shapes is mostly along for the ride. Two caveats: every Qwen3.5+ model is
multimodal and image/video preprocessing *is* CPU-hungry, and host RAM scales
with vCPU — `g6e.xlarge`'s 32 GB is tight against 28.7 GB of weights plus
download and page cache.

## Multi-GPU shape pricing is region-specific — and it inverts

Worth recording as a lesson rather than a rule. The same four L40S GPUs, priced
on the same day in two regions:

| Shape | vCPU | GPUs | VRAM | **us-east-1** | **us-west-2** |
|-------|------|------|------|---------------|---------------|
| `g6e.12xlarge` | 48 | 4× L40S | 178 GB | 7.716 | **9.973** |
| `g6e.24xlarge` | 96 | 4× L40S | 178 GB | **4.051** | 15.066 |

In us-east-1 the `24xlarge` is **47% cheaper** than the `12xlarge` for identical
GPUs. In us-west-2 it is **51% dearer**. An earlier version of this file called
the 24xlarge "strictly the better buy" — that was true only in us-east-1, and
is wrong in the region the quota actually landed in.

Spot pricing is set per instance type per region by supply and demand. There is
no transferable rule here beyond: **measure both shapes in your own region
before committing.** `make prices` now covers all four.

None of this is actionable at 8 vCPU of quota — every shape in this table needs
48 or 96 — but it determines which to request if a larger ask is ever filed.

## Measured spot prices

All **us-west-2**, sampled 2026-10-29. ✅ = reachable with the granted 8 vCPU.

| Instance | vCPU | GPU | VRAM | Spot $/hr | Reachable | Role |
|----------|------|-----|------|-----------|-----------|------|
| `t3.large` | 2 | — | — | **0.0310** | ✅ | system nodes / T1 sim host |
| `m7i.xlarge` | 4 | — | — | 0.0919 | ✅ | T1 alternative |
| `g4dn.xlarge` | 4 | T4 | 16 GB | 0.2540 | ✅ | **no bf16, no FP8** — avoid |
| **`g6.xlarge`** | 4 | **L4** | **22 GB** | **0.4330** | ✅ | **T2 cheap tier** |
| `g5.xlarge` | 4 | A10G | 22 GB | 0.5601 | ✅ | **Ampere, no FP8** — avoid |
| `m7i.16xlarge` | 64 | — | — | 1.2727 | n/a | what the CPU overlay needs, ×2 |
| **`g6e.xlarge`** | 4 | **L40S** | **44 GB** | **1.8475** | ✅ | **T3 default** ⭐ |
| `g6e.2xlarge` | 8 | L40S | 44 GB | 2.2421 | ⚠️ | 1 node only — kills autoscaling |
| `g6.48xlarge` | 192 | 8× L4 | 178 GB | 4.4907 | ❌ | needs 192 vCPU |
| `g6e.12xlarge` | 48 | 4× L40S | 178 GB | 9.9732 | ❌ | needs 48 vCPU |
| `g6e.24xlarge` | 96 | 4× L40S | 178 GB | 15.0656 | ❌ | needs 96 vCPU |
| `g6e.48xlarge` | 192 | 8× L40S | 357 GB | 23.4646 | ❌ | needs 192 vCPU |

Fixed costs on top: **EKS control plane $0.10/hr** per cluster, **NLB ~$0.0225/hr**
plus LCUs. This project runs **no NAT Gateway** — see below.

### GPU choice

**Ada Lovelace or nothing.** L4 (`g6`) and L40S (`g6e`) have native FP8; A10G
(`g5`) is Ampere and does not. Since every model worth serving here ships an FP8
checkpoint, FP8 support halves the weight footprint and `g5` is ruled out
regardless of price. `g4dn` (T4) additionally lacks bf16 and FlashAttention-2,
so vLLM falls back to slower kernels — cheaper per hour, materially worse
tokens/sec.

## Model → GPU fit

Weights from HuggingFace safetensors metadata. Budget is
`weights + ~2GB activations/CUDA graphs + KV cache`, and KV headroom is what
decides how many concurrent sequences a replica holds before queueing starts —
i.e. the signal KEDA scales on.

Only the first two columns are reachable at 8 vCPU — the 178 GB column needs
48+ vCPU and is kept for reference.

| Model | Params | Weights | KV on L4 22GB ✅ | KV on L40S 44GB ✅ | 4× L40S 178GB ❌ |
|-------|--------|---------|------------------|--------------------|------------------|
| **`Qwen/Qwen3.5-4B`** | 4.7B | 8.7 GB | **~11 GB** ⭐T2 | ~33 GB | plenty |
| `Qwen/Qwen3-8B` *(text-only)* | 8.2B | 15.3 GB | ~5 GB | ~27 GB | plenty |
| `Qwen/Qwen3.5-9B` | 9.7B | 18.0 GB | ✗ | ~24 GB | plenty |
| **`Qwen/Qwen3.6-27B-FP8`** | 27.8B | 28.7 GB | ✗ | **~13 GB** ⭐T3 | plenty |
| `Qwen/Qwen3.6-35B-A3B-FP8` | 36.0B MoE | 34.9 GB | ✗ | ~7 GB | plenty |
| `Qwen/Qwen3.5-122B-A10B-FP8` | 125B (10B active) | 116 GB | ✗ | ✗ | ~60 GB |
| `Qwen/Qwen3.5-122B-A10B` BF16 | 125B | 233 GB | ✗ | ✗ | ✗ |

**Ceiling at 8 vCPU: ~35 GB of weights**, i.e. one L40S. `Qwen3.6-27B-FP8` is
the largest model that leaves usable KV headroom, which makes it the default.
`Qwen3.6-35B-A3B-FP8` technically fits but at ~7 GB of KV a replica holds only
two or three concurrent sequences — a degenerate autoscaling demo.

Everything in the Qwen3.5/3.6/3.8 line is **natively multimodal** (image +
video preprocessors). `Qwen3-8B` is the only text-only option listed.

vLLM 0.30 — the engine llm-d v1.0.0 pins — registers
`Qwen3_5ForConditionalGeneration` and `Qwen3_5MoeForConditionalGeneration`.
Verified against the v0.30.0 model registry, not assumed.

**Caveat on 4× L40S:** L40S has no NVLink, so multi-GPU on `g6e` is PCIe-only.
Tensor parallelism across 4 GPUs for a 122B MoE carries real communication
overhead. It works; it is not p5-with-NVSwitch fast. Worth measuring.

## Per-tier hourly cost

**Base cost whenever the cluster exists**, regardless of GPUs:

| Component | $/hr |
|-----------|------|
| EKS control plane | 0.100 |
| 2× `t3.large` spot system nodes | 0.062 |
| NLB | 0.023 |
| **base total** | **0.185** |

An earlier version of this file claimed idle was $0.10/hr. That was wrong — it
ignored the system node group and the load balancer. Real idle, with GPU nodes
consolidated to zero, is **$0.185/hr**.

| Tier | GPU config | Model | $/hr (1 rep) | $/hr (2 reps) |
|------|-----------|-------|--------------|---------------|
| **T0** `sim-local` | none, kind on laptop | simulator | **0.00** | 0.00 |
| **T1** `sim-eks` | none | simulator | **0.19** | 0.19 |
| **T2** `gpu-small` | `g6.xlarge` L4 22 GB | `Qwen3.5-4B` | **0.62** | **1.05** |
| **T3** `gpu` ⭐ | `g6e.xlarge` L40S 44 GB | `Qwen3.6-27B-FP8` | **2.03** | **3.88** |
| idle, cluster up | 0 GPU nodes | — | **0.185** | — |
| idle, nuked | nothing | — | **0.00** | — |

### The 2-hour test, against a $30 ceiling

T3, the real target:

| Scenario | Cost |
|----------|------|
| 1 replica for 2h, scaling to 2 for 30 min | **$4.99** |
| 2 replicas for the full 2h | **$7.76** |
| Same at T2 (`gpu-small`) | $1.73 |

**Well inside $30** — roughly a sixth of it. The granted quota turns out to be
the binding constraint rather than the budget, which means there is no reason
to run anything smaller than T3 for the real measurements.

### Parked until more quota lands

`Qwen3.5-122B-A10B-FP8` on 4× L40S (178 GB) needs **96 vCPU** — twelve times
what was granted. The `g6e.24xlarge` analysis below is kept because the spot
anomaly is worth knowing if the remaining 24 vCPU of the original 32 request is
ever approved, or if a larger ask is filed later.

## Why no CPU-vLLM tier

llm-d ships `guides/optimized-baseline/modelserver/cpu/vllm`. Its
`patch-vllm.yaml` requests `cpu: "64"`, `memory: 64Gi`, `replicas: 2`, serving
gated `meta-llama/Llama-3.2-3B-Instruct`.

| | vCPU | Spot $/hr |
|---|------|-----------|
| 2 × `m7i.16xlarge` (what that overlay needs) | **128** | **1.371** |
| 1 × `g6e.xlarge` | 4 | **1.273** |

Slightly *more* than a single L40S that is vastly more capable — and the real
blocker isn't price: 128 vCPU is **four times** the default 32-vCPU standard
instance quota on a new account, so the overlay cannot launch at all without a
second, separate quota increase.

Shrinking it (1 replica, 4 vCPU, a 1.5B model) is possible but yields single-digit
tokens/sec, which demonstrates nothing you couldn't learn for free. The simulator
is the better trade: it speaks the vLLM OpenAI API and emits genuine vLLM
Prometheus metrics, so the KEDA ScaledObject and all scaling behaviour are
exercised identically — at $0.00 on kind.

**Conclusion: for this workload the GPU is the cheap path.** Reserve GPU spend for
the only question a GPU uniquely answers — tokens per second.

## Where the money actually leaks

Ranked by what they'd cost over a month if left alone:

| Leak | Idle cost | Mitigation |
|------|-----------|------------|
| Forgotten `g6e.24xlarge` spot | **~$2,950/mo** | nightly reaper + budget alarm |
| Forgotten `g6e.xlarge` spot | ~$930/mo | nightly reaper + budget alarm |
| EKS control plane | $73/mo | `make nuke`; reaper |
| **NAT Gateway** × 3 AZ | **$98/mo** | **none created** — public subnets + IGW |
| NLB | $16/mo | destroyed with layer 20 |
| NAT data processing | $0.045/GB | n/a — no NAT |

### The NAT Gateway trap

`terraform-aws-modules/vpc` with `enable_nat_gateway = true` and
`one_nat_gateway_per_az = true` creates three NAT Gateways at $0.045/hr each.
Worse, it bills **$0.045 per GB processed**, and an LLM workload pulls a ~10GB
vLLM image plus 3–15GB of model weights **on every cold pod start**. Ten cold
starts of a 7B model is ~$7 in data processing alone — more than the GPU time
that motivated it.

This repo puts nodes in **public subnets with public IPs**, egressing straight
out the IGW where ingress is free. Only the **S3 gateway endpoint** is created,
because gateway endpoints have no hourly or per-GB charge.

There are deliberately **no ECR or STS interface endpoints**. Those bill
$0.01/hr per AZ per endpoint — $0.18/hr for two across three AZs, which is
*worse than the NAT Gateway this whole design exists to avoid* — and they buy
nothing when the nodes already have a direct route out. Verify no NAT ever
appears:

```sh
make whats-running   # the NAT gateway line must stay empty
```

## To be measured

Numbers that need a real run; this file gets updated as they land.

- [ ] Cold start 0→1: node provision → pod Ready → first token
- [ ] Warm scale 1→2 under load, and KEDA reaction lag from queue depth
- [ ] Tokens/sec on `g6e.xlarge` (27B) and `g6e.24xlarge` (122B, TP=4)
- [ ] Whether `g6e.xlarge`'s 32GB host RAM is enough to load 28.7GB of weights
- [ ] PCIe (no NVLink) tensor-parallel overhead on 4× L40S
- [ ] $/1M tokens at steady state
- [ ] Spot interruption frequency over a session
- [ ] Actual `make cost` total for a full practice session
