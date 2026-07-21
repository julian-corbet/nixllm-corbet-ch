# serving — the shared LLM serving lane (the heart of nixllm). ONE llama-swap + ROCm llama.cpp broker
# owns every model on the card; LiteLLM sits in front as the single OpenAI-compatible door every consuming
# app targets. The model STORE is the registry (nixgpu CONTRACT.md B10): drop a GGUF in the right subdir
# and it becomes servable by name, with no hand-maintained catalog. This module implements platform
# contract behaviors B4 (one server owns all LLMs), B10 (store-is-registry), B14 (concurrency, twice) and
# B15 (MoE / partial offload) — see https://github.com/julian-corbet/nixgpu-corbet-ch/blob/main/CONTRACT.md
#
# GPU DEVICE INFRA (device tokens, priority ladder, pressure watcher) is a separate concern, shipped by the
# sibling nixgpu project — this module is a *consumer* of that contract (priorityClassName, a device
# resource token, the managed/engine labels), not a provider of it.
#
# Status: extracted from a production system where this lane runs live, serving a RAG stack (embedder +
# reranker + chat models) and other consuming apps on a single shared GPU. This generalized module has not
# yet been re-verified live — re-verify before trusting it in a new cluster.
{ lib, config, ... }:
let
  cfg = config.nixllm.serving;

  genScript = builtins.readFile ./gen-llama-swap.sh;

  # ALIASES is fed to the generator as a TAB-separated "name<TAB>relative/path.gguf" block, one alias per
  # line — see generator.aliases below and the script's own header comment for the convention.
  aliasesEnv = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (name: path: "${name}\t${path}") cfg.generator.aliases);

  # Space-padded so the script's `case "$SKIP_DIRS" in *" $dir "*)` substring match works for every entry,
  # including when the list is empty (just a single space => nothing ever matches).
  skipDirsEnv = " " + lib.concatStringsSep " " cfg.generator.skipDirs + " ";

  genEnv = [
    { name = "STORE"; value = cfg.storeMountPath; }
    { name = "OUT"; value = cfg.generator.outputConfigPath; }
    { name = "SYS"; value = cfg.generator.sysMountPath; }
    { name = "RESERVE_BYTES"; value = toString cfg.generator.reserveBytes; }
    { name = "TTL"; value = toString cfg.generator.ttlSeconds; }
    { name = "HEALTH_CHECK_TIMEOUT"; value = toString cfg.generator.healthCheckTimeoutSeconds; }
    { name = "SKIP_DIRS"; value = skipDirsEnv; }
    { name = "ALIASES"; value = aliasesEnv; }
    { name = "VRAM_FALLBACK_BYTES"; value = toString cfg.generator.vramFallbackBytes; }
    { name = "RAM_FALLBACK_KB"; value = toString cfg.generator.ramFallbackKb; }
    { name = "RAM_CEILING_PERCENT"; value = toString cfg.generator.ramCeilingPercent; }
    { name = "SMALL_MODEL_BYTES"; value = toString cfg.generator.smallModelBytes; }
    { name = "NP_SMALL"; value = toString cfg.generator.npSmall; }
    { name = "CONTEXT_CHAT"; value = toString cfg.generator.contextSizeChat; }
    { name = "CONTEXT_EMBED_RERANK"; value = toString cfg.generator.contextSizeEmbedRerank; }
    { name = "BATCH_EMBED_RERANK"; value = toString cfg.generator.batchSizeEmbedRerank; }
  ];

  # One hostPath volume + mount PER model-owning subdirectory (see modelMounts doc below for the why),
  # at the same relative path both inside the pod (under storeMountPath) and on the host (under
  # modelStoreHostPath) — the generator's dir-name routing (embeddings/ -> embed, rerankers/ -> rerank)
  # depends on that relative path being preserved.
  #
  # modelMounts entries become k8s volume NAMES, which must be DNS-1123 labels (lowercase alphanumerics
  # and '-' only) — a directory name straight off disk (e.g. "Qwen3.5") is not guaranteed to qualify, so
  # sanitize it for the volume name only, while mountPath/hostPath keep the entry verbatim since those are
  # real filesystem paths, not k8s identifiers. NOTE: two distinct entries can collide into the same
  # sanitized name (e.g. "a.b" and "a-b" both become "a-b") — this is not otherwise detected, so keep
  # modelMounts entries distinguishable after sanitization; entries must also already be path-safe
  # (whatever DNS-1123 doesn't fix, the filesystem still has to accept as-is).
  sanitizeVolumeName = d: lib.toLower (lib.replaceStrings [ "." "_" ] [ "-" "-" ] d);

  modelVolumes = map
    (d: {
      name = "models-${sanitizeVolumeName d}";
      hostPath = { path = "${cfg.modelStoreHostPath}/${d}"; type = "Directory"; };
    })
    cfg.modelMounts;

  modelVolumeMounts = map
    (d: { name = "models-${sanitizeVolumeName d}"; mountPath = "${cfg.storeMountPath}/${d}"; readOnly = true; })
    cfg.modelMounts;

  # Directory the generated config lives in, in-pod — derived from generator.outputConfigPath so the
  # config-d volume mount and the broker's --config flag can never drift out of sync with the option.
  generatedConfigDir = builtins.dirOf cfg.generator.outputConfigPath;

  litellmConfigYaml = ''
    model_list:
      - model_name: "*"
        litellm_params:
          model: openai/*
          api_base: http://llama-broker.${cfg.namespace}.svc.cluster.local:${toString cfg.brokerPort}/v1
          api_key: dummy
    litellm_settings:
      drop_params: true
      # request_timeout: a serving chain this long can have more than one cold-load timeout in series — the
      # generator's own healthCheckTimeout (generator.healthCheckTimeoutSeconds) and any downstream consumer
      # app's own first-token/stream timeout are independent knobs that all have to tolerate the same slow
      # cold load, or whichever is shortest cuts the connection regardless of what the others allow. Keep
      # this in sync with the other links in the chain rather than raising just one of them.
      request_timeout: ${toString cfg.litellm.requestTimeout}
  '';
in
{
  options.nixllm.serving = {
    enable = lib.mkEnableOption "the shared LLM serving lane (llama-swap broker + LiteLLM front door)";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "llm";
      description = "Namespace the broker and LiteLLM Deployments run in.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this application creates its own namespace.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = ''
        nixidy AppProject this application is filed under. Map it to whatever your Argo CD AppProject
        tiering scheme calls the tier for apps that talk to the GPU directly — the broker holds a device
        resource token and a `gpu-interactive`-class pod, so it belongs with other direct GPU consumers,
        not with ordinary CPU-only workloads or with the platform/device-infra tier that nixgpu itself
        occupies (device tokens, priority ladder, pressure watcher).
      '';
    };

    modelStoreHostPath = lib.mkOption {
      type = lib.types.str;
      example = "/srv/models";
      description = ''
        Absolute host filesystem path to the root of the model store, on whatever node(s) the broker is
        scheduled to. REQUIRED, no default — every real deployment's storage layout is different, and
        any default here would silently point at a path that doesn't exist on your node.

        Every entry in `modelMounts` is expected to exist as a subdirectory directly under this path.
      '';
    };

    modelMounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "embeddings" "rerankers" ];
      description = ''
        Model-store subdirectories to mount into the broker, ONE explicit hostPath bind per entry — never
        the whole store as one big mount. This is deliberate: the pod only ever sees the subdirectories it
        is meant to serve from, so a mistake elsewhere in a shared store (another app's own model format,
        an unrelated app's state directory) cannot leak into what the broker scans, and a store reorganized
        outside this list simply isn't visible until added here. Add a new model family = add one entry
        (after checking what's actually in that subdirectory — a directory name alone can be misleading).

        Two names are structural, not just convention: the generator (`gen-llama-swap.sh`) routes serving
        mode by directory name — `embeddings/` -> embedding mode, `rerankers/` -> reranking mode, anything
        else -> chat. Both must exist (even empty) under `modelStoreHostPath` for the defaults to schedule;
        remove either entry if you don't serve that mode. Add further entries for however many chat-model
        family subdirectories you keep (their names are entirely up to you — the generator treats every
        non-`embeddings`/`rerankers` subdir identically).
      '';
    };

    storeMountPath = lib.mkOption {
      type = lib.types.str;
      default = "/models";
      description = "In-pod mount root the model subdirectories are mounted under, and the generator's STORE env var.";
    };

    sysHostPath = lib.mkOption {
      type = lib.types.str;
      default = "/sys";
      description = ''
        Host path bind-mounted read-only so the generator can read live VRAM size from
        `class/drm/card*/device/mem_info_vram_total`. Standard on any Linux node; only change this if your
        node runs the broker inside some other mount namespace that relocates `/sys`.
      '';
    };

    brokerPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port llama-swap listens on inside the broker pod, and that LiteLLM's api_base targets.";
    };

    gpu = {
      priorityClassName = lib.mkOption {
        type = lib.types.str;
        default = "gpu-interactive";
        description = ''
          PriorityClass for the broker pod. Defaults to the nixgpu ladder's interactive rung (see
          nixgpu's priority-ladder module) — the lane is latency-sensitive serving, so it outranks
          best-effort GPU work but yields to a desktop/interactive session using the same card.
        '';
      };

      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { gpu = "amd"; };
        description = "Node selector restricting the broker to the node(s) that carry the shared GPU.";
      };

      deviceResourceName = lib.mkOption {
        type = lib.types.str;
        default = "devic.es/rocm-compute";
        description = ''
          Extended-resource name the broker requests, matching whatever device plugin advertises the
          GPU's compute lane (e.g. nixgpu's device-tokens module, which by default advertises this exact
          resource name via squat/generic-device-plugin).
        '';
      };

      deviceResourceCount = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "How many device-resource slots the broker requests. One broker holds one compute slot.";
      };

      managedLabelKey = lib.mkOption {
        type = lib.types.str;
        default = "nixgpu.corbet.ch/managed";
        description = ''
          Pod label key marking this pod as under nixgpu's management (e.g. visible to a pressure
          watcher that reclaims VRAM by priority). Set to "true" on the broker pod template. Rename to
          match whatever label domain the rest of your nixgpu deployment uses.
        '';
      };

      engineLabelKey = lib.mkOption {
        type = lib.types.str;
        default = "nixgpu.corbet.ch/engine";
        description = "Pod label key identifying which GPU engine this pod uses (see engineLabelValue).";
      };

      engineLabelValue = lib.mkOption {
        type = lib.types.str;
        default = "compute";
        description = ''
          Engine identifier for the label above. The broker uses the compute engine (as opposed to a
          media/video-codec engine, which runs on separate silicon and is unaffected by compute-side
          pressure — see nixgpu CONTRACT.md B3).
        '';
      };

      hsaOverrideGfxVersion = lib.mkOption {
        type = lib.types.str;
        default = "10.3.0";
        description = ''
          `HSA_OVERRIDE_GFX_VERSION` passed to the broker container. ROCm ships official support for a
          fixed list of GPU architectures; this override tells ROCm to treat the card as the nearest
          supported architecture. This option DEFAULTS to "10.3.0" — the value an RDNA2 consumer card
          needs — IT IS AN EXAMPLE, not a universal default. Find your own card's correct value from
          ROCm's supported-GPU list, or set this to "" (empty string) to omit the env var entirely on a
          card ROCm already supports natively.
        '';
      };
    };

    images = {
      llamaSwapExtractor = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/mostlygeek/llama-swap:cpu";
        description = ''
          Image the broker's init container extracts the `llama-swap` binary from (a CPU-only build is
          fine — only the binary is used, never run against the GPU). Extracting into the ROCm image
          this way avoids building a custom image that bundles both.
        '';
      };

      llamaCpp = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/ggml-org/llama.cpp:server-rocm";
        description = "ROCm-enabled llama.cpp server image the broker container runs llama-swap on top of.";
      };

      gen = lib.mkOption {
        type = lib.types.str;
        default = "busybox:stable";
        description = "Image for the generator init container and refresh sidecar — a POSIX shell is all `gen-llama-swap.sh` needs.";
      };

      litellm = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/berriai/litellm:main-latest";
        description = "LiteLLM image.";
      };
    };

    litellm = {
      existingSecretName = lib.mkOption {
        type = lib.types.str;
        default = "litellm-secrets";
        description = ''
          Name of an EXISTING Kubernetes Secret, in this application's namespace, holding the LiteLLM
          master key. This module does not create the Secret — bring your own via whatever mechanism
          your cluster uses (sealed-secrets, external-secrets, a plain manually-applied Secret). The
          Secret must have a key matching `masterKeySecretKey`.
        '';
      };

      masterKeySecretKey = lib.mkOption {
        type = lib.types.str;
        default = "LITELLM_MASTER_KEY";
        description = "Key within existingSecretName holding the master key value.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 4000;
        description = "Port LiteLLM listens on.";
      };

      clusterIP = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional fixed ClusterIP for the LiteLLM Service. Leave null for a normal, cluster-assigned
          ClusterIP (the right choice for almost everyone). Only set this if your cluster's CNI/routing
          convention needs consuming apps to reach a stable, pre-known VIP rather than resolving the
          Service by DNS.
        '';
      };

      requestTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = ''
          LiteLLM `request_timeout` (seconds). Keep this at least as large as
          `generator.healthCheckTimeoutSeconds` — LiteLLM sits between every consuming app and the broker,
          so if it times out sooner than the broker's own cold-load allowance, it cuts the connection
          first regardless of what the broker would have tolerated.
        '';
      };
    };

    generator = {
      pollIntervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = ''
          How often the refresh sidecar re-runs the generator against the live store. The broker's
          `--watch-config` picks up a changed output file in ~2s regardless of this interval — this only
          bounds how stale the store scan itself can be (B10: "drop a file = served").
        '';
      };

      outputConfigPath = lib.mkOption {
        type = lib.types.str;
        default = "/config.d/config.yaml";
        description = "In-pod path the generator writes the llama-swap config to (an emptyDir shared with the broker container).";
      };

      sysMountPath = lib.mkOption {
        type = lib.types.str;
        default = "/host/sys";
        description = "In-pod mount path for the sysHostPath volume (the generator's SYS env var).";
      };

      reserveBytes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2147483648;
        description = "VRAM headroom (bytes) reserved for KV cache + runtime overhead when fit-testing a model against measured VRAM.";
      };

      ttlSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "llama-swap idle TTL (seconds) before an unused resident model unloads (nixgpu CONTRACT.md B6).";
      };

      healthCheckTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = ''
          llama-swap's `healthCheckTimeout`. Needs to be generous enough for the SLOWEST cold-load in your
          store, not the average one — a large MoE model with expert-offload (--cpu-moe) can take several
          minutes to pass its first health check even though it serves fast once resident. Too short here
          shows up as a spurious error on the first request to a large cold model, every time.
        '';
      };

      skipDirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Store subdirectory names to skip entirely during the scan, even if they contain files ending in
          `.gguf`. Empty by default, because `modelMounts` already scopes this pod's view of the store to
          only the subdirectories it should serve from — you will rarely need this unless you mount a
          broader store than the per-app-scoped default and must exclude another app's own model-store
          subdirectory (a different serving pipeline's own file layout, non-GGUF-format model directories
          used by another tool) that happens to sit alongside this one.
        '';
      };

      aliases = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "my-chat-model" = "chat/My-Chat-Model-Q8_0.gguf";
          "my-embedder" = "embeddings/My-Embedder-Q8_0.gguf";
        };
        description = ''
          Friendly app-facing model names, mapping a stable alias to the model's path relative to the
          store root. Empty by default — with no aliases, every model serves under its filename stem
          (with any shard suffix stripped), which is fine until you want an app to address a model by a
          name that doesn't change across a file rename or a quantization swap. Add an alias only to PIN
          a name; everything else needs no entry at all ("add a model" = drop the file, nothing more).
        '';
      };

      vramFallbackBytes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 17163091968;
        description = ''
          Fallback VRAM total (bytes) used only if the sysfs VRAM readout is unavailable. The default
          (~16 GiB) matches the reference card in the nixgpu contract; set this to your card's real VRAM
          total as a safety net, not as the primary source (the primary source is always the live sysfs
          reading when present).
        '';
      };

      ramFallbackKb = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 131072000;
        description = "Fallback system RAM total (KiB) used only if /proc/meminfo is unreadable.";
      };

      ramCeilingPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 80;
        description = ''
          Percentage of system RAM an oversized MoE model's expert weights are allowed to occupy under
          `--cpu-moe` offload before it is skipped as too large (nixgpu CONTRACT.md B15). Leaves headroom
          for the OS, the page/ARC cache, and every other tenant on the box.
        '';
      };

      smallModelBytes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 6442450944;
        description = ''
          Size threshold (bytes) below which a model is considered small enough to serve with same-model
          concurrency (multiple parallel slots via continuous batching, B14a) rather than one slot. Above
          this, or for any offloaded (--cpu-moe) model, a model gets a single slot to bound KV-cache VRAM.
        '';
      };

      npSmall = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Parallel slot count (`-np`) given to models under smallModelBytes.";
      };

      contextSizeChat = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16384;
        description = "Context window (`-c`) for chat-mode models.";
      };

      contextSizeEmbedRerank = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8192;
        description = "Context window (`-c`) for embedding- and reranking-mode models.";
      };

      batchSizeEmbedRerank = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8192;
        description = "Batch and micro-batch size (`-b`/`-ub`) for embedding- and reranking-mode models.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    applications.llm-serving = {
      namespace = cfg.namespace;
      createNamespace = cfg.createNamespace;
      project = cfg.project;

      resources.configMaps.llm-serving-gen.data."gen-llama-swap.sh" = genScript;

      resources.configMaps.litellm-config.data."config.yaml" = litellmConfigYaml;

      # llama-broker — the shared serving engine. strategy: Recreate, not RollingUpdate: this pod holds
      # the ONE compute device-resource slot (deviceResourceCount, default 1), so a surging new pod
      # couldn't schedule anyway while the old one is still up — Recreate tears the old pod down first,
      # avoiding a pod stuck Pending for the whole rollout.
      resources.deployments.llama-broker = {
        metadata.labels.app = "llama-broker";
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          selector.matchLabels.app = "llama-broker";
          template = {
            metadata.labels = {
              app = "llama-broker";
              "${cfg.gpu.managedLabelKey}" = "true";
              "${cfg.gpu.engineLabelKey}" = cfg.gpu.engineLabelValue;
            };
            spec = {
              nodeSelector = cfg.gpu.nodeSelector;
              priorityClassName = cfg.gpu.priorityClassName;

              initContainers = [
                {
                  name = "get-swap";
                  image = cfg.images.llamaSwapExtractor;
                  command = [
                    "sh"
                    "-c"
                    ''f=$(command -v llama-swap || find / -type f -name llama-swap 2>/dev/null | head -1); cp "$f" /shared/llama-swap && chmod +x /shared/llama-swap''
                  ];
                  volumeMounts = [{ name = "shared"; mountPath = "/shared"; }];
                }
                # Generate the config from the store once, before the broker starts, so it comes up with a
                # valid model set (nixgpu CONTRACT.md B10). The refresh sidecar (below) keeps it fresh
                # afterwards; the broker's --watch-config hot-reloads without a restart.
                {
                  name = "gen-init";
                  image = cfg.images.gen;
                  command = [ "sh" "/gen/gen-llama-swap.sh" ];
                  env = genEnv;
                  volumeMounts = [
                    { name = "config-d"; mountPath = generatedConfigDir; }
                  ] ++ modelVolumeMounts ++ [
                    { name = "sys"; mountPath = cfg.generator.sysMountPath; readOnly = true; }
                    { name = "gen-script"; mountPath = "/gen"; }
                  ];
                }
              ];

              containers = [
                {
                  name = "broker";
                  image = cfg.images.llamaCpp;
                  command = [
                    "sh"
                    "-c"
                    ''D=$(dirname $(find / -name llama-server -type f 2>/dev/null | head -1)); export PATH=$D:$PATH; exec /shared/llama-swap --config ${cfg.generator.outputConfigPath} --watch-config --listen 0.0.0.0:${toString cfg.brokerPort}''
                  ];
                  env = lib.optional (cfg.gpu.hsaOverrideGfxVersion != "")
                    { name = "HSA_OVERRIDE_GFX_VERSION"; value = cfg.gpu.hsaOverrideGfxVersion; };
                  ports = [{ containerPort = cfg.brokerPort; }];
                  resources.limits."${cfg.gpu.deviceResourceName}" = cfg.gpu.deviceResourceCount;
                  # Carried as-is from the originating production deployment (undocumented there beyond
                  # "required" — this generalized module has not independently re-derived why, only
                  # preserved it): without SYS_PTRACE + an unconfined seccomp profile, this ROCm base
                  # image's broker process fails to initialize the GPU correctly.
                  securityContext = {
                    capabilities.add = [ "SYS_PTRACE" ];
                    seccompProfile.type = "Unconfined";
                  };
                  volumeMounts = [
                    { name = "shared"; mountPath = "/shared"; }
                    { name = "config-d"; mountPath = generatedConfigDir; }
                  ] ++ modelVolumeMounts;
                }
                # Refresh sidecar (B10 "drop a file = served"): re-derive the config from the store on
                # every pollIntervalSeconds; the broker's --watch-config picks up changes in ~2s with no
                # restart. CPU-only, no device-resource request — this container never touches the GPU.
                {
                  name = "gen";
                  image = cfg.images.gen;
                  command = [
                    "sh"
                    "-c"
                    "while true; do sh /gen/gen-llama-swap.sh; sleep ${toString cfg.generator.pollIntervalSeconds}; done"
                  ];
                  env = genEnv;
                  resources.requests = { cpu = "10m"; memory = "16Mi"; };
                  volumeMounts = [
                    { name = "config-d"; mountPath = generatedConfigDir; }
                  ] ++ modelVolumeMounts ++ [
                    { name = "sys"; mountPath = cfg.generator.sysMountPath; readOnly = true; }
                    { name = "gen-script"; mountPath = "/gen"; }
                  ];
                }
              ];

              volumes = [
                { name = "shared"; emptyDir = { }; }
                { name = "config-d"; emptyDir = { }; } # generated llama-swap config (B10, derived/throwaway)
                { name = "gen-script"; configMap.name = "llm-serving-gen"; }
              ] ++ modelVolumes ++ [
                { name = "sys"; hostPath.path = cfg.sysHostPath; }
              ];
            };
          };
        };
      };

      resources.services.llama-broker.spec = {
        selector.app = "llama-broker";
        ports = [{ port = cfg.brokerPort; targetPort = cfg.brokerPort; }];
      };

      # LiteLLM — the single OpenAI-compatible door every consuming app targets. No memory limit: model
      # residency/eviction is entirely the broker's job (B4); LiteLLM itself just proxies.
      resources.deployments.litellm.metadata.labels.app = "litellm";
      resources.deployments.litellm.spec = {
        replicas = 1;
        selector.matchLabels.app = "litellm";
        template = {
          metadata.labels.app = "litellm";
          spec.containers = [{
            name = "litellm";
            image = cfg.images.litellm;
            args = [ "--config" "/etc/litellm/config.yaml" "--port" (toString cfg.litellm.port) "--host" "0.0.0.0" ];
            env = [{
              name = "LITELLM_MASTER_KEY";
              valueFrom.secretKeyRef = {
                name = cfg.litellm.existingSecretName;
                key = cfg.litellm.masterKeySecretKey;
              };
            }];
            ports = [{ containerPort = cfg.litellm.port; }];
            volumeMounts = [{ name = "cfg"; mountPath = "/etc/litellm"; }];
          }];
          spec.volumes = [{ name = "cfg"; configMap.name = "litellm-config"; }];
        };
      };

      resources.services.litellm.spec = {
        selector.app = "litellm";
        type = "ClusterIP";
        ports = [{ name = "http"; port = cfg.litellm.port; targetPort = cfg.litellm.port; }];
      } // lib.optionalAttrs (cfg.litellm.clusterIP != null) { clusterIP = cfg.litellm.clusterIP; };
    };
  };
}
