# Platform-neutral selection of NixLLM workstation tools. Arch consumers receive separate official
# repository and AUR lists so one AUR name cannot poison the Pacman transaction.
{ config, lib, ... }:
let
  cfg = config.nixllm;
  catalogue = import ../lib/tools.nix { };
  selected = map (name: catalogue.tools.${name}) cfg.tools;
in
{
  options.nixllm = {
    tools = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames catalogue.tools));
      default = [ ];
      description = "NixLLM workstation tools to declare.";
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selected official-repository Arch package names.";
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selected AUR package names, kept separate from Pacman packages.";
    };
  };

  config = {
    nixllm.archPackages = lib.unique (map (tool: tool.arch) (lib.filter (tool: !(tool.aur or false)) selected));
    nixllm.aurPackages = lib.unique (map (tool: tool.arch) (lib.filter (tool: tool.aur or false) selected));
  };
}
