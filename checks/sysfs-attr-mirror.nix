# Proves the mirror of the sibling nixgpu project's `nixgpu.sysfs.vramTotalAttr` (the amdgpu sysfs
# attribute name for total VRAM) works in ALL THREE directions, without nixllm depending on the real
# nixgpu flake at all — see modules/serving/default.nix's `vramTotalAttr`/`vramMirrorDrifted` bindings
# and their own comment.
#
#   1. `absent` — nothing in the environment ever declares `config.nixgpu`: the rendered broker
#      Deployment must carry `VRAM_TOTAL_ATTR = "mem_info_vram_total"` — today's hardcoded literal,
#      unchanged in effect, now surfaced via this module's own declared default
#      (`generator.vramTotalAttr`) instead of a string buried inside the generator script. No mirror
#      warning fires: nixgpu was simply never adopted here, which must stay silent.
#   2. `present` — a STAND-IN module declares `nixgpu.sysfs.vramTotalAttr` to a name that is
#      deliberately NOT "mem_info_vram_total" (as if the underlying kernel/driver attribute's VALUE
#      had changed): the rendered `VRAM_TOTAL_ATTR` must change to match it, proving the mirror
#      actually reads the value rather than only ever falling back to its own default. No warning
#      fires: the mirror resolved correctly, it just resolved to something else.
#   3. `renamed` — a DIFFERENT stand-in contributes an unrelated nixgpu option (proving nixgpu itself
#      is adopted here) but never declares `nixgpu.sysfs.vramTotalAttr` at all — the actual bug class
#      `vramMirrorDrifted` exists to catch: the NIX OPTION PATH this module reads moved out from under
#      it while nixgpu stayed imported. The rendered value must still fall back correctly (same as
#      `absent`) — AND, unlike `absent`, a nixidy warning MUST fire, because this time the silence
#      would be hiding a real drift rather than an expected non-adoption.
#
# A stand-in, not the real nixgpu flake, on purpose: the whole point of the mirror pattern (the nix*
# family's `mirrorOf` idiom — see nixhost's modules/nixhost.nix) is that a sibling reads
# `config.nixgpu.X or default` WITHOUT requiring nixgpu as a flake input at all. Fetching the real
# nixgpu flake here just to test that would silently reintroduce the very dependency this design
# avoids — a check that quietly adds back what the feature exists to remove would be worse than no
# check.
{ pkgs, nixidy, servingModule, valuesModule }:
let
  lib = pkgs.lib;

  fakeNixgpuPresent = { lib, ... }: {
    options.nixgpu.sysfs.vramTotalAttr = lib.mkOption {
      type = lib.types.str;
      default = "vram_total_bytes_v2"; # stands in for "the kernel attribute's VALUE changed"; must differ from the real default
    };
  };

  fakeNixgpuRenamed = { lib, ... }: {
    # Proves nixgpu is adopted (some option under `nixgpu.*` exists) WITHOUT declaring
    # `nixgpu.sysfs.vramTotalAttr` — simulating that specific option path moving elsewhere, the way it
    # already moved once in nixgpu itself (nixgpu commit 53bab80, the same day this check was added).
    options.nixgpu.deviceTokens.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  mkEnv = extraModules:
    nixidy.lib.mkEnv {
      inherit pkgs;
      modules = [ servingModule valuesModule ] ++ extraModules;
    };

  render = extraModules: (mkEnv extraModules).environmentPackage;

  # Both the gen-init initContainer and the gen refresh sidecar carry genEnv, so the expected value
  # must appear at least twice in the rendered Deployment.
  assertRenderedAttr = drv: expected:
    pkgs.runCommand "sysfs-attr-mirror-assert-${builtins.replaceStrings [ "/" ] [ "-" ] expected}"
      { } ''
      deployment="${drv}/llm-serving/Deployment-llama-broker.yaml"
      n=$(grep -c 'value: ${expected}$' "$deployment" || true)
      if [ "$n" -lt 2 ]; then
        echo "expected VRAM_TOTAL_ATTR = ${expected} at least twice (gen-init + gen sidecar), found $n" >&2
        echo "--- rendered Deployment ---" >&2
        cat "$deployment" >&2
        exit 1
      fi
      touch $out
    '';

  # Proves the OTHER half of the fix: whether a nixidy mirror-drift warning is present on
  # `applications.llm-serving.warnings` for a given extra-modules set. Reads `.config` directly, not
  # `.environmentPackage` — nixidy's own warning printer (`traceIfWarnings` in its `modules/default.nix`)
  # only surfaces warnings as a `builtins.trace` side effect when a *build output* is forced, which a
  # Nix expression cannot assert against structurally; the (already-`apply`-normalized, so always
  # `{ when, message, context }`) option value itself is the checkable fact.
  hasMirrorWarning = extraModules:
    builtins.any (w: w.when) (mkEnv extraModules).config.applications.llm-serving.warnings;

  assertWarningState = name: extraModules: expected:
    let actual = hasMirrorWarning extraModules;
    in
    pkgs.runCommand "sysfs-attr-mirror-warning-${name}" { } ''
      if [ "${lib.boolToString actual}" != "${lib.boolToString expected}" ]; then
        echo "expected mirror-drift warning present=${lib.boolToString expected} for '${name}', got ${lib.boolToString actual}" >&2
        exit 1
      fi
      touch $out
    '';
in
{
  absent = assertRenderedAttr (render [ ]) "mem_info_vram_total";
  present = assertRenderedAttr (render [ fakeNixgpuPresent ]) "vram_total_bytes_v2";
  renamed = assertRenderedAttr (render [ fakeNixgpuRenamed ]) "mem_info_vram_total";

  warning-absent = assertWarningState "absent" [ ] false;
  warning-present = assertWarningState "present" [ fakeNixgpuPresent ] false;
  warning-renamed = assertWarningState "renamed" [ fakeNixgpuRenamed ] true;
}
