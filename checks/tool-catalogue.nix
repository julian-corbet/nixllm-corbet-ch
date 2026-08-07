{ lib, pkgs, toolsModule }:
let
  check = name: ok: detail: { inherit name ok detail; };
  eval = values: (lib.evalModules { modules = [ toolsModule values ]; }).config;
  all = eval {
    nixllm.tools = [
      "anythingllm-cli"
      "intel-llm"
      "intel-llm-convert"
      "litert-lm"
      "llama-cpp-sycl"
      "lmstudio"
      "openvino-genai"
      "python-openai"
      "python-openai-whisper"
      "python-transformers"
      "whisper-cpp"
    ];
  };
  results = [
    (check "tools/official-packages-stay-out-of-aur"
      (all.nixllm.archPackages == [ "python-openai" "python-openai-whisper" "python-transformers" "whisper-cpp" ])
      "got: ${builtins.toJSON all.nixllm.archPackages}")
    (check "tools/aur-packages-stay-out-of-pacman"
      (all.nixllm.aurPackages == [ "anythingllm-cli-bin" "intel-llm" "intel-llm-convert" "litert-lm" "llama.cpp-sycl-bin" "lmstudio-bin" "openvino-genai-bin" ])
      "got: ${builtins.toJSON all.nixllm.aurPackages}")
  ];
  failed = lib.filter (result: !result.ok) results;
in
if failed == [ ] then
# A real derivation, not `builtins.toFile` — a flake `checks.<system>.<name>` output must be one
# (drvPath and all) or `nix flake check` rejects it with "is not a derivation" even though the
# tests above all passed. `pkgs.writeText` matches the sibling `sysfs-attr-mirror.nix` check's use
# of `pkgs.runCommand` for the same reason.
  pkgs.writeText "nixllm-tool-catalogue" "all ${toString (builtins.length results)} NixLLM tool-catalogue tests passed\n"
else
  throw "nixllm tool-catalogue tests failed: ${builtins.toJSON failed}"
