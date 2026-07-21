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
- a Mixture-of-Experts model is detected from its own GGUF header and, if it
  doesn't fit VRAM, served with its experts offloaded to CPU RAM instead of
  being refused outright;
- an oversized *dense* model (no MoE structure to offload) is skipped rather
  than risking an OOM / GPU-driver reset;
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
| `nodeSelector` | attrsOf str | `{ gpu = "amd"; }` | Restricts the broker to GPU-bearing node(s). |
| `deviceResourceName` | str | `"devic.es/rocm-compute"` | Extended-resource requested; matches nixgpu's device-tokens default compute lane. |
| `deviceResourceCount` | int | `1` | Device-resource slots requested. |
| `managedLabelKey` | str | `"nixgpu.corbet.ch/managed"` | Pod label key marking this pod as nixgpu-managed. |
| `engineLabelKey` | str | `"nixgpu.corbet.ch/engine"` | Pod label key naming which GPU engine this pod uses. |
| `engineLabelValue` | str | `"compute"` | Value for `engineLabelKey` — the compute engine, not the (separate-silicon) media engine. |
| `hsaOverrideGfxVersion` | str | `"10.3.0"` | `HSA_OVERRIDE_GFX_VERSION` for ROCm. `"10.3.0"` is an RDNA2 **example** — look up your own card's correct value; empty string omits the env var entirely. |

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
| `reserveBytes` | int | `2147483648` | VRAM headroom reserved for KV cache + runtime overhead. |
| `ttlSeconds` | int | `300` | llama-swap idle TTL before an unused model unloads (B6). |
| `healthCheckTimeoutSeconds` | int | `900` | llama-swap's `healthCheckTimeout` — size for your slowest cold-load, not the average one. |
| `skipDirs` | listOf str | `[]` | Extra subdirectory names to exclude from the scan, on top of `modelMounts` scoping. Usually unneeded. |
| `aliases` | attrsOf str | `{}` | Friendly name → relative GGUF path. Only for models an app addresses by a stable name. |
| `vramFallbackBytes` | int | `17163091968` | Fallback VRAM total (~16 GiB, the nixgpu reference card) if sysfs is unreadable. |
| `ramFallbackKb` | int | `131072000` | Fallback RAM total if `/proc/meminfo` is unreadable. |
| `ramCeilingPercent` | int (1-100) | `80` | Max % of system RAM an offloaded MoE model's experts may occupy (B15). |
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
against a single shared GPU. **This generalized module has not yet been
re-verified live**; re-verify before trusting it in a new cluster.

Source lineage: generalized from a production single-GPU cluster.
