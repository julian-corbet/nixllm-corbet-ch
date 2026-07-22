#!/bin/sh
# gen-llama-swap.sh — THE STORE IS THE REGISTRY (nixgpu CONTRACT.md B10). Scan the model store and write
# ONE complete llama-swap config (globals + a "models:" entry per *fitting* GGUF) atomically to $OUT. The
# broker runs `llama-swap --config $OUT --watch-config`, so a rewrite hot-reloads in ~2s with no pod restart
# and in-flight requests drained. The output is DERIVED + THROWAWAY — never edited by hand; the store is the
# only source of truth. This file is loaded directly into the generator ConfigMap by the module's default.nix
# (`builtins.readFile`), so editing it here IS updating the deployed copy — no manual re-render/sync step.
# Drop a fitting GGUF in the right dir → served.
#
# Policy (the honest, in-repo cost of "no catalog"; B10 + B2):
#   - skip non-GGUF + app-state dirs that happen to share the store root (configurable, e.g. another app's
#     own model-store subdirectory sitting next to this one — empty by default, this module scopes each
#     app's mount to its own subdir already, see modelMounts in default.nix)
#   - SKIP a model whose on-disk size (sum of shards) exceeds (VRAM_total - RESERVE) — never -ngl 999 a
#     model that can't fit the card (that risks an OOM/ROCm card-reset; B2 forbids it)
#   - collapse `-NNNNN-of-NNNNN` shard sets to their first member (size = sum of the set)
#   - serving mode from the parent dir: embeddings/ -> embed, rerankers/ -> rerank, else chat
#   - flags from per-mode macros + sane defaults; an optional per-model `<file>.gguf.env` (sets EXTRA=...)
#     beside the model overrides flags (the blessed escape hatch)
#   - friendly app-facing names come from the ALIASES map (the module's `generator.aliases` option, rendered
#     into this environment variable — NOT the filename stem); a model with no alias serves under its stem.
#     Adding a model = drop the file; set an alias only to PIN a name.
# LiteLLM is a single wildcard pass-through (model_name "*" -> broker); it needs no generated list.
set -u

STORE="${STORE:-/models}"
OUT="${OUT:-/config.d/config.yaml}"              # the one llama-swap config the broker --watch-config's
SYS="${SYS:-/host/sys}"
RESERVE_BYTES="${RESERVE_BYTES:-2147483648}"     # headroom for KV cache + runtime overhead
FIT_TARGET_MIB=$(( RESERVE_BYTES / 1048576 ))    # --fit headroom in MiB (same reserve as the skip gate); chat models pass --fit-target this
TTL="${TTL:-300}"
# healthCheckTimeout: measured too short at the industry-default 180s for large --cpu-moe cold-loads on the
# system this generator was extracted from — a ~37 GB MoE model took ~7 minutes to pass its first health
# check, well past 180s, causing a spurious 500 on first use every time it was cold. Bumped to 900s (15 min);
# fast/GPU-resident models are unaffected (they pass health checks in seconds regardless of the ceiling).
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-900}"
# Space-padded list of dir names to skip entirely, e.g. " other-app hf-models ". Empty by default — this module
# already scopes each consumer's mount to its own subdir (see modelMounts), so there is usually nothing else
# in view to skip; set this if you mount a broader store and need to exclude non-GGUF/app-state subdirs.
SKIP_DIRS="${SKIP_DIRS:- }"

# ---- friendly-name aliases: TAB-separated "name<TAB>relative/path.gguf" lines, one per line, fed in via the
#      ALIASES env var (rendered from the module's `generator.aliases` option). The ONLY hand-edited
#      line-items, and only for models an app addresses by a stable name. Everything else serves under its
#      filename stem. ----
ALIASES="${ALIASES:-}"

TAB="$(printf '\t')"
log() { echo "gen-llama-swap: $*" >&2; }

vram="$(cat "$SYS"/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -rn | head -1)"
[ -n "${vram:-}" ] || vram="${VRAM_FALLBACK_BYTES:-17163091968}"   # fallback ~16 GiB (the nixgpu reference card) if sysfs is unreadable
THRESH=$(( vram - RESERVE_BYTES ))
# RAM ceiling for MoE expert-offload (B15): experts live in CPU RAM, so an oversized MoE is servable as long
# as it fits a configurable percentage of system RAM. Below this an oversized MoE gets --cpu-moe; above it
# (or if dense) it is skipped.
ramkb="$(sed -n 's/MemTotal:[[:space:]]*\([0-9]*\) kB/\1/p' /proc/meminfo 2>/dev/null)"
[ -n "${ramkb:-}" ] || ramkb="${RAM_FALLBACK_KB:-131072000}"       # fallback if /proc/meminfo is unreadable
RAM_CEILING_PERCENT="${RAM_CEILING_PERCENT:-80}"
RAMCEIL=$(( ramkb * 1024 / 100 * RAM_CEILING_PERCENT ))
SMALL_MODEL_BYTES="${SMALL_MODEL_BYTES:-6442450944}"   # < this => allow same-model concurrency (-np); B14
NP_SMALL="${NP_SMALL:-4}"
CONTEXT_CHAT="${CONTEXT_CHAT:-16384}"
CONTEXT_EMBED_RERANK="${CONTEXT_EMBED_RERANK:-8192}"
BATCH_EMBED_RERANK="${BATCH_EMBED_RERANK:-8192}"
# is_moe: GGUF metadata carries "<arch>.expert_count" only for Mixture-of-Experts models; the key name is
# plain text in the file header, so a header grep is a cheap, reliable detector (no GGUF parser needed).
is_moe(){ head -c 4000000 "$1" 2>/dev/null | grep -aq expert_count; }
log "card VRAM=${vram}B  fit-threshold=${THRESH}B  RAM-ceiling=${RAMCEIL}B  store=$STORE"

alias_for() {  # relpath -> friendly name (empty if none)
  printf '%s\n' "$ALIASES" | while IFS="$TAB" read -r nm rp; do
    [ "$rp" = "$1" ] && { printf '%s' "$nm"; return; }
  done
}

mkdir -p "$(dirname "$OUT")"
tmp="$OUT.tmp"
{ echo "healthCheckTimeout: $HEALTH_CHECK_TIMEOUT"; echo "logLevel: info"; echo "models:"; } > "$tmp"

# enumerate first-shard-or-unsharded GGUFs; append one models: entry per fitting model to $tmp
find "$STORE" -maxdepth 2 -name '*.gguf' 2>/dev/null | sort | while read -r path; do
  rel="${path#"$STORE"/}"
  dir="${rel%%/*}"
  base="$(basename "$rel")"
  case "$SKIP_DIRS" in *" $dir "*) continue;; esac

  size="$(stat -c %s "$path" 2>/dev/null || echo 0)"
  case "$base" in
    *-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9].gguf)
      case "$base" in
        *-00001-of-*)
          setpfx="${path%-00001-of-*}"; size=0
          for s in "$setpfx"-*-of-*.gguf; do size=$(( size + $(stat -c %s "$s" 2>/dev/null || echo 0) )); done
          ;;
        *) continue;;   # non-first shard — handled by the first
      esac
      ;;
  esac

  # Fit/skip gate (B8/B10/B15): chat models get llama.cpp's NATIVE --fit (below), which reads live
  # free VRAM at every launch (hipMemGetInfo) and offloads exactly enough — MoE experts first, then
  # whole layers — to fit what's free RIGHT NOW, with real per-tensor + KV accounting. So we no longer
  # statically pick -ngl/--cpu-moe (that DEFEATED --fit and made a "just fits" model hog the whole
  # card). We still SKIP only what cannot be served at all: a MoE bigger than the RAM ceiling (experts
  # won't fit even on CPU), or a dense model bigger than VRAM (dense layers can't shed to CPU without
  # becoming unusably slow). An oversized-but-RAM-fitting MoE is served — --fit offloads it at runtime.
  if [ "$size" -gt "$THRESH" ]; then
    if is_moe "$path" && [ "$size" -ge "$RAMCEIL" ]; then
      log "SKIP (MoE too large even for RAM: ${size}B > ${RAMCEIL}B) $rel"; continue
    elif ! is_moe "$path"; then
      log "SKIP (dense too large for VRAM: ${size}B > ${THRESH}B) $rel"; continue
    fi
    log "oversized MoE $rel (${size}B > ${THRESH}B VRAM, fits RAM) — served; --fit offloads experts at launch"
  fi

  case "$dir" in
    embeddings) mode=embed ;;
    rerankers)  mode=rerank ;;
    *)          mode=chat ;;
  esac

  name="$(alias_for "$rel")"
  if [ -z "$name" ]; then name="${base%.gguf}"; name="${name%-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]}"; fi

  EXTRA=""
  [ -f "$path.env" ] && . "$path.env" 2>/dev/null || true

  # same-model concurrency (B14): small models that fit comfortably get parallel slots (continuous batching
  # is default-on in llama.cpp); big models stay single-slot to bound KV-cache VRAM.
  np=1; [ "$size" -lt "$SMALL_MODEL_BYTES" ] && np=$NP_SMALL

  case "$mode" in
    # --fit on: llama.cpp auto-offloads at launch to fit live free VRAM (headroom = FIT_TARGET_MIB,
    # reusing the RESERVE the skip gate uses). NO explicit -ngl/--cpu-moe/-ot — any of those DISABLES
    # fitting for that parameter. -c is the target context; --fit shrinks it (down to its floor) only
    # if VRAM is too tight. Verified live on the ROCm build: a 26B MoE loaded + served with ~7 GiB free.
    chat)   flags="--fit on --fit-target $FIT_TARGET_MIB -c $CONTEXT_CHAT -np $np" ;;
    embed)  flags="--embeddings --pooling last -c $CONTEXT_EMBED_RERANK -b $BATCH_EMBED_RERANK -ub $BATCH_EMBED_RERANK -np $np" ;;
    rerank) flags="--reranking -c $CONTEXT_EMBED_RERANK -b $BATCH_EMBED_RERANK -ub $BATCH_EMBED_RERANK -np 1" ;;
  esac

  {
    echo "  \"$name\":"
    echo "    cmd: |"
    echo "      llama-server --model $path"
    echo "      $flags $EXTRA --host 127.0.0.1 --port \${PORT}"
    echo "    ttl: $TTL"
  } >> "$tmp"
  log "emit [$mode] $name <- $rel (${size}B)"
done

n_emit="$(grep -c '^  "' "$tmp" 2>/dev/null || echo 0)"
# Only replace the config when content actually CHANGED — otherwise the broker's --watch-config would
# reload (and evict the resident model!) every cycle. Idempotent: no change => no reload (B5/B6/B7).
if cmp -s "$tmp" "$OUT" 2>/dev/null; then
  rm -f "$tmp"; log "unchanged: $n_emit model(s) — config identical, no reload"
else
  mv "$tmp" "$OUT"; log "updated: $n_emit model(s) -> $OUT (broker hot-reloads ~2s)"
fi
