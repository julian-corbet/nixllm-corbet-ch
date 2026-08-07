# Native workstation tools that interact with models or model-serving APIs.  GPU drivers, runtimes,
# and generic compute bindings stay in nixgpu; these entries are the clients, inference engines,
# and conversion tools which use that substrate.
{ ... }:
{
  tools = {
    anythingllm-cli = { arch = "anythingllm-cli-bin"; aur = true; };
    intel-llm = { arch = "intel-llm"; aur = true; };
    intel-llm-convert = { arch = "intel-llm-convert"; aur = true; };
    litert-lm = { arch = "litert-lm"; aur = true; };
    llama-cpp-sycl = { arch = "llama.cpp-sycl-bin"; aur = true; };

    # LM Studio: a desktop app for downloading and running local GGUF models, with
    # its own chat UI and an OpenAI-compatible local server. The one GUI entry in
    # this catalogue — every other tool here is a CLI or library — but the file's
    # scope above is "clients, inference engines, and conversion tools," not
    # "headless tools," and LM Studio is itself a llama.cpp-based inference engine
    # as much as a chat client, so it fits without stretching the boundary. It is
    # the approachable end of local inference: good for pulling a model and trying
    # it in minutes. It is not the route for a big or shared workload — that stays
    # this repo's own llama-swap + llama.cpp broker (modules/serving), which fits
    # one card to many callers on demand instead of one app holding it for itself.
    # AUR-only, confirmed rather than guessed from the "-bin" suffix: absent from
    # `pacman -Si lmstudio-bin`, present in the AUR RPC. No nixpkgs attribute,
    # matching every other AUR entry here — AI tools come from the AUR, never
    # nixpkgs, because they self-update in place and a nixpkgs derivation breaks
    # that update path.
    lmstudio = { arch = "lmstudio-bin"; aur = true; };

    openvino-genai = { arch = "openvino-genai-bin"; aur = true; };
    python-openai = { arch = "python-openai"; };
    python-openai-whisper = { arch = "python-openai-whisper"; };
    python-transformers = { arch = "python-transformers"; };

    # The C/C++ port of the Python entry above: faster and lighter, wanted for transcript-driven
    # editing — transcribe a recording, edit the text, and the cut follows the words. It is the
    # one AI-assisted editing workflow that genuinely works today. Arch package name is
    # "whisper-cpp", not "whisper.cpp" (that is the upstream project name the description points
    # at); official repo (cachyos-extra-v3/extra), confirmed with `pacman -Si whisper-cpp`.
    whisper-cpp = { arch = "whisper-cpp"; };
  };
}
