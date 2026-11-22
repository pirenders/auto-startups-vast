#!/bin/bash
# ---
# name: MiniMax H3 Image — T2I & Image Edit workflows
# workflow: image_minimax_h3_image_t2i, image_minimax_h3_image_edit
# aliases: [minimax-h3-image, h3-image, minimax-h3-t2i, minimax-h3-edit]
# description: Installs or upgrades ComfyUI (>= v0.46.0), provisions the models required by the MiniMax H3 Image T2I and Image Edit workflows (Comfy-Org/MiniMax-H3-Image), and on Lium exposes ComfyUI via a Cloudflare Quick Tunnel (trycloudflare) saved to /workspace/comfyui_url.txt. All nodes in both workflows are ComfyUI core nodes (no custom-node packs required).
# size: ~57GB default (int8 UNET + int8 32B text encoder + Qwen3.5 9B prompt enhancer + fp16 VAE); ~90GB with --all-models
# min_vram: 24GB
# nodes: []
# usage: ./image_script.sh [--interactive] [--platform=lium|vast|runpod] [--workflows=t2i,edit|all] [--diffusion=int8|w4a8|bf16] [--text-encoder=int8|nvfp4|both] [--prompt-enhancer=9b|27b|both|none] [--all-models]
#   --interactive        Prompt for HF_TOKEN (hidden), platform, workflows, diffusion quant, text encoder, and prompt enhancer.
#                        Needs a TTY (tmux pane or foreground shell).
#   --platform=          Force platform: lium, vast, or runpod (auto-detected by default).
#                        On Lium: installs ComfyUI if missing, installs cloudflared, and publishes a trycloudflare URL to /workspace/comfyui_url.txt (and /root/comfyui_url.txt).
#   --workflows=         Which image workflows to provision (or env WORKFLOWS=...).
#                        Non-interactive default: all.
#     t2i                MiniMax H3 Image Text-to-Image  (image_minimax_h3_image_t2i.json)
#     edit               MiniMax H3 Image Edit           (image_minimax_h3_image_edit.json)
#   --diffusion=         Diffusion model quantization from Comfy-Org/MiniMax-H3-Image (default: int8):
#     int8               minimax_h3_image_pruned_int8_convrot.safetensors  (~21.0 GB) [default, wired in workflows]
#     w4a8               minimax_h3_image_pruned_w4a8.safetensors          (~12.6 GB)
#     bf16               minimax_h3_image_pruned_bf16.safetensors          (~40.2 GB)
#   --text-encoder=      Main Qwen3-VL 32B text encoder from Comfy-Org/MiniMax-H3-Image (default: int8):
#     int8               qwen3vl_32b_minimax_h3_int8_convrot.safetensors   (~27.1 GB) [default, wired in workflows]
#     nvfp4              qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors      (~15.7 GB)
#     both               Download both int8 and nvfp4 text encoders
#   --prompt-enhancer=   Prompt Enhancer LLM for TextGenerateV2 (default: 9b):
#     9b                 qwen3.5_9b_w4a8_gptq.safetensors                         (~7.3 GB)  [default, wired in workflows]
#     27b                qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors    (~17.3 GB) [official recommended PE]
#     both               Download both 9B and 27B prompt enhancers
#     none               Skip prompt enhancer models
#   --all-models         Shorthand for --text-encoder=both --prompt-enhancer=both (downloads every file in the model card tree).
# ---

set -e

MIN_CORE="0.46.0"
HF_REPO="Comfy-Org/MiniMax-H3-Image"

# ── Workflow & option defaults ──
ALL_WORKFLOWS="t2i edit"
WORKFLOWS_ARG="${WORKFLOWS:-}"
PLATFORM_ARG="${PLATFORM:-}"
DIFFUSION_CHOICE="${DIFFUSION_CHOICE:-int8}"
TEXT_ENC_CHOICE="${TEXT_ENC_CHOICE:-int8}"
PE_CHOICE="${PE_CHOICE:-9b}"

want() { case " $SELECTED_WORKFLOWS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
normalize_workflows() {
    local out="" tok
    for tok in $(echo "$1" | tr ',;' '  ' | tr 'A-Z' 'a-z'); do
        case "$tok" in
            all) out="$ALL_WORKFLOWS" ;;
            t2i|text2img|txt2img|image_t2i) out="$out t2i" ;;
            edit|i2i|img2img|image_edit) out="$out edit" ;;
            *) echo "  ⚠️  Unknown workflow '$tok' — ignored (use: t2i edit all)" >&2 ;;
        esac
    done
    for tok in $ALL_WORKFLOWS; do
        case " $out " in *" $tok "*) printf '%s ' "$tok" ;; esac
    done
}

# ── CLI args ──
INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE=1 ;;
        --platform=*) PLATFORM_ARG="$(echo "${arg#--platform=}" | tr 'A-Z' 'a-z')" ;;
        --workflows=*) WORKFLOWS_ARG="${arg#--workflows=}" ;;
        --diffusion=*) DIFFUSION_CHOICE="${arg#--diffusion=}" ;;
        --text-encoder=*) TEXT_ENC_CHOICE="${arg#--text-encoder=}" ;;
        --prompt-enhancer=*) PE_CHOICE="${arg#--prompt-enhancer=}" ;;
        --all-models)
            TEXT_ENC_CHOICE="both"
            PE_CHOICE="both"
            ;;
        -h|--help)
            sed -n '/^# usage:/,/^# ---$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "⚠️  Ignoring unknown argument: $arg" ;;
    esac
done

# ── Platform Detection ──
echo "==> Detecting platform..."
FRESH_INSTALL=0
if [ -n "$PLATFORM_ARG" ]; then
    PLATFORM="$PLATFORM_ARG"
    if [ "$PLATFORM" = "runpod" ] && [ -d "/workspace/runpod-slim" ]; then
        COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
    else
        COMFYUI_DIR="/workspace/ComfyUI"
    fi
    echo "  ✅ Platform selected: $PLATFORM (COMFYUI_DIR=$COMFYUI_DIR)"
elif [ -n "${LIUM_VOLUME_PATH:-}" ] || [ -d "/lium-cipher" ]; then
    PLATFORM="lium"
    COMFYUI_DIR="/workspace/ComfyUI"
    echo "  ✅ Lium detected (LIUM_VOLUME_PATH=${LIUM_VOLUME_PATH:-/root})"
elif [ -d "/workspace/runpod" ]; then
    PLATFORM="runpod"
    COMFYUI_DIR="/workspace/ComfyUI"
    echo "  ✅ RunPod detected"
elif [ -d "/workspace/runpod-slim" ]; then
    PLATFORM="runpod"
    COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
    echo "  ✅ RunPod (slim) detected"
elif [ -d "/workspace/ComfyUI" ]; then
    PLATFORM="vast"
    COMFYUI_DIR="/workspace/ComfyUI"
    echo "  ✅ Vast.ai detected"
else
    PLATFORM="vast"
    COMFYUI_DIR="/workspace/ComfyUI"
    echo "  ℹ️  ComfyUI not found — will install fresh into $COMFYUI_DIR"
fi

# ── Model summary helper ──
resolve_diffusion_file() {
    case "$DIFFUSION_CHOICE" in
        int8) DIFFUSION_FILE="diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors"; DIFFUSION_DESC="minimax_h3_image_pruned_int8_convrot.safetensors (~21.0 GB)" ;;
        w4a8) DIFFUSION_FILE="diffusion_models/minimax_h3_image_pruned_w4a8.safetensors";         DIFFUSION_DESC="minimax_h3_image_pruned_w4a8.safetensors (~12.6 GB)" ;;
        bf16) DIFFUSION_FILE="diffusion_models/minimax_h3_image_pruned_bf16.safetensors";         DIFFUSION_DESC="minimax_h3_image_pruned_bf16.safetensors (~40.2 GB)" ;;
        *)
            echo "  ⚠️  Unknown --diffusion='$DIFFUSION_CHOICE' — falling back to int8"
            DIFFUSION_CHOICE="int8"
            DIFFUSION_FILE="diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors"
            DIFFUSION_DESC="minimax_h3_image_pruned_int8_convrot.safetensors (~21.0 GB)"
            ;;
    esac
}

print_download_summary() {
    resolve_diffusion_file
    local wf_preview
    wf_preview="$(normalize_workflows "${WORKFLOWS_ARG:-all}")"
    [ -z "${wf_preview// /}" ] && wf_preview="$ALL_WORKFLOWS"
    echo "==> Download summary ($HF_REPO)"
    echo "    Platform:        $PLATFORM ($COMFYUI_DIR)"
    echo "    Workflows:       $wf_preview"
    echo "    Diffusion model: $DIFFUSION_DESC"
    echo "    Image VAE:       minimax_h3_image_vae_fp16.safetensors (~1.2 GB)"
    case "$TEXT_ENC_CHOICE" in
        int8)  echo "    Text encoder:    qwen3vl_32b_minimax_h3_int8_convrot.safetensors (~27.1 GB)" ;;
        nvfp4) echo "    Text encoder:    qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors (~15.7 GB)" ;;
        both)  echo "    Text encoders:   qwen3vl_32b_minimax_h3_int8_convrot.safetensors (~27.1 GB) + nvfp4_awq (~15.7 GB)" ;;
        *)     echo "    Text encoder:    qwen3vl_32b_minimax_h3_int8_convrot.safetensors (~27.1 GB)" ;;
    esac
    case "$PE_CHOICE" in
        9b)   echo "    Prompt enhancer: qwen3.5_9b_w4a8_gptq.safetensors (~7.3 GB)" ;;
        27b)  echo "    Prompt enhancer: qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors (~17.3 GB)" ;;
        both) echo "    Prompt enhancer: qwen3.5_9b_w4a8_gptq.safetensors (~7.3 GB) + qwen3.8_27b_pe (~17.3 GB)" ;;
        none) echo "    Prompt enhancer: none (skipped)" ;;
        *)    echo "    Prompt enhancer: qwen3.5_9b_w4a8_gptq.safetensors (~7.3 GB)" ;;
    esac
}

# ── Interactive prompts (--interactive) ──
if [ "$INTERACTIVE" = "1" ]; then
    echo "==> Interactive mode — collecting HF_TOKEN"
    if [ ! -t 0 ]; then
        echo "  ⚠️  stdin is not a TTY — nothing to read."
        echo "      Run in a tmux pane or a foreground shell (no stdin pipe), then re-run."
    else
        if [ -n "${HF_TOKEN:-}" ]; then
            echo "  ℹ️  HF_TOKEN already in env (${#HF_TOKEN} chars) — press Enter to keep it."
        fi
        read -rsp "  🔑 Enter HF_TOKEN (hidden, Enter = use existing env/config): " _HF_INPUT || true
        echo
        if [ -n "${_HF_INPUT:-}" ]; then
            export HF_TOKEN="$_HF_INPUT"
            case "$HF_TOKEN" in
                hf_*) echo "  ✅ HF_TOKEN set (${#HF_TOKEN} chars)" ;;
                *)    echo "  ⚠️  HF_TOKEN does not start with 'hf_' — continuing, but downloads may 401." ;;
            esac
            unset _HF_INPUT
        else
            echo "  ℹ️  No input — falling back to \$HF_TOKEN / /root/config/token.json"
        fi
    fi

    print_download_summary
    _MODIFY_INPUT=""
    if [ -t 0 ]; then
        read -rp "  ▶️  Press Enter to continue, or type M to modify selections [Enter/M]: " _MODIFY_INPUT || true
    fi

    case "${_MODIFY_INPUT:-}" in
        m|M|modify|MODIFY)
            if [ -z "$PLATFORM_ARG" ] && [ -t 0 ]; then
                read -rp "  🖥️  Platform (lium/vast/runpod) [$PLATFORM]: " _PLAT_INPUT || true
                if [ -n "${_PLAT_INPUT:-}" ]; then
                    PLATFORM="$(echo "$_PLAT_INPUT" | tr 'A-Z' 'a-z')"
                    [ "$PLATFORM" = "runpod" ] && [ -d "/workspace/runpod-slim" ] \
                        && COMFYUI_DIR="/workspace/runpod-slim/ComfyUI" \
                        || COMFYUI_DIR="/workspace/ComfyUI"
                fi
                unset _PLAT_INPUT
            fi

            echo "==> Choose workflows to provision"
            echo "    t2i   MiniMax H3 Image Text-to-Image  (image_minimax_h3_image_t2i.json)"
            echo "    edit  MiniMax H3 Image Edit           (image_minimax_h3_image_edit.json)"
            read -rp "  🧩 Workflows (comma-separated, or 'all') [${WORKFLOWS_ARG:-all}]: " _WF_INPUT || true
            [ -n "${_WF_INPUT:-}" ] && WORKFLOWS_ARG="$_WF_INPUT"
            unset _WF_INPUT

            echo "==> Choose diffusion model quantization ($HF_REPO)"
            echo "    1) minimax_h3_image_pruned_int8_convrot.safetensors  (~21.0 GB) [default]"
            echo "    2) minimax_h3_image_pruned_w4a8.safetensors          (~12.6 GB)"
            echo "    3) minimax_h3_image_pruned_bf16.safetensors          (~40.2 GB)"
            read -rp "  🎨 Diffusion model [1]: " _D_INPUT || true
            case "${_D_INPUT:-1}" in
                2|w4a8) DIFFUSION_CHOICE="w4a8" ;;
                3|bf16) DIFFUSION_CHOICE="bf16" ;;
                1|int8|"") DIFFUSION_CHOICE="int8" ;;
                *) echo "  ⚠️  Unrecognised choice '$_D_INPUT' — keeping $DIFFUSION_CHOICE" ;;
            esac
            unset _D_INPUT

            echo "==> Choose main text encoder (Qwen3-VL 32B)"
            echo "    1) qwen3vl_32b_minimax_h3_int8_convrot.safetensors   (~27.1 GB) [default]"
            echo "    2) qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors      (~15.7 GB)"
            echo "    3) both                                              (~42.8 GB)"
            read -rp "  🧠 Text encoder [1]: " _TE_INPUT || true
            case "${_TE_INPUT:-1}" in
                2|nvfp4) TEXT_ENC_CHOICE="nvfp4" ;;
                3|both)  TEXT_ENC_CHOICE="both" ;;
                1|int8|"") TEXT_ENC_CHOICE="int8" ;;
                *) echo "  ⚠️  Unrecognised choice '$_TE_INPUT' — keeping $TEXT_ENC_CHOICE" ;;
            esac
            unset _TE_INPUT

            echo "==> Choose Prompt Enhancer (TextGenerateV2)"
            echo "    1) qwen3.5_9b_w4a8_gptq.safetensors                      (~7.3 GB)  [default, wired in workflows]"
            echo "    2) qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors (~17.3 GB) [official recommended PE]"
            echo "    3) both                                                  (~24.6 GB)"
            echo "    4) none                                                  (skip)"
            read -rp "  ✨ Prompt enhancer [1]: " _PE_INPUT || true
            case "${_PE_INPUT:-1}" in
                2|27b)  PE_CHOICE="27b" ;;
                3|both) PE_CHOICE="both" ;;
                4|none) PE_CHOICE="none" ;;
                1|9b|"") PE_CHOICE="9b" ;;
                *) echo "  ⚠️  Unrecognised choice '$_PE_INPUT' — keeping $PE_CHOICE" ;;
            esac
            unset _PE_INPUT
            ;;
    esac
    unset _MODIFY_INPUT
fi

BASE_DIR="$COMFYUI_DIR/models"
IMAGES_PATH="$COMFYUI_DIR/input"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"

SELECTED_WORKFLOWS="$(normalize_workflows "${WORKFLOWS_ARG:-all}")"
if [ -z "${SELECTED_WORKFLOWS// /}" ]; then
    echo "  ⚠️  No valid workflow in '${WORKFLOWS_ARG}' — provisioning all."
    SELECTED_WORKFLOWS="$ALL_WORKFLOWS"
fi

resolve_diffusion_file

echo "  ✅ Platform:        $PLATFORM"
echo "  ✅ Workflows:       $SELECTED_WORKFLOWS"
echo "  ✅ Diffusion model: $(basename "$DIFFUSION_FILE")"
echo "  ✅ Text encoder:    $TEXT_ENC_CHOICE"
echo "  ✅ Prompt enhancer: $PE_CHOICE"

# ── Phase 0: Install ComfyUI if missing, or upgrade to latest (>= v0.46.0) ──
echo "==> Phase 0: Checking ComfyUI installation and version (minimum v$MIN_CORE)..."
ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

if [ ! -d "$COMFYUI_DIR" ] || [ ! -f "$COMFYUI_DIR/main.py" ]; then
    echo "  📥 ComfyUI not installed at $COMFYUI_DIR — cloning latest ComfyUI..."
    mkdir -p "$(dirname "$COMFYUI_DIR")"
    if [ -d "$COMFYUI_DIR" ] && [ ! -d "$COMFYUI_DIR/.git" ]; then
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}.tmp_clone"
        cp -rn "${COMFYUI_DIR}.tmp_clone/." "$COMFYUI_DIR/" 2>/dev/null || cp -r "${COMFYUI_DIR}.tmp_clone/." "$COMFYUI_DIR/"
        rm -rf "${COMFYUI_DIR}.tmp_clone"
    else
        git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    fi
    FRESH_INSTALL=1
    UPGRADED=1
fi

CURRENT_VERSION=$(git -C "$COMFYUI_DIR" describe --tags 2>/dev/null | sed 's/^v//' || true)
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION=$(python3 -c "import importlib.metadata; print(importlib.metadata.version('comfy'))" 2>/dev/null || echo "unknown")
fi
echo "  Current ComfyUI version: $CURRENT_VERSION"

NEED_UPGRADE=0
if [ "$FRESH_INSTALL" = "1" ] || \
   [ "$CURRENT_VERSION" = "unknown" ] || \
   ! ver_ge "$CURRENT_VERSION" "$MIN_CORE"; then
    NEED_UPGRADE=1
fi
grep -rq "MiniMaxH3ImageConditioning" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null || NEED_UPGRADE=1
grep -rq "TextGenerateV2" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null || NEED_UPGRADE=1

if [ "$NEED_UPGRADE" = "1" ]; then
    echo "  ⚠️  ComfyUI $CURRENT_VERSION needs upgrade (require >= v$MIN_CORE + MiniMax-H3-Image nodes)..."
    git -C "$COMFYUI_DIR" stash --quiet 2>/dev/null || true
    git -C "$COMFYUI_DIR" fetch origin --tags --quiet 2>/dev/null || \
        git -C "$COMFYUI_DIR" fetch origin master --depth=1 --quiet 2>/dev/null || true
    TARGET_TAG=$(git -C "$COMFYUI_DIR" tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]' | head -1 || true)
    if [ -n "$TARGET_TAG" ] && ver_ge "${TARGET_TAG#v}" "$MIN_CORE"; then
        echo "  📥 Checking out latest release tag: $TARGET_TAG"
        git -C "$COMFYUI_DIR" checkout "$TARGET_TAG" --quiet 2>/dev/null || \
            git -C "$COMFYUI_DIR" checkout -f "$TARGET_TAG" --quiet 2>/dev/null || true
    else
        echo "  📥 No release tag >= v$MIN_CORE found — updating to origin/master"
        git -C "$COMFYUI_DIR" fetch origin master --quiet 2>/dev/null || true
        git -C "$COMFYUI_DIR" checkout origin/master --quiet 2>/dev/null || \
            git -C "$COMFYUI_DIR" checkout origin/master -- . 2>/dev/null || \
            git -C "$COMFYUI_DIR" checkout origin/main -- . 2>/dev/null || true
    fi
    UPGRADED=1
    V2=$(git -C "$COMFYUI_DIR" describe --tags 2>/dev/null | sed 's/^v//' || echo "master")
    if grep -rq "MiniMaxH3ImageConditioning" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null && \
       grep -rq "TextGenerateV2" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null; then
        echo "  ✅ ComfyUI ready at $V2 — MiniMax H3 Image core nodes present"
    elif [ -n "$TARGET_TAG" ] && ver_ge "${TARGET_TAG#v}" "$MIN_CORE"; then
        echo "  ⚠️  ComfyUI upgraded to $V2 (>= v$MIN_CORE), but MiniMaxH3ImageConditioning/TextGenerateV2 not found via grep — continuing."
    else
        echo "  ❌ Upgrade incomplete: ComfyUI ($V2) still lacks >= v$MIN_CORE / MiniMaxH3ImageConditioning."
        exit 1
    fi
else
    echo "  ✅ ComfyUI $CURRENT_VERSION >= $MIN_CORE with MiniMax H3 Image core nodes — no upgrade needed"
fi

# ── Detect (or create) ComfyUI Python ──
echo "==> Detecting ComfyUI Python..."
if [ -f "/venv/main/bin/python" ]; then
    COMFY_PYTHON="/venv/main/bin/python"
    COMFY_PIP="/venv/main/bin/pip"
    echo "  ✅ Found /venv/main/bin/python"
elif [ -f "$COMFYUI_DIR/venv/bin/activate" ]; then
    source "$COMFYUI_DIR/venv/bin/activate"
    COMFY_PYTHON="$COMFYUI_DIR/venv/bin/python"
    COMFY_PIP="$COMFYUI_DIR/venv/bin/pip"
    echo "  ✅ Found $COMFYUI_DIR/venv"
elif [ -f "$COMFYUI_DIR/.venv-cu128/bin/activate" ]; then
    source "$COMFYUI_DIR/.venv-cu128/bin/activate"
    COMFY_PYTHON="$COMFYUI_DIR/.venv-cu128/bin/python"
    COMFY_PIP="$COMFYUI_DIR/.venv-cu128/bin/pip"
    echo "  ✅ Found $COMFYUI_DIR/.venv-cu128"
elif python3 -c "import torch; assert torch.cuda.is_available()" >/dev/null 2>&1; then
    # Lium PyTorch images ship CUDA-enabled PyTorch in system Python with PIP_BREAK_SYSTEM_PACKAGES=1
    export PIP_BREAK_SYSTEM_PACKAGES=1
    COMFY_PYTHON="$(command -v python3)"
    COMFY_PIP="$(command -v pip3 || command -v pip)"
    TORCH_INFO="$($COMFY_PYTHON -c 'import torch; print(torch.__version__, "CUDA", torch.version.cuda)' 2>/dev/null || true)"
    echo "  ✅ Using system Python with preinstalled PyTorch ($TORCH_INFO)"
elif [ "$FRESH_INSTALL" = "1" ]; then
    echo "  📥 No venv and no CUDA PyTorch in system Python — creating $COMFYUI_DIR/venv..."
    python3 -m venv "$COMFYUI_DIR/venv"
    source "$COMFYUI_DIR/venv/bin/activate"
    COMFY_PYTHON="$COMFYUI_DIR/venv/bin/python"
    COMFY_PIP="$COMFYUI_DIR/venv/bin/pip"
    $COMFY_PIP install -q --upgrade pip
    echo "  📥 Installing PyTorch (CUDA 12.8)..."
    $COMFY_PIP install -q torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu128 2>&1 | tail -5
else
    export PIP_BREAK_SYSTEM_PACKAGES=1
    COMFY_PYTHON="python3"
    COMFY_PIP="pip3"
    echo "  ⚠️  Using system Python"
fi

# ── Phase 0b: Refresh ComfyUI Python deps after install or core upgrade ──
if [ "${UPGRADED:-0}" = "1" ] && [ -f "$COMFYUI_DIR/requirements.txt" ]; then
    echo "==> Phase 0b: Installing ComfyUI requirements..."
    $COMFY_PIP install -q -r "$COMFYUI_DIR/requirements.txt" 2>&1 | tail -5 || true
fi

# ── Phase 0c: Install cloudflared on Lium ──
if [ "$PLATFORM" = "lium" ]; then
    echo "==> Checking cloudflared (Cloudflare Quick Tunnel for Lium)..."
    if command -v cloudflared >/dev/null 2>&1; then
        echo "  ✅ cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    else
        CF_ARCH="amd64"
        [ "$(uname -m)" = "aarch64" ] && CF_ARCH="arm64"
        echo "  📥 Downloading cloudflared (linux-${CF_ARCH})..."
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
            -o /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        echo "  ✅ cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
    fi
fi

# ── AVX2-less host guard: kornia_rs SIGILLs ComfyUI at boot ──
if [ -r /proc/cpuinfo ] && ! grep -qw avx2 /proc/cpuinfo; then
    KORNIA_VER="$($COMFY_PYTHON -c 'import kornia;print(kornia.__version__)' 2>/dev/null || echo none)"
    if [ "$KORNIA_VER" = "none" ] || \
       [ "$(printf '%s\n' 0.7.1 "$KORNIA_VER" | sort -V | tail -1)" != "0.7.1" ]; then
        echo "  ⚠️  Host has no AVX2 + kornia ${KORNIA_VER} — pinning kornia 0.7.1 (kornia_rs would SIGILL)..."
        $COMFY_PIP uninstall -y kornia-rs >/dev/null 2>&1 || true
        $COMFY_PIP install -q 'kornia==0.7.1' >/tmp/kornia_pin.log 2>&1 || true
        tail -2 /tmp/kornia_pin.log 2>/dev/null || true
    fi
fi

# ── ComfyUI launch flags for H3 Image on 24GB+ ──
H3_FLAGS="--lowvram --disable-pinned-memory"
if ( cd "$COMFYUI_DIR" && "$COMFY_PYTHON" main.py --help 2>&1 ) | grep -q -- "--disable-comfy-compiler"; then
    H3_FLAGS="$H3_FLAGS --disable-comfy-compiler"
    echo "  ✅ build ships the Comfy model compiler — adding --disable-comfy-compiler"
fi

# ── Vast.ai: ComfyUI supervisord command line flag injection ──
if [ -f /opt/supervisor-scripts/comfyui.sh ]; then
    WRAP=/opt/supervisor-scripts/comfyui.sh
    MISSING=""
    for FLAG in $H3_FLAGS; do
        grep -q -- "$FLAG" "$WRAP" || MISSING="$MISSING $FLAG"
    done
    if [ -z "$MISSING" ]; then
        echo "  ✅ supervisor launch line already has:$H3_FLAGS"
    else
        echo "  📥 Adding missing flags to supervisor launch line:$MISSING"
        cp "$WRAP" "${WRAP}.bak.$(date +%Y%m%d_%H%M%S)"
        sed -i "/python main\.py/,\$ s#\${COMFYUI_ARGS}#\${COMFYUI_ARGS}${MISSING}#" "$WRAP"
        sed -n '/python main\.py/,+2p' "$WRAP" | sed 's/^/    /'
    fi
fi

# ── RunPod / Lium standalone launcher ──
LAUNCHER=/root/start_comfyui.sh
AUTH_PROXY=/opt/comfyui-auth-proxy/auth_proxy.py
START_AUTH_PROXY=0
if [ -f "$AUTH_PROXY" ]; then
    if [ "${#COMFYUI_PASSWORD}" -lt 12 ]; then
        echo "❌ This pod has RunPod's ComfyUI password proxy, but COMFYUI_PASSWORD is not set"
        echo "   or is shorter than 12 characters. Set it in the pod's environment and re-run."
        exit 1
    fi
    COMFY_BIND="--listen 127.0.0.1 --port 18188"
    COMFY_LOCAL_PORT=18188
    if ! pgrep -f "$AUTH_PROXY" >/dev/null 2>&1; then
        START_AUTH_PROXY=1
    fi
    echo "  🔒 RunPod password proxy found — ComfyUI goes on 127.0.0.1:18188 behind it"
else
    COMFY_BIND="--listen 0.0.0.0 --port 8188 --enable-cors-header"
    COMFY_LOCAL_PORT=8188
fi
if [ ! -f /opt/supervisor-scripts/comfyui.sh ]; then
    LAUNCH_PY="$(command -v "$COMFY_PYTHON" 2>/dev/null || command -v python3)"
    if grep -qsF "main.py $COMFY_BIND $H3_FLAGS" "$LAUNCHER" 2>/dev/null; then
        echo "  ✅ $LAUNCHER already carries launch flags"
    else
        echo "  📥 Writing launcher $LAUNCHER with memory flags..."
        cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/bin/bash
# Auto-generated by $(basename "$0"). Launch flags: $H3_FLAGS
cd $COMFYUI_DIR
exec $LAUNCH_PY main.py $COMFY_BIND $H3_FLAGS
LAUNCHER_EOF
        chmod +x "$LAUNCHER"
    fi
fi

# ── Create model & input directories ──
echo "==> Creating model and input directories..."
mkdir -p "$BASE_DIR"/{diffusion_models,text_encoders,vae}
mkdir -p "$IMAGES_PATH"

# ── Load shared HF download helper (with built-in fallback) ──
if [ ! -f "$BASE_DIR/_hf_download.sh" ]; then
    echo "  Fetching _hf_download.sh from GitHub..."
    curl -sSL -o "$BASE_DIR/_hf_download.sh" \
        "https://raw.githubusercontent.com/muneesraja/auto-startups-vast/main/workflows/setup/_hf_download.sh" || true
fi
if [ -s "$BASE_DIR/_hf_download.sh" ]; then
    source "$BASE_DIR/_hf_download.sh"
fi
if ! declare -f hf_download >/dev/null 2>&1; then
    echo "  ℹ️  Using built-in hf_download fallback"
    hf_download() {
        local repo="$1" file="$2" dest="$3"
        local out="$dest/$file"
        if [ -s "$out" ]; then
            echo "  ✅ already present: $out"
            return 0
        fi
        mkdir -p "$(dirname "$out")"
        if command -v hf >/dev/null 2>&1; then
            hf download "$repo" "$file" --local-dir "$dest"
        elif command -v huggingface-cli >/dev/null 2>&1; then
            huggingface-cli download "$repo" "$file" --local-dir "$dest"
        else
            local auth_hdr=()
            [ -n "${HF_TOKEN:-}" ] && auth_hdr=(-H "Authorization: Bearer $HF_TOKEN")
            curl -fL --retry 3 --continue-at - "${auth_hdr[@]}" \
                "https://huggingface.co/$repo/resolve/main/$file" -o "$out"
        fi
    }
fi

# ── Phase 1: Model Downloads (Comfy-Org/MiniMax-H3-Image) ──
echo "==> Starting model downloads from $HF_REPO..."
STEP=0
step() { STEP=$((STEP + 1)); echo "[$STEP] $*"; }

# 1. Diffusion model -> models/diffusion_models/
step "$(basename "$DIFFUSION_FILE") (Diffusion Model - $HF_REPO)..."
hf_download "$HF_REPO" "$DIFFUSION_FILE" "$BASE_DIR"
if [ ! -s "$BASE_DIR/$DIFFUSION_FILE" ]; then
    echo "  ⚠️  expected $BASE_DIR/$DIFFUSION_FILE — not on disk."
fi

# 2. Image VAE -> models/vae/
step "minimax_h3_image_vae_fp16.safetensors (Image VAE - $HF_REPO)..."
hf_download "$HF_REPO" "vae/minimax_h3_image_vae_fp16.safetensors" "$BASE_DIR"

# 3. Main Text Encoder (Qwen3-VL 32B) -> models/text_encoders/
case "$TEXT_ENC_CHOICE" in
    int8)
        step "qwen3vl_32b_minimax_h3_int8_convrot.safetensors (Text Encoder int8 - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" "$BASE_DIR"
        ;;
    nvfp4)
        step "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors (Text Encoder nvfp4 - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "$BASE_DIR"
        ;;
    both)
        step "qwen3vl_32b_minimax_h3_int8_convrot.safetensors (Text Encoder int8 - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" "$BASE_DIR"
        step "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors (Text Encoder nvfp4 - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "$BASE_DIR"
        ;;
    *)
        echo "  ⚠️  Unknown --text-encoder='$TEXT_ENC_CHOICE' — downloading int8 default"
        step "qwen3vl_32b_minimax_h3_int8_convrot.safetensors (Text Encoder int8 - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" "$BASE_DIR"
        ;;
esac

# 4. Prompt Enhancer(s) for TextGenerateV2 -> models/text_encoders/
case "$PE_CHOICE" in
    9b)
        step "qwen3.5_9b_w4a8_gptq.safetensors (Prompt Enhancer 9B - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors" "$BASE_DIR"
        ;;
    27b)
        step "qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors (Prompt Enhancer 27B - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors" "$BASE_DIR"
        ;;
    both)
        step "qwen3.5_9b_w4a8_gptq.safetensors (Prompt Enhancer 9B - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors" "$BASE_DIR"
        step "qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors (Prompt Enhancer 27B - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3.8_27b_minimax_h3_image_pe_w4a8_gptq.safetensors" "$BASE_DIR"
        ;;
    none)
        echo "  ℹ️  Skipping prompt enhancer download (--prompt-enhancer=none)"
        ;;
    *)
        echo "  ⚠️  Unknown --prompt-enhancer='$PE_CHOICE' — downloading 9b default"
        step "qwen3.5_9b_w4a8_gptq.safetensors (Prompt Enhancer 9B - $HF_REPO)..."
        hf_download "$HF_REPO" "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors" "$BASE_DIR"
        ;;
esac

# 5. Sample input image for the Image Edit workflow -> /workspace/ComfyUI/input/
if want edit; then
    SAMPLE_IMG="$IMAGES_PATH/vintage_yellow_taxi.png"
    if [ ! -s "$SAMPLE_IMG" ]; then
        step "vintage_yellow_taxi.png (sample input image for Image Edit workflow)..."
        curl -sSL -o "$SAMPLE_IMG" \
            "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/input/vintage_yellow_taxi.png" \
            || echo "  ⚠️  Failed to download sample input image (non-fatal)"
    else
        echo "  ✅ sample input already present: $SAMPLE_IMG"
    fi
fi

echo "==> All downloads completed!"

# ── Restart ComfyUI ──
echo "==> Starting / restarting ComfyUI..."
COMFY_READY=0
if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui >/dev/null 2>&1; then
    echo "  Restarting via supervisorctl..."
    supervisorctl restart comfyui || true
    COMFY_READY=1
elif [ -x "$LAUNCHER" ]; then
    echo "  No supervisor comfyui service — starting via tmux launcher $LAUNCHER"
    tmux kill-session -t comfyui 2>/dev/null || true
    sleep 2
    for pid in $(ps -eo pid,args | awk '$0 ~ /main\.py/ && $0 !~ /awk/ {print $1}'); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 2
    rm -f "$COMFYUI_DIR/user/comfyui.db.lock" 2>/dev/null || true
    if command -v tmux >/dev/null 2>&1; then
        tmux new-session -d -s comfyui "$LAUNCHER 2>&1 | tee /workspace/comfyui.log"
    else
        nohup "$LAUNCHER" >/workspace/comfyui.log 2>&1 &
    fi
    if [ "$START_AUTH_PROXY" = 1 ] && ! pgrep -f "$AUTH_PROXY" >/dev/null 2>&1; then
        echo "  🔒 Password proxy was not running — starting it on :8188 (tmux session comfyui-proxy)"
        tmux kill-session -t comfyui-proxy 2>/dev/null || true
        tmux new-session -d -s comfyui-proxy \
            "COMFYUI_PROXY_PORT=8188 COMFYUI_UPSTREAM=127.0.0.1:18188 /usr/bin/python3 -I $AUTH_PROXY 2>&1 | tee /workspace/comfyui-proxy.log"
    fi
    for i in $(seq 1 60); do
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
               "http://127.0.0.1:${COMFY_LOCAL_PORT}/system_stats" 2>/dev/null || true)
        [ -n "$CODE" ] || CODE=000
        if [ "$CODE" = "200" ]; then
            echo "  ✅ ComfyUI ready (http://127.0.0.1:${COMFY_LOCAL_PORT})"
            COMFY_READY=1
            break
        fi
        sleep 3
    done
    if [ "$COMFY_READY" != "1" ]; then
        echo "  ⚠️  ComfyUI did not answer on :${COMFY_LOCAL_PORT} — last 20 log lines:"
        tail -20 /workspace/comfyui.log 2>/dev/null || true
        echo "❌ Setup finished but ComfyUI is NOT serving on :${COMFY_LOCAL_PORT} (see log above)."
        exit 1
    fi
else
    echo "  ⚠️  No supervisor and no launcher at $LAUNCHER — start ComfyUI manually:"
    echo "      cd $COMFYUI_DIR && $COMFY_PYTHON main.py $H3_FLAGS"
fi

# ── Lium: Expose ComfyUI via Cloudflare Quick Tunnel (trycloudflare) ──
CF_URL=""
CF_URL_FILE="/workspace/comfyui_url.txt"
if [ "$PLATFORM" = "lium" ] && [ "$COMFY_READY" = "1" ]; then
    echo "==> Starting Cloudflare Quick Tunnel (trycloudflare) for http://127.0.0.1:${COMFY_LOCAL_PORT}..."
    CF_LOG="/workspace/cloudflared.log"
    tmux kill-session -t comfyui-tunnel 2>/dev/null || true
    pkill -f "cloudflared tunnel --no-autoupdate --url" 2>/dev/null || true
    sleep 1
    rm -f "$CF_LOG" "$CF_URL_FILE" /root/comfyui_url.txt 2>/dev/null || true
    if command -v tmux >/dev/null 2>&1; then
        tmux new-session -d -s comfyui-tunnel \
            "cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${COMFY_LOCAL_PORT} 2>&1 | tee $CF_LOG"
    else
        nohup cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${COMFY_LOCAL_PORT}" >"$CF_LOG" 2>&1 &
    fi
    for i in $(seq 1 30); do
        CF_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 || true)
        [ -n "$CF_URL" ] && break
        sleep 1
    done
    if [ -n "$CF_URL" ]; then
        printf '%s\n' "$CF_URL" > "$CF_URL_FILE"
        [ -d /root ] && cp "$CF_URL_FILE" /root/comfyui_url.txt 2>/dev/null || true
        echo "  ✅ ComfyUI tunnel live: $CF_URL"
        echo "  📄 URL saved to: $CF_URL_FILE (and /root/comfyui_url.txt)"
    else
        echo "  ⚠️  Could not capture trycloudflare URL within 30s — check $CF_LOG:"
        tail -15 "$CF_LOG" 2>/dev/null || true
    fi
fi

echo "✅ Setup complete!"
for _wf in $SELECTED_WORKFLOWS; do
    case "$_wf" in
        t2i)  echo "👉 Workflow: workflows/image-workflows/image_minimax_h3_image_t2i.json" ;;
        edit) echo "👉 Workflow: workflows/image-workflows/image_minimax_h3_image_edit.json" ;;
    esac
done
echo "👉 Diffusion model on disk: $BASE_DIR/$DIFFUSION_FILE"
echo "👉 Input images directory:  $IMAGES_PATH"
if [ -n "$CF_URL" ]; then
    echo "👉 ComfyUI public URL:      $CF_URL (saved in $CF_URL_FILE)"
fi
