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
