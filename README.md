# llm-d on EKS — request-autoscaled LLM inference you can afford to practice on

A learning project: [llm-d](https://llm-d.ai) **v1.0.0** serving an open-weights model on
EKS, autoscaling on **inference queue depth** (not CPU), with GPU nodes that
scale to zero when idle. Terraform, start to finish.

The design goal is not "production grade." It is **a practice session that costs
a few dollars** — a real 28-billion-parameter model for about $5 a session — with hard
guardrails so a forgotten GPU can't bill you for a week.

> **New to this?** Read [How this works, from scratch](#how-this-works-from-scratch)
> first — it explains every piece in plain language, no Kubernetes or ML
> background assumed.
>
> **Status:** deployed through CI — see [Deploying (CI only)](#deploying-ci-only).

---

## How this works, from scratch

*If you've never deployed an LLM or touched Kubernetes, start here. If you have,
skip to [Architecture](#architecture).*

### What we're building

A web service you send a question to and get an AI-generated answer back from —
the same shape of thing as the OpenAI API, except it runs on hardware you rent
by the hour, and **it switches itself off when nobody is using it.**

Three properties make it worth building:

1. It serves a **real** open-weights model (27.8 billion parameters), not a toy.
2. It **adds GPUs automatically** when requests pile up, and gives them back when traffic stops.
3. Idle costs **$0.185/hour**, and **$0.00** once torn down.

### Why a GPU at all?

A language model is a very large pile of numbers called *weights*. To produce
one word of output, the computer multiplies your input through all of them. For
a 27-billion-parameter model that's tens of billions of multiplications **per
word**.

A CPU does a few dozen multiplications at once. A GPU does thousands. That's
the whole reason GPUs are involved — roughly a 100× difference on this
particular kind of arithmetic.

The catch: **the weights have to fit in the GPU's own memory** (VRAM), which is
separate from and much smaller than normal RAM. This single number decides
which models you can run at all:

> **Rule of thumb: ~1 byte of VRAM per parameter** for an FP8 model (and ~2
> bytes for a BF16 one). So a 27B model needs ~28 GB, and a 125B model needs
> ~116 GB. Plus headroom — see [KV cache](#the-kv-cache-and-why-it-decides-everything) below.

An `L40S` GPU has 44 GB of usable VRAM, which is what this project runs on.
Four of them would give 178 GB — but AWS caps how much GPU you may rent via a
*quota*, and ours allows **two single-GPU machines and no more**, so 44 GB per
model is the hard ceiling here. See [the cost model](#the-cost-model-measured).

### The pieces, in plain language

| Thing | What it actually is | Why it's here |
|-------|---------------------|---------------|
| **the model** (`Qwen3.6-27B-FP8`) | A few dozen GB of numbers, free to download from HuggingFace | Does the actual thinking |
| **vLLM** | A program that loads those numbers and answers HTTP requests | The inference engine |
| **Kubernetes (k8s)** | Software that runs programs across a fleet of machines and restarts them when they die | Manages however many copies of vLLM we need |
| **EKS** | Amazon's hosted Kubernetes — AWS runs the coordinating "brain", you supply the machines | So we don't babysit a control plane |
| **a pod** | Kubernetes' word for one running copy of a program | One pod = one vLLM = one GPU, here |
| **llm-d** | A smart router sitting in front of several vLLM pods | Picks the least-busy pod, and prefers one that already has your conversation cached |
| **EPP** (endpoint picker) | The part of llm-d that does that picking | Where the "which pod?" decision lives |
| **KEDA** | Watches a number and asks Kubernetes for more pods when it rises | Decides **how many** pods |
| **Karpenter** | Notices pods with nowhere to run, buys matching machines from AWS, and **gives them back when empty** | The thing that makes idle cost collapse to zero |
| **Istio + Gateway API** | The front door — gives the cluster a public URL | Turns a cluster into a web service |
| **Terraform** | Describes all of the above as text files | `make gpu` instead of 50 clicks in a web console |
| **spot instances** | AWS machines at a steep discount, which AWS may reclaim with 2 minutes' notice | The discount that makes this affordable at all |

Two of those do jobs that sound identical but aren't, and confusing them is the
single most common source of bewilderment here:

- **KEDA decides *how many* pods** should exist.
- **EPP decides *which* existing pod** gets a given request.
- **Karpenter decides *how many machines* are needed to hold those pods.**

### What actually happens when you run `make gpu`

```
  you type: make gpu
      │
      ├─ Terraform creates the network and the EKS cluster      (~16 min, $0.185/hr starts)
      │  and installs Karpenter, Istio and KEDA on it
      │
      ├─ Terraform installs the llm-d router and tells
      │  Kubernetes "I want 1 copy of vLLM with a GPU"          (~4 min)
      │
      ├─ Kubernetes: "no machine here has a GPU." The pod
      │  sits in Pending — nothing can run it
      │
      ├─ Karpenter notices the stuck pod, reads what it asked
      │  for, and buys a matching spot GPU machine from AWS     (~60-90s)
      │
      ├─ The new machine downloads vLLM (~10 GB) and the
      │  model weights (~28 GB), then loads them into VRAM      (~2-4 min)
      │
      ├─ vLLM reports ready → EPP adds it to the pool →
      │  the load balancer marks it healthy
      │
      └─ you can now curl a public URL and get tokens back
```

That full cold start is **2–5 minutes**. Then:

```
  you type: make load          # fires synthetic traffic at it
      │
      ├─ requests start queueing up inside vLLM
      ├─ KEDA sees the queue growing → asks for a 2nd pod
      ├─ that pod is unschedulable → Karpenter buys a 2nd machine
      └─ ~2 min later you're serving on 2 GPUs (the quota ceiling)

  traffic stops
      │
      ├─ queue empties → KEDA scales back to 1 (or 0) pods
      ├─ machines are now empty → Karpenter terminates them  (~1 min)
      └─ back to $0.185/hr with the cluster still alive and ready
```

And at the end: `make down` removes the GPU layer; `make nuke` removes
everything and puts you back to **$0.00/hr**.

> ### Want to watch all of that for free first?
>
> `make sim-local` runs the **entire** stack — router, EPP, KEDA, Prometheus,
> the ScaledObject — on a local kind cluster against
> [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim), which
> speaks the vLLM OpenAI API and emits genuine vLLM Prometheus metrics. The
> autoscaling behaves exactly as it does on GPUs. **Cost: $0.00.**
>
> The only thing T0 can't exercise is Karpenter, since it provisions real EC2.

### The one genuinely clever bit: scale on queue depth, not CPU

Ordinary web autoscaling says *"CPU is at 80%, add servers."* **That does not
work for LLMs.**

A GPU doing inference sits near 100% utilisation whether it is comfortably
keeping up or hopelessly backlogged. The number looks identical in both cases,
so it cannot tell you whether to add capacity.

What *does* distinguish them is **how many requests are waiting in line.** vLLM
publishes exactly that (`vllm:num_requests_waiting`): zero waiting means you're
keeping up; twenty waiting means add capacity now. That queue depth is the
signal KEDA watches, and it's the reason this project exists rather than being
a five-line Helm install.

### The KV cache, and why it decides everything

When a model generates text it keeps notes on everything said so far, in VRAM.
Those notes are the **KV cache**, and each simultaneous conversation needs its
own.

So your VRAM splits two ways:

```
 ┌──────────────── 44 GB L40S ────────────────┐
 │  model weights 28.7 GB │ KV cache ~13 GB   │
 └────────────────────────┴───────────────────┘
          fixed cost            how many users
                                you can serve at once
```

Pick a model too big for the card and the KV cache gets squeezed, so only two
or three people can be served at once and everyone else queues. That's why
[`docs/COSTS.md`](docs/COSTS.md) tracks KV headroom for every model rather than
just asking "does it fit" — **KV headroom is what the autoscaling signal is
actually measuring.**

### Why this is cheap

Four decisions, in order of how much they save:

1. **No NAT Gateway.** The standard AWS network template quietly adds three of
   these at $0.045/hr each *plus $0.045 per GB of traffic* — and an LLM pulls
   tens of GB on every cold start. Putting machines on the public network
   instead makes downloads free. Biggest single win.
2. **Scale to zero.** Karpenter returns GPU machines when they're idle, so you
   pay for GPUs only while actually serving.
3. **Spot instances everywhere**, at 60–70% off list price.
4. **A free simulator tier.** `llm-d-inference-sim` mimics vLLM's API and
   metrics without a GPU, so you can develop and debug the entire autoscaling
   setup on your laptop for **$0** and only pay for GPUs when measuring real
   speed.

### Jargon decoder

| Term | Meaning |
|------|---------|
| **VRAM** | Memory on the GPU itself. The constraint that decides which models fit. |
| **FP8 / BF16** | How precisely each weight is stored — 1 byte vs 2. FP8 halves memory for a small quality cost. |
| **MoE** | *Mixture of Experts.* A model with many specialist sub-networks where only a few run per word. A "125B (10B active)" model needs VRAM for all 125B but is as fast as a 10B one. |
| **TP / tensor parallelism** | Splitting one model across several GPUs because it won't fit on one. |
| **quota** | AWS's cap on what you may launch. Starts at **zero** for GPUs and must be requested — usually the thing that blocks you, not money. |
| **IGW** | Internet Gateway. The free way out of an AWS network (as opposed to the paid NAT Gateway). |
| **NLB** | Network Load Balancer. The public entry point AWS creates for the cluster. |
| **CRD** | A way to teach Kubernetes new object types — how llm-d and Gateway API extend it. |
| **IRSA / Pod Identity** | How a program in Kubernetes proves to AWS that it's allowed to do something (e.g. Karpenter buying machines). |

---

## The cost model, measured

All prices are `us-east-1` **spot**, sampled 2026-10-28 via `describe-spot-price-history`.
Re-measure with `make prices` — they move.

Sized to the GPU quota actually granted: **8 vCPU of G/VT spot in `us-west-2`,
and zero on-demand.** A GPU `xlarge` is 4 vCPU, so that is exactly **two
single-GPU nodes** — and since the smallest multi-GPU shape is 48 vCPU,
multi-GPU is out of reach. The autoscaling demo is therefore **1→2 replicas**,
which is the minimum that proves the mechanism.

| Tier | What runs | GPU | 1 rep | 2 reps | What it proves |
|------|-----------|-----|-------|--------|----------------|
| **T0** `make sim-local` | kind on your laptop + `llm-d-inference-sim` | no | **$0.00** | — | router, EPP, KEDA ScaledObject, scaling behaviour, every line of YAML |
| **T1** `make sim-eks` | EKS + `llm-d-inference-sim` | no | **$0.19** | $0.19 | real EKS, Istio Gateway, NLB, Karpenter, end-to-end autoscaling |
| **T2** `make gpu-small` | 2× `g6.xlarge` (L4 22GB) + `Qwen3.5-4B` | yes | **$0.62** | **$1.05** | cheap iteration against a real GPU |
| **T3** `make gpu` ⭐ | 2× `g6e.xlarge` (L40S 44GB) + `Qwen3.6-27B-FP8` | yes | **$2.03** | **$3.88** | real tokens, real throughput, scale-out under load |

| **T4** `make kimi` | 1× `g7e.12xlarge` (2× RTX PRO 6000, 192GB) + `Kimi-Dev-72B`, on-demand | yes | **$8.47** | — | a 72B model, tensor-parallel across two GPUs; no scale-out |

T4 exists because the on-demand G/VT quota in `us-west-2` was later raised to
**64 vCPU** (spot is still 8). One 48 vCPU node fits; a second does not, so T4
is fixed at one replica. On-demand list price, sampled 2026-11-14.

**A 2-hour T3 session costs ~$5.00** (one replica throughout, scaling to two for
30 minutes), or **$7.76** with both replicas up the whole time. Against a $30
budget that's about a sixth — **quota, not money, is the binding constraint**,
so there's no reason to run below T3 for real measurements.

Idle with the cluster up but GPUs consolidated away is **$0.185/hr** (control
plane + two small system nodes + load balancer). `make nuke` takes it to $0.

> **Parked:** `Qwen3.5-122B-A10B-FP8` on 4× L40S needs **96 vCPU** — twelve
> times what was granted. See [`docs/COSTS.md`](docs/COSTS.md) for the shape
> analysis if more quota lands.

### Why there is no CPU-vLLM tier

llm-d ships a CPU model server at `guides/optimized-baseline/modelserver/cpu/vllm`.
It is a **cost trap for this use case** and deliberately not used here:

| | vCPU | VRAM | Spot cost |
|---|---|---|---|
| Shipped CPU overlay: `cpu: "64"` × 2 replicas | **128** | none | **$1.37/hr** |
| `g6e.xlarge` (L40S) | 4 | 44 GB | **$1.27/hr** |

So the CPU path costs *slightly more* than a far more capable single L40S — and
needs 128 vCPU, **four times** the default 32-vCPU account quota, so on a fresh
account it cannot launch at all. Shrinking it to fit yields single-digit
tokens/sec, which demonstrates nothing. For everything short of real token
throughput,
[`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) is strictly
better: it speaks the vLLM OpenAI API and emits real vLLM Prometheus metrics, so
**KEDA scales against it exactly as it would against the real thing** — for
$0.022/hr on a `t3.large`, or free on kind.

Spend GPU money on the one thing only a GPU proves: tokens per second.

### Where the money actually leaks

The GPU is not the problem. These are:

| Leak | Naive cost | Here |
|------|-----------|------|
| **NAT Gateway** (3 AZ × $0.045/hr) | $0.135/hr | **$0** — no NAT; public subnets + IGW |
| **NAT data processing** — a ~10GB vLLM image and 3–15GB of weights, *per pod start* | ~$0.045/GB | **$0** |
| EKS control plane, left running | $73/mo | `make nuke` → $0; nightly reaper enforces it |
| Forgotten GPU node | ~$340/mo | reaper + budget alarm |

Dropping NAT Gateway is the single largest line-item win, and it is why this repo
does **not** use the stock `terraform-aws-modules/vpc` defaults.

---

## Architecture

```
                    Internet
                       │
              NLB (Istio Gateway)
                       │
         ┌─────────────▼─────────────┐
         │   llm-d Router v1.0.0     │   standalone mode
         │   + Endpoint Picker (EPP) │   prefix-cache & load aware routing
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │  vLLM 0.30 model servers  │  ← KEDA scales replicas on
         │  (or llm-d-inference-sim) │    EPP queue-depth metric
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │ Karpenter NodePool        │  ← provisions g6e spot;
         │ consolidation → 0 nodes   │    terminates when empty
         └───────────────────────────┘
```

**Two independent scaling layers** — conflating them is the usual source of confusion:

- **Routing** — llm-d's EPP picks *which* replica serves a request, using
  prefix-cache-aware and load-aware scoring. Does not change replica count.
- **Scaling** — KEDA drives *how many* replicas exist from EPP's queue-depth
  metric. Queue depth, **not** GPU utilisation: a saturated GPU and a comfortable
  GPU both read ~100%, so utilisation cannot tell you to scale.

Then Karpenter closes the loop — replicas at 0 means nodes are empty, and
`consolidationPolicy: WhenEmptyOrUnderutilized` reclaims them in about a minute.
Idle cost falls to $0.185/hr with the cluster still live — the $0.10 control
plane plus two small system nodes and the load balancer.

Cold start 0→1 is roughly **2–5 minutes** (node provision ~60–90s, GPU image
pull, weight load, CUDA graph capture). Driving that number down is the most
interesting engineering here; measurements go in [`docs/COSTS.md`](docs/COSTS.md).

### Pinned versions (llm-d v1.0.0 aligned)

| Component | Version |
|-----------|---------|
| llm-d router (`oci://ghcr.io/llm-d/charts/llm-d-router-standalone`) | `v1.0.0` |
| `llm-d-router-endpoint-picker` | `v1.0.0` |
| `llm-d-inference-sim` | `v1.0.0` |
| Gateway API CRDs | `v1.6.2` |
| Gateway API Inference Extension (GAIE) CRDs | `v1.6.2` |
| Istio (gateway provider) | `1.29.4` |
| vLLM base image | `docker.io/vllm/vllm-openai:v0.30.0` |
| LeaderWorkerSet | `1.0.0` |

llm-d v1.0 **removed kgateway**; Istio is the best-tested provider. Istio's
Gateway API implementation provisions a Service of type LoadBalancer, which on
EKS is an **NLB** — not an ALB. Same $0.0225/hr, and a better fit for streaming
token responses.

---

## Layout

```
terraform/
  00-bootstrap/     S3 remote state + GitHub OIDC reaper role    once,    ~$0
  10-cluster/       VPC (no NAT), EKS 1.37, Karpenter, KEDA,      ~16 min, $0.185/hr
                    Prometheus, budget alarm
  20-inference/     Karpenter NodePool, llm-d router, vLLM,       ~4 min,  GPU cost
                    KEDA ScaledObject
    tiers/*.tfvars  sim | small | gpu — the only difference between tiers
manifests/
  router/           llm-d router values (shared by every tier)
  sim/              simulator modelserver + ScaledObject + NodePort
local/              kind config + up.sh / down.sh for the $0 tier
loadgen/            k6 ramp script
.github/workflows/  validate (static checks) + reaper (nightly destroy)
```

The 10/20 split exists because **you will iterate on 20 about thirty times and on
10 maybe twice**. One state file means every vLLM config typo costs a 16-minute
cluster rebuild.

## Deploying (CI only)

Every deploy runs in GitHub Actions (`.github/workflows/deploy.yml`) under an
OIDC role — nothing is applied from a workstation. The running tier is
declared in [`deploy/tier`](deploy/tier):

```bash
echo kimi > deploy/tier && git commit -am "Run Kimi" && git push   # deploy
make deploy TIER=sim                                               # one-off override, no commit
```

On push, the workflow plans only the layers whose files changed
(`terraform/10-cluster/**` → cluster, `terraform/20-inference/**`,
`manifests/router/**`, `deploy/**` → inference) and applies only when the plan
is non-empty. Docs and README pushes never deploy. After an apply it smoke-tests
a completion through the router. The nightly reaper shares its concurrency group,
so a teardown never races a deploy.

The local `make cluster` / `make gpu` / `make kimi` targets refuse to run
without `ALLOW_LOCAL=1` (break-glass). `make down` and `make nuke` still work
locally as an emergency stop. `00-bootstrap` is the one layer applied by hand,
because it creates the role CI assumes.

## Commands

```
make deploy         # run the deploy workflow in CI (TIER=... to override deploy/tier)
make sim-local      # T0: kind + simulator on your laptop, $0
make sim-eks        # T1: EKS + simulator, no GPU
make gpu-small      # T2: Qwen3.5-4B on g6.xlarge (L4), cheap iteration
make gpu            # T3: Qwen3.6-27B-FP8 on g6e.xlarge (L40S)  <- the real one
make kimi           # T4: Kimi-Dev-72B on g7e.12xlarge (2x 96GB), on-demand, 1 replica

make load           # fire k6 at the endpoint, watch replicas climb
make watch          # live view of ScaledObject, HPA, pods and nodes

make down           # destroy layer 20 → GPU gone, cluster warm ($0.185/hr)
make nuke           # destroy everything → $0.00/hr, then proves it

make preflight-gpu  # is the GPU quota enough? (checked automatically by `make gpu`)
make quota          # GPU quota + what it buys + pending requests
make cost           # actual spend to date, from Cost Explorer
make prices         # re-measure spot prices
make whats-running  # anything currently billing, incl. a NAT-gateway check
make validate       # fmt + validate every layer
```

Default end-of-session habit is `make nuke`. `make down` is for coming back in an hour.

## Guardrails

- **Nightly reaper** — scheduled GitHub Actions workflow destroys the GPU layer
  every night via OIDC, regardless of state. The highest-value protection here.
- **AWS Budget + SNS email** at a threshold you set in `terraform.tfvars`.
- **Mandatory tagging** — every resource carries `Project=llm-d-eks-lab`, which is
  what makes `make cost` able to tell you the truth.

## Prerequisites

- Terraform ≥ 1.13, `kubectl`, `helm` ≥ 3.10, `aws` CLI v2
- `kind` + Docker for T0; `k6` for `make load` (falls back to a container)
- An AWS account with **G/VT spot quota** (`L-3819A6DF`) in `us-west-2`. This
  defaults to **0** on new accounts and is denominated in **vCPUs, not
  instances** — a limit of 3 launches nothing at all, since the smallest GPU
  node is 4 vCPU. This project is built against a granted **8 vCPU**:

  | Quota | vCPU | Gets you |
  |-------|------|----------|
  | 8 (granted) | 4 per node | 2× single-GPU nodes, 44 GB each |
  | 48 | 48 per node | first 4-GPU node, 178 GB, tensor parallelism |
  | 96 | 96 per node | `g6e.24xlarge`, same 4 GPUs, different price |

  Check yours with `make quota`, which also prints how many nodes the current
  limit buys.
- A HuggingFace token in `TF_VAR_hf_token`. Required even for ungated models —
  the llm-d charts expect the `llm-d-hf-token` secret to exist.

## Before your first apply

Everything validates, but **nothing has been applied to AWS yet**. `terraform
validate` checks syntax and types; it cannot tell you AWS will accept the plan.
Expect the first apply to surface something — that's normal.

Pre-flight checks already done for you:

| Check | Result |
|-------|--------|
| All three layers `terraform validate` | ✅ |
| `terraform fmt` clean | ✅ |
| Gateway API v1.6.2 + GAIE v1.6.2 CRD URLs resolve | ✅ |
| Charts resolve: istio 1.29.4, keda 2.21.0, karpenter 1.15.1, kube-prometheus-stack 92.16.0, llm-d-router-standalone v1.0.0 | ✅ |
| llm-d router chart renders with this repo's values | ✅ |
| Router contracts verified by rendering, not assumed (pool label, port 8000, LB selector) | ✅ |
| Simulator CLI flags checked against upstream docs | ✅ |
| GPU quota sufficient (8 vCPU = 2 nodes) | ✅ |

Recommended order:

```bash
make sim-local            # 1. free. Prove the whole stack works locally.
make bootstrap            # 2. ~30s. S3 state bucket.
make cluster              # 3. ~16 min. $0.185/hr starts here.
make sim-eks              # 4. ~4 min. Real EKS + Karpenter, still no GPU.
make gpu                  # 5. the real thing. ~$2/hr.
make load                 # 6. watch it scale 1 -> 2.
make nuke                 # 7. back to $0.00/hr.
```

### Turn the reaper on before you run a GPU tier

The nightly reaper is the guardrail that stops a forgotten GPU billing for a
week. It no-ops safely until configured:

```bash
# in terraform/00-bootstrap/terraform.tfvars
github_repo = "didiberman/llm-d-eks-lab"
```

then set the repo secret `AWS_REAPER_ROLE_ARN` (from the
`github_reaper_role_arn` output) and the repo variable `STATE_BUCKET`. Pass the
role ARN to `10-cluster` as `reaper_role_arn` so it gets an EKS access entry —
without that it can authenticate but not delete anything.

## Honest caveats

- **llm-d's real wins need scale.** Prefix-cache-aware routing and
  prefill/decode disaggregation pay off across many GPUs. On one `g6e.xlarge`
  serving a small model, llm-d is net overhead — you're exercising the control
  plane, not demonstrating a speedup. That's a fine reason to build it for
  learning, but don't expect flattering benchmarks.
- **Public endpoint, no auth.** The NLB is internet-facing and unauthenticated by
  default. Set `allowed_cidrs` in `terraform.tfvars` to your own IP.
- **Spot interruptions are real.** Nodes can vanish with a 2-minute warning.
  That's a feature for a learning project — it's how you find out whether your
  deployment actually tolerates it.

## License

Apache-2.0
