# Placeholder values for every nixidy module in this repository — the file that
# makes the render check real. `nix flake check` renders the serving lane from
# here, so a module that stops evaluating, or that grows a required value nobody
# supplies, fails in CI rather than in somebody's cluster.
#
# Nothing here is real: the path is under /var/lib/example and no credential
# appears in any form.
{
  # Required by the nixidy environment itself, not by the module.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixllm.serving = {
    enable = true;

    # The one option in this module with no default, and the idea the project is
    # named for: the model store IS the registry. There is no portable answer to
    # where a multi-gigabyte weights directory lives, so the module refuses to
    # guess and fails by name until told.
    modelStoreHostPath = "/var/lib/example/models";

    # Two model aliases, on purpose. `generator.aliases` defaults to empty, and
    # the routing table is the interesting half of this module — a check with no
    # aliases would pass while never rendering a route. Each maps a short name a
    # caller asks for to a weights file inside the store above.
    generator.aliases = {
      "example-chat" = "chat/Example-Chat-Model-Q8_0.gguf";
      "example-embed" = "embeddings/Example-Embedding-Model-F16.gguf";
    };

    gpu = {
      # Also required, also no default (nixgpu commit 521f4ef): a node selector is
      # a fact about THIS example's node labels, not about GPUs. Any real caller
      # states their own cluster's convention here instead.
      nodeSelector = { gpu = "amd"; };

      # Also required: the example card is an RDNA2 part, which needs this
      # override. A real caller looks up their own card's value from ROCm's
      # supported-GPU list, or sets "" on a card ROCm already supports natively.
      hsaOverrideGfxVersion = "10.3.0";
    };
  };
}
