# llm-d on EKS — autoscaled LLM inference you can afford to practice on

A learning lab: [llm-d](https://llm-d.ai) **v1.0.0** serving open-weights models
on EKS, autoscaled on **inference queue depth** (not CPU), with GPU nodes that
appear when needed and disappear when idle. Terraform end to end, deployed
**only** through GitHub Actions with OIDC — `git push` is the deploy button.

It is not "production grade." It is a practice environment where a real 72B
model costs about **$8.70/hour** while you use it and **nothing** once it is
reaped, with guardrails so a forgotten GPU cannot bill you for a week.

```
 git push ─▶ GitHub Actions (OIDC) ─▶ Terraform ─▶ EKS
                                                   ├─ llm-d router + endpoint picker
                                                   ├─ vLLM serving the model (KEDA-scaled)
                                                   ├─ Karpenter: GPU nodes on demand
                                                   └─ Open WebUI: chat in your browser
```

> **New to LLM serving or Kubernetes?** Start with
> [How this works, from scratch](#how-this-works-from-scratch). Already know the
> pieces? Jump to [Quick start](#quick-start).

---

## Contents

- [Quick start](#quick-start)
- [Tiers](#tiers)
- [How deploys work](#how-deploys-work)
- [Using the model](#using-the-model)
- [Costs](#costs)
- [Guardrails](#guardrails)
- [How this works, from scratch](#how-this-works-from-scratch)
- [Architecture](#architecture)
- [Setting it up in your own account](#setting-it-up-in-your-own-account)
- [Layout](#layout)
- [Commands](#commands)
- [Lessons learned](#lessons-learned)
- [Honest caveats](#honest-caveats)

---

## Quick start

Assuming the one-time setup is done ([below](#setting-it-up-in-your-own-account)):

```bash
# Pick what should be running, then push. CI does the rest.
echo kimi > deploy/tier          # none | sim | small | gpu | kimi
git commit -am "Run Kimi" && git push

# Or run a tier once without committing:
make deploy TIER=sim

# Point kubectl at the cluster:
make kubeconfig

# Stop paying for GPUs (cluster stays up, ~$0.26/hr):
echo none > deploy/tier && git commit -am "Stop" && git push

# Tear down everything billable (CI, asks you to type "destroy"):
make destroy        # or Actions → destroy → Run workflow
```

The deploy run's summary page prints the model endpoint and the Open WebUI URL.

Want to see the whole stack for free first? `make sim-local` runs router, EPP,
KEDA, Prometheus and the ScaledObject on a local kind cluster against a vLLM
simulator. **$0.00.**

---

## Tiers

Every tier is the same Terraform with a different file in
`terraform/20-inference/tiers/`. Which one runs is set by
[`deploy/tier`](deploy/tier).

| Tier | Model | Hardware | Capacity | Replicas | ~$/hr while up* |
|------|-------|----------|----------|----------|------------------|
| `sim` | [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) (fake vLLM) | `c7i.large` | spot | 1–4 | 0.29 |
| `small` | `Qwen/Qwen3.5-4B` | `g6.xlarge` — 1× L4, 22 GB | spot | 1–2 | 0.79–1.32 |
| `gpu` | `Qwen/Qwen3.6-27B-FP8` | `g6e.xlarge` — 1× L40S, 44 GB | spot | 1–2 | 2.06–3.86 |
| **`kimi`** ⭐ | **`moonshotai/Kimi-Dev-72B`** | **`g7e.12xlarge` — 2× RTX PRO 6000, 192 GB** | **on-demand** | **1** | **8.68** |
| `none` | — | — | — | 0 | 0.26 (cluster only) |

\* Including the ~$0.26/hr the cluster costs whenever it exists. Spot prices move;
re-measure with `make prices`.

**Why these shapes:** the account's GPU quota in `us-west-2` is **64 vCPU
on-demand** and **8 vCPU spot** (G and VT family). Spot fits two 4-vCPU
single-GPU nodes, which is what `small` and `gpu` use to demo scale-out 1→2.
`kimi` needs a 48-vCPU node; that only fits the on-demand quota, and only once —
so it is a fixed single replica.

**About Kimi-Dev-72B:** a 72.7B coding model (Qwen2.5-72B base, MIT licence,
ungated). It ships BF16 only — 145 GB of weights, ~135 GiB in VRAM — so it runs
**tensor-parallel across two 96 GB GPUs**, leaving ~34 GiB for KV cache
(~110k tokens: three full 32k-context conversations, or many short ones). It
reasons in a `◁think▷` block before answering, so give it a generous
`max_tokens`. The larger Kimi K2/K3 models (1T+ parameters) do not fit any
single AWS G-family instance.

Measured on the first deploy:

| | |
|---|---|
| GPU node launch → Ready | ~2 min |
| Weights download (145 GB, gp3 at 1000 MB/s) | ~6 min (~370 MB/s) |
| Load + CUDA graph capture | ~4 min |
| **Cold start total** | **~12–15 min** |
| Single-request decode speed | ~18 tokens/s |

---

## How deploys work

Every deploy runs in GitHub Actions (`.github/workflows/deploy.yml`) under an
IAM role assumed via OIDC — no AWS keys are stored anywhere. Nothing is applied
from a workstation.

```
push to main
   │
   ├─ scope      which layers changed? which tier does deploy/tier ask for?
   │
   ├─ cluster    only if terraform/10-cluster/** changed
   │             plan → apply only if the plan is non-empty
   │
   └─ inference  if terraform/20-inference/**, manifests/router/** or deploy/** changed
                 plan → apply only if non-empty → smoke test a completion
```

- **Docs never deploy.** README, `docs/` and other non-infra pushes trigger
  nothing; `validate` also skips docs-only pushes.
- **No pointless applies.** Each layer is planned with `-detailed-exitcode` and
  applied only when something actually changes.
- **Smoke test.** After an apply, CI port-forwards to the router and requires a
  real completion from the served model.
- **One at a time.** Deploy and the nightly reaper share a concurrency group,
  so a teardown never races an apply for the state lock.
- **Manual runs.** `make deploy TIER=<tier>` (or the *Run workflow* button)
  overrides `deploy/tier` for a single run.

The local `make cluster`, `make gpu`, `make kimi` … targets refuse to run
without `ALLOW_LOCAL=1` (break-glass only). `make down` and `make nuke` still
work locally as an emergency stop.

---

## Using the model

**Open WebUI** — a ChatGPT-style interface on its own load balancer. Its URL is
in the deploy run's summary, or:

```bash
kubectl -n llm-d get svc open-webui-public
```

No login: it is reachable only from the IPs in `ALLOWED_CIDRS`. Chats are not
persisted (no volume), so a pod restart or the nightly reaper wipes them.

**OpenAI-compatible API** — the router's public endpoint, same IP allowlist:

```bash
EP=$(kubectl -n llm-d get svc llm-d-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$EP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "moonshotai/Kimi-Dev-72B",
  "messages": [{"role": "user", "content": "Write a palindrome checker in Python."}],
  "max_tokens": 800
}' | jq -r '.choices[0].message.content'
```

Tool calling (`tool_choice: "auto"`) is enabled on the Kimi tier with vLLM's
`hermes` parser — Open WebUI and most agent frameworks need it.

**Logs:**

```bash
kubectl -n llm-d logs -f deploy/llm-d-vllm-decode     # vLLM: download, load, requests
kubectl -n llm-d logs -f deploy/llm-d-epp -c epp      # router: which backend got each request
kubectl -n kube-system logs -f deploy/karpenter       # node launches and terminations
make watch                                            # pods, HPA, nodes at a glance
```

---

## Costs

Measured in `us-west-2`, November 2026.

**Whenever the cluster exists — ~$0.26/hr (~$6.20/day):**

| Item | $/hr |
|------|------|
| EKS control plane | 0.100 |
| 2× `t3.xlarge` spot system nodes | ~0.102 |
| Public IPv4 addresses (~6 × $0.005) | ~0.030 |
| Network Load Balancers (router + WebUI) | ~0.045 |
| System node EBS | ~0.004 |

**Added while `kimi` runs — ~$8.42/hr:** `g7e.12xlarge` on-demand $8.29, plus
the 400 GB high-throughput gp3 root volume (~$0.13). The same instance is ~$5.46
on spot, but this account's 8-vCPU spot quota cannot hold a 48-vCPU node.

| Scenario | Cost |
|----------|------|
| 2-hour Kimi session | ~$17.50 |
| Cluster idling, no GPU | ~$6.20/day |
| `make nuke` | ~$0 (S3 state only) |

**Where money leaks, and what this repo does about it:**

| Leak | Naive cost | Here |
|------|-----------|------|
| NAT Gateway (3 AZ) | $0.135/hr + $0.045/GB | **none** — public subnets + IGW; a 145 GB model download costs $0 in transfer |
| Forgotten GPU node | $200/day (Kimi) | nightly reaper + budget alert |
| EKS control plane left up | $73/month | `make nuke` |

`make cost` shows actual spend attributed by the `Project` tag. Older model/shape
analysis from the 8-vCPU-spot era lives in [`docs/COSTS.md`](docs/COSTS.md).

---

## Guardrails

- **Nightly reaper** (`.github/workflows/reaper.yml`) — destroys the inference
  layer at 03:00 UTC every night via its own OIDC role, whatever `deploy/tier`
  says. It fails loudly if any GPU instance survives. Bring the model back with
  any push to `deploy/` or `make deploy`. Run it manually with "also destroy
  cluster" for a full teardown.
- **Karpenter consolidation** — a GPU node is terminated about a minute after
  its last model pod leaves.
- **NodePool vCPU limits** match the quota, so an over-ask shows up as a
  Pending pod rather than a stream of EC2 errors.
- **Destroy on demand** (`.github/workflows/destroy.yml`) — manual workflow
  that tears down the inference layer, waits for NLBs and GPU nodes to go,
  destroys the cluster, sweeps orphaned Karpenter instances and fails if
  anything billable remains. Leaves only the S3 state bucket and OIDC roles.
  Set `deploy/tier` to `none` first, or the next infra push rebuilds it.
- **AWS Budget + email** — set the `BUDGET_ALERT_EMAIL` secret to enable.
- **IP allowlist** on both public endpoints (`ALLOWED_CIDRS`).
- **Tagging** — every resource carries `Project=llm-d-eks-lab`.

---

## How this works, from scratch

*If you've never deployed an LLM or touched Kubernetes, start here.*

### What we're building

A web service you send a question to and get an AI-generated answer from — the
same shape as the OpenAI API, except it runs on hardware you rent by the hour
and **switches itself off when nobody is using it.**

### Why a GPU at all?

A language model is a very large pile of numbers called *weights*. Producing one
word means multiplying your input through all of them — tens of billions of
multiplications per word for a large model. A CPU does a few dozen at once; a
GPU does thousands. That is the whole reason GPUs are involved.

The catch: **the weights must fit in the GPU's own memory (VRAM).** That one
number decides which models you can run:

> **Rule of thumb: ~1 byte of VRAM per parameter for FP8, ~2 for BF16.**
> A 27B FP8 model needs ~28 GB; Kimi-Dev-72B in BF16 needs ~135 GB — more than
> any single GPU here, so it is split across two.

### The pieces, in plain language

| Thing | What it actually is | Why it's here |
|-------|---------------------|---------------|
| **the model** | Tens to hundreds of GB of numbers from HuggingFace | Does the thinking |
| **vLLM** | Loads the weights onto GPUs and answers HTTP requests | The inference engine |
| **Kubernetes / EKS** | Runs programs across machines and restarts them when they die; EKS is Amazon's hosted version | Manages the copies of vLLM |
| **pod** | One running copy of a program | One pod = one vLLM server |
| **llm-d router + EPP** | A smart front door; the *endpoint picker* chooses which vLLM pod gets each request | Prefers the least busy pod, or one that already has your conversation cached |
| **KEDA** | Watches a metric and asks for more pods when it rises | Decides **how many** pods |
| **Karpenter** | Sees pods with nowhere to run, buys matching machines, returns them when empty | Makes idle GPU cost zero |
| **Open WebUI** | A chat interface | So you don't have to curl |
| **Terraform** | Describes all of the above as files | Reproducible infrastructure |
| **GitHub Actions + OIDC** | Runs Terraform on push, authenticating to AWS without stored keys | The only way anything is deployed |

Three of these sound alike but aren't:

- **KEDA** decides *how many* pods should exist.
- **EPP** decides *which* existing pod serves a request.
- **Karpenter** decides *how many machines* are needed to hold the pods.

### What happens on a deploy

```
 git push (deploy/tier = kimi)
     │
     ├─ CI assumes an AWS role via OIDC, runs terraform for the inference layer
     ├─ Kubernetes gets "1 copy of vLLM needing 2 GPUs" → no node fits → Pending
     ├─ Karpenter sees it, launches a g7e.12xlarge              (~2 min)
     ├─ vLLM pulls its image, downloads 145 GB of weights        (~6 min)
     ├─ loads them across both GPUs, captures CUDA graphs        (~4 min)
     ├─ vLLM reports healthy → the router adds it to the pool
     └─ CI smoke-tests a completion and prints the URLs
```

On the spot tiers (`small`, `gpu`), `make load` then shows the autoscaling:
requests queue → KEDA asks for a second pod → Karpenter buys a second GPU node →
traffic stops → KEDA scales back → Karpenter returns the node.

### The clever bit: scale on queue depth, not CPU

Normal autoscaling says "CPU at 80%, add servers." **That fails for LLMs:** a
GPU doing inference reads ~100% busy whether it is keeping up or drowning. What
distinguishes the two is **how many requests are waiting.** The EPP exposes that
queue depth, and that is what KEDA scales on.

### The KV cache

While generating, the model keeps notes on the conversation so far in VRAM — the
**KV cache** — and every concurrent conversation needs its own:

```
 ┌───────────────── 2 × 96 GB (Kimi tier) ─────────────────┐
 │  weights ~135 GiB (split across both)  │  KV ~34 GiB     │
 └────────────────────────────────────────┴─────────────────┘
          fixed cost                         how many people
                                             can be served at once
```

A model too big for its GPUs leaves a tiny KV cache, so only a couple of
requests run at once and the rest queue. KV headroom is what the queue-depth
signal is really measuring.

### Jargon decoder

| Term | Meaning |
|------|---------|
| **VRAM** | Memory on the GPU. Decides which models fit. |
| **FP8 / BF16** | 1 vs 2 bytes per weight. FP8 halves memory for a small quality cost. |
| **TP / tensor parallelism** | Splitting one model across several GPUs. Kimi uses TP=2. |
| **quota** | AWS's cap on what you may launch, counted in **vCPUs**. Starts at zero for GPUs. |
| **spot / on-demand** | Spot is discounted spare capacity AWS can reclaim with 2 minutes' notice; on-demand is full price and stable. |
| **OIDC** | Lets GitHub Actions prove its identity to AWS and get short-lived credentials — no stored keys. |
| **NLB** | Network Load Balancer — the public entry point for a Service. |
| **IGW / NAT** | Ways out to the internet; the IGW is free, a NAT Gateway is not. |

---

## Architecture

```
                         Internet (ALLOWED_CIDRS only)
                     │                              │
              NLB :80 (API)                  NLB :80 (Open WebUI)
                     │                              │
        ┌────────────▼─────────────┐   ┌────────────▼──────────┐
        │ llm-d router v1.0.0      │◀──│ Open WebUI            │
        │ Envoy + Endpoint Picker  │   │ (system nodes)        │
        └────────────┬─────────────┘   └───────────────────────┘
                     │  picks a backend: queue, KV-cache and prefix aware
        ┌────────────▼─────────────┐
        │ vLLM 0.30 model server   │◀── KEDA: replicas from EPP queue depth
        │ (or llm-d-inference-sim) │      (Prometheus → ScaledObject → HPA)
        └────────────┬─────────────┘
                     │
        ┌────────────▼─────────────┐
        │ Karpenter NodePool       │◀── launches GPU nodes for Pending pods,
        │ per tier, GPU-tainted    │    terminates them when empty
        └──────────────────────────┘
```

- **Standalone router mode.** The llm-d router runs its own Envoy sidecar and
  is exposed by a plain LoadBalancer Service, so no Gateway API dataplane is
  needed. Istio is installed only if `enable_istio = true` (off by default).
- **No AWS Load Balancer Controller.** Services use the
  `aws-load-balancer-type: nlb` annotation, which the controller built into EKS
  handles.
- **No NAT Gateway.** Nodes sit in public subnets behind security groups;
  model downloads go straight out the IGW.
- **NVIDIA device plugin** is installed by Terraform: the EKS AL2023 NVIDIA AMI
  ships the driver but not the plugin.
- **Access.** Cluster admins are explicit EKS access entries — the human admin,
  the CI deploy role and the reaper role — rather than "whoever ran Terraform."

### Pinned versions

| Component | Version |
|-----------|---------|
| EKS | 1.37 |
| llm-d router chart (`llm-d-router-standalone`) + EPP | v1.0.0 |
| vLLM image | `vllm/vllm-openai:v0.30.0` |
| `llm-d-inference-sim` | v1.0.0 |
| Gateway API / Inference Extension CRDs | v1.6.2 / v1.6.2 |
| Karpenter | 1.15.1 |
| KEDA | 2.21.0 |
| kube-prometheus-stack | 92.16.0 |
| NVIDIA device plugin | 0.20.1 |
| Open WebUI chart | 18.3.0 |

The `validate` workflow checks that pinned charts and CRD URLs still resolve.

---

## Setting it up in your own account

You need Terraform ≥ 1.13, the AWS CLI v2, `kubectl`, `helm` and the `gh` CLI.
`kind` + Docker for the free local tier; `k6` for `make load` (falls back to a
container).

**1. GPU quota.** In your chosen region (default `us-west-2`), request
*Running On-Demand G and VT instances* (`L-DB2E81BA`) and/or *All G and VT Spot
Instance Requests* (`L-3819A6DF`). Both are counted in **vCPUs** and start at
zero. `kimi` needs 48 on-demand; `small`/`gpu` need 4 spot per replica. Check
with `make quota`.

**2. Bootstrap — the only layer applied from your machine**, because it creates
the role CI uses. Create `terraform/00-bootstrap/terraform.tfvars`:

```hcl
github_repo = "<owner>/<repo>"
# If the account already has the GitHub OIDC provider from another project:
# create_github_oidc_provider = false
# If the repo uses immutable OIDC subjects, set the prefix from
#   gh api repos/<owner>/<repo>/actions/oidc/customization/sub
# github_oidc_sub_prefix = "repo:<owner>@<id>/<repo>@<id>"
```

On a brand-new account the state bucket does not exist yet: comment out the
`backend "s3"` block in `terraform/00-bootstrap/versions.tf`, run
`make bootstrap`, restore the block, then run `terraform init -migrate-state`
in that directory. After that, `make bootstrap` works directly.

**3. Repo settings** (values from the bootstrap outputs):

| Kind | Name | Value |
|------|------|-------|
| secret | `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` |
| secret | `AWS_REAPER_ROLE_ARN` | `github_reaper_role_arn` |
| secret | `ALLOWED_CIDRS` | e.g. `["203.0.113.7/32"]` — who may reach the endpoints |
| secret | `HF_TOKEN` | optional; faster HuggingFace downloads |
| secret | `BUDGET_ALERT_EMAIL` | optional; enables the budget alert |
| variable | `STATE_BUCKET` | `state_bucket` |
| variable | `REAPER_ROLE_ARN` | `github_reaper_role_arn` |
| variable | `ADMIN_PRINCIPAL_ARN` | your IAM user/role ARN, for `kubectl` |

`ALLOWED_CIDRS` is a secret rather than a variable so your IP is masked in
Actions logs, which are public on a public repo.

**4. Deploy.** Set `deploy/tier` and push, or run `make deploy TIER=sim`. The
first run creates the cluster (~16 min), then the tier.

**5. Protect `main`.** The deploy role has AdministratorAccess and trusts only
workflows running on `main`, so whoever can push to `main` controls the AWS
account. Block force-pushes and require reviews from anyone but you.

---

## Layout

```
deploy/tier             which tier should be running — the deploy switch
terraform/
  00-bootstrap/         S3 state bucket, GitHub OIDC deploy + reaper roles   (local, once)
  10-cluster/           VPC (no NAT), EKS, Karpenter, KEDA, Prometheus,     (CI, ~16 min)
                        CRDs, access entries, budget
  20-inference/         NodePool, NVIDIA plugin, llm-d router, vLLM,        (CI, minutes)
                        KEDA ScaledObject, Open WebUI
    tiers/*.tfvars      sim | small | gpu | kimi — the only difference between tiers
manifests/router/       llm-d router values (shared by every tier)
manifests/sim/, local/  the free kind tier
loadgen/                k6 ramp script for `make load`
.github/workflows/      deploy · destroy · reaper · validate
docs/COSTS.md           shape/price analysis
```

The 10/20 split exists because you iterate on the inference layer constantly
and on the cluster rarely; a vLLM flag change should not risk a 16-minute
cluster rebuild.

---

## Commands

```
make deploy TIER=...  run the deploy workflow in CI and follow it
make destroy          run the destroy workflow in CI: everything billable, to ~$0
make kubeconfig       point kubectl at the cluster (context: llm-d-eks-lab)
make watch            live view of ScaledObject, HPA, pods and nodes
make load             fire k6 at the endpoint and watch replicas scale

make sim-local        free local tier on kind (sim-local-down to remove)

make down             emergency: destroy the inference layer locally
make nuke             emergency: destroy everything except state, then verify

make quota            GPU quota and what it buys
make cost             actual spend by Project tag (Cost Explorer)
make prices           current spot prices for the shapes used here
make whats-running    anything billing, including a NAT gateway check
make validate         terraform validate on every layer
make bootstrap        apply 00-bootstrap (the one local apply)
```

---

## Lessons learned

Things the first real deploy surfaced that `terraform validate` could not:

- **Karpenter reserves `karpenter.sh/*` tags.** Setting one on an EC2NodeClass
  gets the whole object rejected — no NodePool, a pod Pending forever, and
  Terraform waiting on the rollout until it times out.
- **Kubernetes gives a Deployment 10 minutes by default** (`progressDeadlineSeconds`)
  before marking it failed. A 145 GB model needs longer, so the deadline is now
  derived from the startup-probe window.
- **AWS Load Balancer Controller annotations do nothing without the controller.**
  `aws-load-balancer-type: external` tells the built-in controller to stand
  aside; with nothing else installed the Service never gets an address.
- **GitHub immutable OIDC subjects** (`repo:owner@id/repo@id:…`) break trust
  policies written for `repo:owner/repo:…` — every assume fails with "Not
  authorized." The nightly reaper failed silently for two weeks because of it.
- **The EKS AL2023 NVIDIA AMI has no device plugin.** Without it, GPU nodes
  never advertise `nvidia.com/gpu`.
- **Default gp3 writes at 125 MB/s** — about 20 minutes just to write 145 GB.
  1000 MB/s costs ~$0.05/hr and brought the download to ~6 minutes.
- **vLLM rejects `tool_choice: "auto"`** unless started with
  `--enable-auto-tool-choice` and a parser, and Open WebUI sends it.
- **Spot isn't always cheaper.** `g6e.xlarge` spot ran within 3% of on-demand,
  with a spot placement score of 1/10 across the region.

---

## Honest caveats

- **llm-d's real wins need scale.** Prefix-cache routing and prefill/decode
  disaggregation pay off across many GPUs. On one or two replicas you are
  exercising the control plane, not demonstrating a speedup.
- **The Kimi tier cannot autoscale.** Quota fits exactly one 48-vCPU node; use
  `small` or `gpu` to watch 1→2 scaling.
- **Endpoints have no auth.** The model API and Open WebUI are protected only
  by the IP allowlist. Widen `ALLOWED_CIDRS` and you should turn
  `WEBUI_AUTH` back on in `terraform/20-inference/webui.tf`.
- **Public subnets.** Nodes have public IPs (that is the no-NAT trade-off);
  security groups are the boundary. Fine for a disposable lab, not a pattern
  for production.
- **Ephemeral by design.** No persistent volumes: Open WebUI chats and
  downloaded weights vanish with their pods, and the reaper runs nightly.

## License

Apache-2.0
