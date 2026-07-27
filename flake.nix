{
  description = "nixllm - self-hosted LLM serving where the model store IS the registry";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders the module below to Argo CD manifests. A real input, not
    # just a name in a comment: without it there is no module system to evaluate
    # `serving` against, and `nix flake check` passes by checking nothing. The
    # comment below used to call this module "render-checked" while no such check
    # existed — this input is what makes that claim true.
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
      # but not yet re-verified live.
      #
      # This is the shared serving door. It graduated out of the sibling app
      # cookbook once it developed a mechanism worth having independently of the
      # app: consumers ask it for a model by name and request no GPU of their own.
      nixidyModules = {
        serving = ./modules/serving;
        # Only module in this class — trivially the default.
        default = self.nixidyModules.serving;
      };

      lib = { };

      # Renders the module against the real module system it targets, from the
      # placeholder values in `examples/all`. Proves it evaluates and renders —
      # not that it serves a model correctly, which needs a card and weights.
      checks = forAllSystems (system:
        let
          env = nixidy.lib.mkEnv {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = nixpkgs.lib.attrValues self.nixidyModules
              ++ [ ./examples/all/values.nix ];
          };
        in
        {
          serving-renders = env.environmentPackage;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
