# Proves the mirror of the sibling nixgpu project's `nixgpu.sysfs.vramTotalAttr` (the amdgpu sysfs
# attribute name for total VRAM) works in BOTH directions, without nixllm depending on the real nixgpu
# flake at all — see modules/serving/default.nix's `vramTotalAttr` binding and its own comment.
#
#   1. `absent` — nothing in the environment ever declares `config.nixgpu`: the rendered broker
#      Deployment must carry `VRAM_TOTAL_ATTR = "mem_info_vram_total"` — today's hardcoded literal,
#      unchanged in effect, now surfaced via this module's own declared default
#      (`generator.vramTotalAttr`) instead of a string buried inside the generator script.
#   2. `present` — a STAND-IN module declares `nixgpu.sysfs.vramTotalAttr` to a name that is
#      deliberately NOT "mem_info_vram_total" (as if a kernel/driver rename had happened): the
#      rendered `VRAM_TOTAL_ATTR` must change to match it, proving the mirror actually reads the
#      value rather than only ever falling back to its own default.
#
# A stand-in, not the real nixgpu flake, on purpose: the whole point of the mirror pattern (the nix*
# family's `mirrorOf` idiom — see nixhost's modules/nixhost.nix) is that a sibling reads
# `config.nixgpu.X or default` WITHOUT requiring nixgpu as a flake input at all. Fetching the real
# nixgpu flake here just to test that would silently reintroduce the very dependency this design
# avoids — a check that quietly adds back what the feature exists to remove would be worse than no
# check.
{ pkgs, nixidy, servingModule, valuesModule }:
let
  fakeNixgpuPresent = { lib, ... }: {
    options.nixgpu.sysfs.vramTotalAttr = lib.mkOption {
      type = lib.types.str;
      default = "vram_total_bytes_v2"; # stands in for "a kernel rename happened"; must differ from the real default
    };
  };

  render = extraModules:
    (nixidy.lib.mkEnv {
      inherit pkgs;
      modules = [ servingModule valuesModule ] ++ extraModules;
    }).environmentPackage;

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
in
{
  absent = assertRenderedAttr (render [ ]) "mem_info_vram_total";
  present = assertRenderedAttr (render [ fakeNixgpuPresent ]) "vram_total_bytes_v2";
}
