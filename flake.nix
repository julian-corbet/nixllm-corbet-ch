{
  description = "nixllm - self-hosted LLM serving where the model store IS the registry";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders the module below to Argo CD manifests. A real input, not
    # just a name in a comment: without it there is no module system to evaluate
    # `serving` against, and `nix flake check` passes by checking nothing.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # nixidy module (github:arnarg/nixidy) — imported into a nixidy env's
      # `modules` list and rendered to manifests for Argo CD. Extracted from a
      # production cluster; the generalized form is render-checked (see `checks`)
      # AND has been running live there, adopted in-place, since 2026-07-22 — see
      # the repo README's Status section.
      #
      # This is the shared serving door. It graduated out of the sibling app
      # cookbook once it developed a mechanism worth having independently of the
      # app: consumers ask it for a model by name and request no GPU of their own.
      nixidyModules = {
        serving = ./modules/serving;
        # Only module in this class — trivially the default.
        default = self.nixidyModules.serving;
      };

      # Arch/CachyOS package-selection plane for local model clients and engines. It deliberately
      # does not install a GPU runtime: that substrate is the sibling nixgpu project's concern.
      systemManagerModules.tools = ./modules/system-manager.nix;

      lib = { };

      # Renders the module against the real module system it targets, from the
      # placeholder values in `examples/all`. Proves it evaluates and renders —
      # not that it serves a model correctly, which needs a card and weights.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = nixpkgs.lib.attrValues self.nixidyModules
              ++ [ ./examples/all/values.nix ];
          };

          # Proves the nixgpu.sysfs.vramTotalAttr mirror (modules/serving/default.nix) in all three
          # directions — unchanged when nixgpu is unadopted, actually wired when it is, and visibly
          # (not silently) falling back when nixgpu is adopted but has renamed the option out from
          # under this module. See the file's own header.
          sysfsMirror = import ./checks/sysfs-attr-mirror.nix {
            inherit pkgs nixidy;
            servingModule = self.nixidyModules.serving;
            valuesModule = ./examples/all/values.nix;
          };

          toolCatalogue = import ./checks/tool-catalogue.nix {
            inherit (nixpkgs) lib;
            inherit pkgs;
            toolsModule = self.systemManagerModules.tools;
          };
        in
        {
          serving-renders = env.environmentPackage;
          sysfs-attr-mirror-absent = sysfsMirror.absent;
          sysfs-attr-mirror-present = sysfsMirror.present;
          sysfs-attr-mirror-renamed = sysfsMirror.renamed;
          sysfs-attr-mirror-warning-absent = sysfsMirror.warning-absent;
          sysfs-attr-mirror-warning-present = sysfsMirror.warning-present;
          sysfs-attr-mirror-warning-renamed = sysfsMirror.warning-renamed;
          tool-catalogue = toolCatalogue;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
