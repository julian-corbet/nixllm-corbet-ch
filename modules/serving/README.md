# serving

The shared LLM **serving lane** — the heart of nixllm. ONE llama-swap +
ROCm llama.cpp broker owns every model on the card; [LiteLLM](https://github.com/BerriAI/litellm)
sits in front of it as the single OpenAI-compatible door every consuming app
targets. No app runs its own model server and no app reserves VRAM for
itself — everything goes through this one lane.

The defining idea: **the model store IS the registry.** There is no
hand-maintained list of served models. A generator script scans the store on
a timer and writes llama-swap's config directly from what it finds:

- serving mode comes from the subdirectory a GGUF lives in — `embeddings/`
  serves in embedding mode, `rerankers/` in reranking mode, anything else in
  chat mode;
- every chat-mode model is launched through llama.cpp's own native **`--fit`**
  mechanism, not a static store-scan-time guess: at launch, `--fit` reads how
  much VRAM is actually free right now and offloads exactly enough to fit it —
  Mixture-of-Experts experts first, then whole layers for dense models if
  still short — so the offload split is a live, per-launch decision, not
  something baked into the generated config ahead of time;
- an oversized *dense* model (no MoE structure to shed) is still skipped at
  store-scan time rather than risking an OOM / GPU-driver reset — no amount of
  runtime fitting helps a dense model that would not even run at usable speed
  fully offloaded to CPU;
- a `-00001-of-NNNNN`-style shard set collapses to its first member for size
  accounting;
- a friendly app-facing name comes from a small alias map (only for models
  worth addressing by a stable name) — everything else serves under its
  filename stem, so "add a model" is really just "drop the file".

Because the config is *derived*, it is also disposable: the generator only
rewrites it when the content actually changed, so llama-swap's
`--watch-config` hot-reload never evicts a resident model on a no-op cycle.

This module implements platform contract behaviors **B4** (one server owns
all LLMs), **B10** (store-is-registry), **B14** (same-model + multi-model
concurrency) and **B15** (MoE / partial offload) from the
[nixgpu contract](https://github.com/julian-corbet/nixgpu-corbet-ch/blob/main/CONTRACT.md).
The GPU *device* infrastructure this lane depends on (a device-resource
token, a priority-class ladder, VRAM pressure eviction) is a separate
concern shipped by the sibling **nixgpu** project — this module only
*consumes* that contract (`gpu.priorityClassName`, `gpu.deviceResourceName`,
the managed/engine labels below), it does not provide it.

## Why per-subdirectory mounts, not one big store

The broker never gets one hostPath mount of the whole model store. Instead,
`modelMounts` lists the subdirectories it should see, and each gets its own
explicit, read-only hostPath bind at the same relative path inside the pod.
This is deliberate, not incidental: a shared store commonly holds other
things too (another app's own model format, an unrelated pipeline's state
directory) and a mistake or reorganization elsewhere in that store cannot
leak into what the broker scans if the broker was never given a path to see
it in the first place. Adding a new model family is one new list entry —
after actually checking what is in that subdirectory, since a directory name
alone can be misleading.

## Options

Top-level:

| Option | Type | Default | Description |
|---|---|---|---|
| `nixllm.serving.enable` | bool | `false` | Enable the module. |
| `nixllm.serving.namespace` | str | `"llm"` | Namespace for the broker and LiteLLM. |
| `nixllm.serving.appName` | str | `"llm-serving"` | Name of the generated nixidy/Argo application; override to adopt an existing app name in-place during migration. |
| `nixllm.serving.createNamespace` | bool | `true` | Whether this application creates its namespace. |
| `nixllm.serving.project` | str | `"apps"` | nixidy AppProject. Map to whatever tier your scheme uses for apps that touch the GPU directly — this belongs with other direct GPU consumers, not with plain CPU-only apps or with nixgpu's own device-infra tier. |
| `nixllm.serving.modelStoreHostPath` | str | **required** | Host path to the model store root. No default — every deployment's storage differs; a default here would be a lie. |
| `nixllm.serving.modelMounts` | listOf str | `["embeddings" "rerankers"]` | Store subdirectories to bind-mount, one at a time (see above). `embeddings`/`rerankers` are structural — the generator's mode routing depends on those two names specifically. Add one entry per chat-model family you keep. Each entry's k8s volume name is derived by lowercasing and replacing `.`/`_` with `-` (k8s volume names must be DNS-1123 labels); the `mountPath`/host subdirectory keep the entry verbatim. Two entries that only differ in the sanitized characters (e.g. `a.b` vs `a-b`) collide into the same volume name — keep entries distinguishable after sanitization, and otherwise path-safe as-is. |
| `nixllm.serving.storeMountPath` | str | `"/models"` | In-pod mount root for the model subdirectories (the generator's `STORE`). |
| `nixllm.serving.sysHostPath` | str | `"/sys"` | Host path bind-mounted so the generator can read live VRAM size. |
| `nixllm.serving.brokerPort` | port | `8080` | Port llama-swap listens on; also what LiteLLM's `api_base` targets. |

GPU contract surface (`nixllm.serving.gpu.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `priorityClassName` | str | `"gpu-interactive"` | PriorityClass for the broker pod (matches nixgpu's priority-ladder interactive rung by default). |
| `nodeSelector` | attrsOf str | **required** | Restricts the broker to GPU-bearing node(s). No default — a node-label convention is a fact about your cluster, not about GPUs. |
| `deviceResourceName` | str | `"devic.es/rocm-compute"` | Extended-resource requested; matches nixgpu's device-tokens default compute lane. |
| `deviceResourceCount` | int | `1` | Device-resource slots requested. |
| `managedLabelKey` | str | `"nixgpu.corbet.ch/managed"` | Pod label key marking this pod as nixgpu-managed. |
| `engineLabelKey` | str | `"nixgpu.corbet.ch/engine"` | Pod label key naming which GPU engine this pod uses. |
| `engineLabelValue` | str | `"compute"` | Value for `engineLabelKey` — the compute engine, not the (separate-silicon) media engine. |
| `hsaOverrideGfxVersion` | str | **required** | `HSA_OVERRIDE_GFX_VERSION` for ROCm. No default — a wrong value doesn't fail loudly (ROCm refuses the device, or miscompiles kernels for the wrong architecture); look up your own card's correct value, or set `""` to omit the env var on a card ROCm already supports natively. |

Images (`nixllm.serving.images.*`), all pinned, source-observed defaults:

| Option | Default |
|---|---|
| `llamaSwapExtractor` | `ghcr.io/mostlygeek/llama-swap:cpu` |
| `llamaCpp` | `ghcr.io/ggml-org/llama.cpp:server-rocm` |
| `gen` | `busybox:stable` |
| `litellm` | `ghcr.io/berriai/litellm:main-latest` |

LiteLLM (`nixllm.serving.litellm.*`):

| Option | Type | Default | Description |
|---|---|---|---|
| `existingSecretName` | str | `"litellm-secrets"` | Name of an **existing** Secret (bring your own — sealed-secrets, external-secrets, or a plain Secret you apply yourself) holding the master key. Not created by this module. |
| `masterKeySecretKey` | str | `"LITELLM_MASTER_KEY"` | Key within that Secret. |
| `port` | port | `4000` | LiteLLM listen port. |
| `clusterIP` | nullOr str | `null` | Optional fixed ClusterIP. Leave `null` unless your routing needs a stable, pre-known VIP. |
| `requestTimeout` | int | `900` | LiteLLM's own `request_timeout` (seconds) — keep ≥ `generator.healthCheckTimeoutSeconds`, since LiteLLM sits between every consuming app and the broker and will cut the connection first if its timeout is shorter. |

Generator (`nixllm.serving.generator.*`) — every threshold the store scan
uses, each mapped straight from the shipped `gen-llama-swap.sh`'s own
environment-variable inputs:

| Option | Type | Default | Description |
|---|---|---|---|
| `pollIntervalSeconds` | int | `60` | How often the refresh sidecar re-scans the store. |
| `outputConfigPath` | str | `"/config.d/config.yaml"` | In-pod path the generated config is written to. |
| `sysMountPath` | str | `"/host/sys"` | In-pod mount path for `sysHostPath` (the generator's `SYS`). |
| `vramTotalAttr` | str | `"mem_info_vram_total"` | sysfs attribute (under `class/drm/card*/device/`) read for total VRAM. amdgpu-specific, not a DRM standard — the same fact the sibling nixgpu project owns as `nixgpu.sysfs.vramTotalAttr`. When nixgpu's modules are imported into the same nixidy environment as this one, this module **mirrors nixgpu's value automatically**; this option is only nixllm's own fallback for running standalone (no hard dependency on nixgpu). See the option's own description for what silently breaks if it's wrong. |
| `reserveBytes` | int | `2147483648` | VRAM headroom reserved for KV cache + runtime overhead. |
| `ttlSeconds` | int | `300` | llama-swap idle TTL before an unused model unloads (B6). |
| `healthCheckTimeoutSeconds` | int | `900` | llama-swap's `healthCheckTimeout` — size for your slowest cold-load, not the average one. |
| `skipDirs` | listOf str | `[]` | Extra subdirectory names to exclude from the scan, on top of `modelMounts` scoping. Usually unneeded. |
| `aliases` | attrsOf str | `{}` | Friendly name → relative GGUF path. Only for models an app addresses by a stable name. |
| `vramFallbackBytes` | int | `17163091968` | Fallback VRAM total (~16 GiB, the nixgpu reference card) if sysfs is unreadable. |
| `ramFallbackKb` | int | `131072000` | Fallback RAM total if `/proc/meminfo` is unreadable. |
| `ramCeilingPercent` | int (1-100) | `80` | Max % of system RAM an oversized MoE model's expert weights may occupy before it is skipped at store-scan time; the offload itself is a runtime `--fit` decision, not this gate (B15). |
| `smallModelBytes` | int | `6442450944` | Below this, a model gets same-model concurrency (multiple `-np` slots, B14a). |
| `npSmall` | int | `4` | Parallel slot count for models under `smallModelBytes`. |
| `contextSizeChat` | int | `16384` | Context window for chat-mode models. |
| `contextSizeEmbedRerank` | int | `8192` | Context window for embedding/reranking-mode models. |
| `batchSizeEmbedRerank` | int | `8192` | Batch/micro-batch size for embedding/reranking-mode models. |

## Consumer example

```nix
{
  imports = [ inputs.nixllm.nixidyModules.serving ];

  nixllm.serving.enable = true;
  nixllm.serving.modelStoreHostPath = "/srv/models"; # required — your real store root
  nixllm.serving.modelMounts = [ "embeddings" "rerankers" "chat" ];

  # Bring your own Secret named litellm-secrets with key LITELLM_MASTER_KEY
  # (sealed-secrets, external-secrets, whatever your cluster uses), or point
  # existingSecretName at one you already manage.

  # Optional: pin a couple of stable app-facing names.
  nixllm.serving.generator.aliases = {
    "chat-default" = "chat/My-Chat-Model-Q8_0.gguf";
    "embed-default" = "embeddings/My-Embedder-Q8_0.gguf";
  };
}
```

Every consuming app then just needs a key and a model name — it targets
`http://litellm.<namespace>.svc.cluster.local:<litellm.port>` with the
`existingSecretName` key, and asks for a model by its alias or filename
stem. It requests no GPU resource of its own.

## Status

Extracted from a production system where this lane runs live — serving a
RAG stack (embedder + reranker + chat models) and other consuming apps
against a single shared GPU, and dogfooded there today. **The generalized
module has since been re-verified live**, including under deliberately
adversarial contention (below) — this is not a "trust but verify before use"
caveat anymore, though it is still same-day validation, not multi-day
organic soak.

The `--fit`-based runtime offload described above is not just a design on
paper: on the originating cluster it was proven live under deliberately
adversarial contention — a chat model not yet resident, the card already
filled to within roughly 2.5 GiB of its 16 GiB total by other best-effort
tenants, requested through the real front door (not a synthetic harness) —
and it served successfully, in 44 seconds, with zero GPU resets. That is
concrete evidence for B15's "served, not refused" claim under real
pressure, not just the happy-path case. It is one same-day proof under
synthetic adversarial load, though, not multi-day organic soak — treat it as
real confidence, not as "hardened" or "no further work needed."

Source lineage: generalized from a production single-GPU cluster.
