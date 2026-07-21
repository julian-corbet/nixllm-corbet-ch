# nixllm

**Self-hosted LLM serving where the model store IS the registry: drop a GGUF
in a directory and it is servable by name. No catalog, ever.**

One shared llama-swap + llama.cpp broker owns every model on the card,
fronted by LiteLLM as a single OpenAI-compatible door. The serving config is
*generated* from the store — a derived, throwaway artifact, never a source of
truth you edit.

## The pitch

Every self-hosted LLM setup grows the same tumor: a hand-maintained model
catalog that drifts from the directory it describes. `nixllm` deletes it:

- **The store IS the registry.** Serving mode comes from the subdirectory
  (`embeddings/` → embedder, `rerankers/` → reranker, anything else → chat);
  context length and chat template come from GGUF metadata; the rest is sane
  defaults. Adding a model = dropping a file.
- **Fit-aware, not naive.** An oversized dense model is skipped (never the
  card-reset an oversized full-offload load risks); an oversized
  Mixture-of-Experts model is served anyway, experts on CPU RAM, attention +
  KV on the GPU. Shard sets collapse to their first member; stable app-facing
  names come from a one-line alias file beside the model.
- **One broker, no VRAM hogs.** Apps never start their own GPU model server —
  they point at the one front door with a key and a model name, and request
  no GPU of their own. Models load on demand in seconds (a warm page cache
  does the heavy lifting) and idle models unload.
- **Concurrency is first-class, twice.** Same-model requests interleave via
  continuous batching; several small models co-reside and serve in parallel
  when they fit together.

These are behaviors B4/B10/B14/B15 of the
[nixgpu contract](https://github.com/julian-corbet/nixgpu-corbet-ch/blob/main/CONTRACT.md)
— platform obligations for any serving lane on a shared card. `nixllm` is the
lane; [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) is the
sharing substrate it runs on.

## What ships

- **`serving`** (`nixidyModules.serving`, landed) — the full lane as a nixidy
  module: llama-swap + llama.cpp broker, LiteLLM front door, and the
  store-scan config generator, with the GPU contract surface (priority class,
  device token, Recreate strategy) as options. See
  [modules/serving/README.md](modules/serving/README.md) for the option
  table.

## Status

**Pre-alpha, and dogfooded: the originating cluster runs THIS module in
production.** The lane was adopted back in-place (via the `appName` option,
no prune/recreate) — the generalized module serves real models on the real
card today, front door and store-scan generator included.

## Requirements (deliberate, not negotiable)

Like its siblings, `nixllm` targets a declarative GitOps cluster:
**nixidy-rendered manifests synced by Argo CD** — the spine shipped by
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch). GPU scheduling
and reclaim come from
[nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch).

## Related projects

Part of an interoperating set — usable independently, designed together:

- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — priority-based
  sharing of one GPU; the substrate this lane runs on.
- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — bare-metal k3s
  on NixOS + the nixidy → Argo CD GitOps spine.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — curated
  tenant app modules (image generation, TTS, …) that consume the same
  contracts.
- [nixvibe](https://github.com/julian-corbet/nixvibe-corbet-ch) — a coding
  agent in a real browser terminal; requires an endpoint like this one but
  never bundles it.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
