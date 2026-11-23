#!/bin/bash
# ---
# name: MiniMax H3 — Story Studio render workflows
# workflow: BUNNY_SelfLift_12GB_LORA, MinimaxH3_2Stage_Pika_Regen2K_Final, video_pika_h3_flex_ref2va, minimax-h3.ui_v2_1_stage
# aliases: [minimax-h3, story-studio-h3, minimax-h3-2stage-nvidia-upscale, h3-nvidia-upscale, MinimaxH3_2Stage-NVIDIA_UPSCALE]
# description: Provisions ONLY what the Render page's workflows need (web/src/server/render/workflows.ts). Pick the workflows you will run and the script installs just their custom-node packs and workflow-specific weights; every LoRA the app can load (turbo slot + fight LoRAs) is always downloaded. On Lium: installs ComfyUI if missing, installs cloudflared, and exposes ComfyUI via a trycloudflare tunnel saved to /workspace/comfyui_url.txt.
# size: ~75GB with all four workflows and the official base; the Regen 2K weights (~13GB LoRAs) and the Fast VAE are skipped unless that workflow is picked
# min_vram: 24GB
# nodes: [comfyui-minimax-h3-audio-T8, selflift-Avatar, ComfyUI-YCNodes-MiniMax-H3, ComfyUI-KJNodes, ComfyUI-VideoHelperSuite, ComfyUI-Easy-Use, Comfyui-MMH3-UltimateUpscale, ComfyUI-Open-H3-Regenerate, ComfyUI-RMBG]
# usage: ./video_script.sh [--interactive] [--platform=lium|vast|runpod] [--workflows=bunny,regen2k,flex,standard|all]
#   --interactive  Prompt for HF_TOKEN (hidden), platform, the workflows and the diffusion
#                  model. Needs a TTY (tmux pane or foreground shell).
#   --platform=    Force platform: lium, vast, or runpod (auto-detected by default).
#                  On Lium: installs ComfyUI if missing, installs cloudflared, and publishes a trycloudflare URL to /workspace/comfyui_url.txt (and /root/comfyui_url.txt).
#   --workflows=   Which render workflows to provision (or env WORKFLOWS=...).
#                  Non-interactive default: all.
#     bunny     BUNNY SelfLift          (BUNNY_SelfLift_12GB_LORA.json)
#                 nodes: comfyui-minimax-h3-audio-T8 (incl. SolAttnMiniMax),
#                        selflift-Avatar, ComfyUI-YCNodes-MiniMax-H3
#                 weights: V2 latent upscaler
#     regen2k   Pika Regen 2K           (MinimaxH3_2Stage_Pika_Regen2K_Final.json)
#                 nodes: comfyui-minimax-h3-audio-T8, ComfyUI-KJNodes, ComfyUI-Easy-Use,
#                        Comfyui-MMH3-UltimateUpscale, ComfyUI-Open-H3-Regenerate, ComfyUI-RMBG
#                 weights: latent upscaler, Fast VAE, Open-H3 Regenerate 2K + Sharp curve LoRAs, LMS LoRA, RMBG-2.0
#     flex      Pika H3 Flex            (video_pika_h3_flex_ref2va.json)  core nodes only
#     standard  MiniMax H3 1-stage      (minimax-h3.ui_v2_1_stage.json)   core nodes only
#   Always installed: ComfyUI-VideoHelperSuite (VHS_LoadVideo loads reference videos in every
#   ref2va graph the app builds), the shared VAEs/text encoder and ALL LoRAs.
#   Diffusion model: ONE checkpoint is downloaded (they are ~20-32GiB each);
#   non-interactive runs ALWAYS take the official one:
#     [default]   minimax_h3_ref2va_pruned_int8_convrot.safetensors
#                 (Comfy-Org/MiniMax-H3, inside its diffusion_models/ subdir)
#                 Pika Flex's base; Pika Regen 2K needs it too (its 1025x8 adaln_t_table).
#     [choice 2]  minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors
#                 (smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models): MiniMax H3 1-stage, i2v, long takes
#     [choice 3]  Minimax-h3_Singularity_ref2va_v2_int8.safetensors
#                 (WarmBloodAban/Minimax-h3_Singularity): BUNNY SelfLift default
#     [choice 4]  fasth3_omniref_8step_pruned_int8_convrot.safetensors
#                 (FastVideo/FastH3-Omni-Comfy, inside its diffusion_models/ subdir)
#   All four are DIFFERENT weight files (hybrid ~19.5GiB, Singularity V2
#   ~31.7GiB unpruned, FastH3 Omni ~20.7GiB), NOT aliases. The app sets the
#   UNETLoader from the Render page checkpoint, so it must name the one you
#   downloaded.
# ---

set -e

# ── Workflow selection helpers ──
# SELECTED_WORKFLOWS is a space-separated list; everything below is gated on want <name>.
ALL_WORKFLOWS="bunny regen2k flex standard"
WORKFLOWS_ARG="${WORKFLOWS:-}"
PLATFORM_ARG="${PLATFORM:-}"
want() { case " $SELECTED_WORKFLOWS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
normalize_workflows() {
    local out="" tok
    for tok in $(echo "$1" | tr ',;' '  ' | tr 'A-Z' 'a-z'); do
        case "$tok" in
            all) out="$ALL_WORKFLOWS" ;;
            bunny|selflift|bunny_selflift) out="$out bunny" ;;
            regen2k|regen|pika_regen2k) out="$out regen2k" ;;
            flex|pika|pika_flex) out="$out flex" ;;
            standard|h3|h3_standard|1stage) out="$out standard" ;;
            *) echo "  ⚠️  Unknown workflow '$tok' — ignored (use: bunny regen2k flex standard all)" >&2 ;;
        esac
    done
    for tok in $ALL_WORKFLOWS; do
        case " $out " in *" $tok "*) printf '%s ' "$tok" ;; esac
    done
}

# ── CLI args ──
# --interactive prompts for HF_TOKEN before any long work. Manual/foreground runs
# usually have no token in the env and no /root/config/token.json, so the helper
# would abort mid-Phase-2 after the custom nodes were already installed.
INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE=1 ;;
        --platform=*) PLATFORM_ARG="$(echo "${arg#--platform=}" | tr 'A-Z' 'a-z')" ;;
        --workflows=*) WORKFLOWS_ARG="${arg#--workflows=}" ;;
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

# ── Interactive HF_TOKEN & platform prompt (--interactive) ──
if [ "$INTERACTIVE" = "1" ]; then
    echo "==> Interactive mode — collecting HF_TOKEN"
    if [ ! -t 0 ]; then
        echo "  ⚠️  stdin is not a TTY — nothing to read."
        echo "      Run in a tmux pane or a foreground shell (no stdin pipe), then re-run."
    else
        if [ -n "${HF_TOKEN:-}" ]; then
            echo "  ℹ️  HF_TOKEN already in env (${#HF_TOKEN} chars) — press Enter to keep it."
        fi
        # -s hides the token from the terminal; `|| true` keeps `set -e` from
        # aborting the whole script on EOF (e.g. someone pipes stdin in anyway).
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
fi

# ── Workflow selection ──
# Only the picked workflows get their custom nodes and workflow-specific weights.
if [ "$INTERACTIVE" = "1" ]; then
    echo "==> Interactive mode — choose the render workflows to provision"
    echo "    bunny     BUNNY SelfLift     (default in the app)  nodes: T8 audio, selflift-Avatar, YCNodes"
    echo "    regen2k   Pika Regen 2K      nodes: T8 audio, KJNodes, Easy-Use, MMH3-UltimateUpscale, Open-H3-Regenerate, RMBG; +13GB LoRAs"
    echo "    flex      Pika H3 Flex       core nodes only"
    echo "    standard  MiniMax H3 1-stage core nodes only"
    if [ ! -t 0 ]; then
        echo "  ⚠️  stdin is not a TTY — keeping: ${WORKFLOWS_ARG:-all}"
    else
        read -rp "  🧩 Workflows (comma-separated, or 'all') [${WORKFLOWS_ARG:-all}]: " _WF_INPUT || true
        [ -n "${_WF_INPUT:-}" ] && WORKFLOWS_ARG="$_WF_INPUT"
        unset _WF_INPUT
    fi
fi
SELECTED_WORKFLOWS="$(normalize_workflows "${WORKFLOWS_ARG:-all}")"
if [ -z "${SELECTED_WORKFLOWS// /}" ]; then
    echo "  ⚠️  No valid workflow in '${WORKFLOWS_ARG}' — provisioning all."
    SELECTED_WORKFLOWS="$ALL_WORKFLOWS"
fi
echo "  ✅ Platform:  $PLATFORM"
echo "  ✅ Workflows: $SELECTED_WORKFLOWS"

# ── Diffusion-model selection ──
# Four different weights, NOT aliases, so the download is a straight choice. Only
# the chosen one is downloaded — a second ~20-32GiB checkpoint fills the disk.
# Non-interactive runs always take the official Comfy-Org ref2va UNET. It (and
# FastH3) ships inside the repo's diffusion_models/ subdir, so step [5] points the
# helper at $BASE_DIR instead of $BASE_DIR/diffusion_models.
OFFICIAL_REPO="Comfy-Org/MiniMax-H3"
OFFICIAL_FILE="diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"
HYBRID_REPO="smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models"
HYBRID_FILE="minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors"
SINGULARITY_REPO="WarmBloodAban/Minimax-h3_Singularity"
SINGULARITY_FILE="Minimax-h3_Singularity_ref2va_v2_int8.safetensors"
# FastH3 Omni's card pins its own vae/ and text_encoders/ copies, so the VAE and
# text-encoder steps source them from this repo when choice 4 is picked
# (byte-identical to Comfy-Org's, same LFS sha256 + size, verified 2026-10).
FASTH3_REPO="FastVideo/FastH3-Omni-Comfy"
FASTH3_FILE="diffusion_models/fasth3_omniref_8step_pruned_int8_convrot.safetensors"
DIFFUSION_REPO="$OFFICIAL_REPO"
DIFFUSION_FILE="$OFFICIAL_FILE"

if [ "$INTERACTIVE" = "1" ]; then
    echo "==> Interactive mode — choose the diffusion model"
    echo "    1) $(basename "$OFFICIAL_FILE")"
    echo "         official Comfy-Org ref2va pruned int8: Pika Flex / Pika Regen 2K base  [default]"
    echo "    2) $HYBRID_FILE"
    echo "         hybrid fl2va+ref2va int8, ~19.5GiB: MiniMax H3 1-stage, i2v, long takes"
    echo "    3) $SINGULARITY_FILE"
    echo "         Singularity ref2va V2 int8 (unpruned), ~31.7GiB: BUNNY SelfLift default"
    echo "    4) $(basename "$FASTH3_FILE")"
    echo "         FastH3 Omni ref2v 8-step pruned int8, ~20.7GiB (no turbo LoRA needed)"
    if [ ! -t 0 ]; then
        echo "  ⚠️  stdin is not a TTY — keeping the default (1): $(basename "$DIFFUSION_FILE")"
    else
        read -rp "  🎬 Which diffusion model? [1]: " _MDL_INPUT || true
        case "${_MDL_INPUT:-1}" in
            2|hybrid|Hybrid)
                DIFFUSION_REPO="$HYBRID_REPO"
                DIFFUSION_FILE="$HYBRID_FILE"
                ;;
            3|singularity|Singularity)
                DIFFUSION_REPO="$SINGULARITY_REPO"
                DIFFUSION_FILE="$SINGULARITY_FILE"
                ;;
            4|fasth3|FastH3|omni|Omni)
                DIFFUSION_REPO="$FASTH3_REPO"
                DIFFUSION_FILE="$FASTH3_FILE"
                ;;
            1|official|Official|"") ;;
            *) echo "  ⚠️  Unrecognised choice '$_MDL_INPUT' — using the default (1)." ;;
        esac
        unset _MDL_INPUT
    fi
    echo "  ✅ Diffusion model: $(basename "$DIFFUSION_FILE")"
    echo "     from: $DIFFUSION_REPO"
    if [ "$DIFFUSION_REPO" = "$FASTH3_REPO" ]; then
        echo "     VAEs + text encoder: pulled from $FASTH3_REPO (its card's copies)"
    fi
else
    echo "==> Non-interactive: diffusion model = $(basename "$DIFFUSION_FILE") (official Comfy-Org ref2va pruned int8)"
fi
if want regen2k && [ "$DIFFUSION_FILE" != "$OFFICIAL_FILE" ]; then
    echo "  ⚠️  Pika Regen 2K's OpenH3RegenLora needs the official ref2va base — pick it on the Render page"
    echo "      only if you also download it (this run fetches just $(basename "$DIFFUSION_FILE"))."
fi

BASE_DIR="$COMFYUI_DIR/models"
IMAGES_PATH="$COMFYUI_DIR/input"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"

# ── Phase 0: Install ComfyUI if missing, and check core meets H3 prerequisites (>= 0.42.0) ──
echo "==> Phase 0: Checking ComfyUI installation and version..."
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

MIN_CORE="0.42.0"
NEED_UPGRADE=0
if [[ "$CURRENT_VERSION" == "unknown" ]] || \
   [[ "$(printf '%s\n' "$MIN_CORE" "$CURRENT_VERSION" | sort -V | head -n1)" != "$MIN_CORE" ]]; then
    NEED_UPGRADE=1
fi
grep -q "AttentionTensorContainer" "$COMFYUI_DIR/comfy/ldm/modules/attention.py" 2>/dev/null || NEED_UPGRADE=1
grep -rq "class ModelAttentionBackend" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null || NEED_UPGRADE=1
grep -rq "class SaveVideo" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null || NEED_UPGRADE=1
grep -rq "class MathExpressionNode" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null || NEED_UPGRADE=1
[ -f "$COMFYUI_DIR/comfy_api/latest/__init__.py" ] || NEED_UPGRADE=1
grep -q "pdd_steps" "$COMFYUI_DIR/comfy/model_detection.py" 2>/dev/null || NEED_UPGRADE=1

if [ "$NEED_UPGRADE" = "1" ]; then
    echo "  ⚠️  core $CURRENT_VERSION lacks the H3 prerequisites (need >= $MIN_CORE) — upgrading..."
    ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
    git -C "$COMFYUI_DIR" stash --quiet 2>/dev/null || true
    git -C "$COMFYUI_DIR" fetch origin --tags --quiet 2>/dev/null || \
        git -C "$COMFYUI_DIR" fetch origin master --depth=1 --quiet 2>/dev/null || true
    TARGET_TAG=$(git -C "$COMFYUI_DIR" tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]' | head -1 || true)
    if [ -n "$TARGET_TAG" ] && ver_ge "$TARGET_TAG" "v$MIN_CORE"; then
        echo "  Checking out $TARGET_TAG"
        git -C "$COMFYUI_DIR" checkout "$TARGET_TAG" --quiet 2>/dev/null || true
    else
        echo "  No tag >= v$MIN_CORE found — falling back to origin/master"
        git -C "$COMFYUI_DIR" checkout origin/master -- . 2>/dev/null || \
            git -C "$COMFYUI_DIR" checkout origin/main -- . 2>/dev/null || true
    fi
    UPGRADED=1
    V2=$(git -C "$COMFYUI_DIR" describe --tags 2>/dev/null | sed 's/^v//')
    if grep -q "AttentionTensorContainer" "$COMFYUI_DIR/comfy/ldm/modules/attention.py" 2>/dev/null && \
       grep -rq "class ModelAttentionBackend" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null && \
       grep -rq "class SaveVideo" "$COMFYUI_DIR/comfy_extras/" 2>/dev/null && \
       [ -f "$COMFYUI_DIR/comfy_api/latest/__init__.py" ] && \
       grep -q "pdd_steps" "$COMFYUI_DIR/comfy/model_detection.py" 2>/dev/null; then
        echo "  ✅ ComfyUI upgraded to $V2 — H3 prerequisites present"
    else
        echo "  ❌ Upgrade incomplete: H3 prerequisites STILL missing after checkout ($V2)."
        exit 1
    fi
else
    echo "  ✅ ComfyUI $CURRENT_VERSION >= $MIN_CORE with H3 prerequisites — no upgrade needed"
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

# ── Phase 0a: torchaudio must match the existing torch (T8 audio pack imports it) ──
# Preinstalled system torch (e.g. Lium 2.12.0+cu130) can ship without torchaudio, and a
# same-version torchaudio wheel may not exist yet. Install the closest build <= torch with
# --no-deps so torch itself is never replaced (T8 only uses torchaudio.functional).
if ! $COMFY_PYTHON -c "import torchaudio" >/dev/null 2>&1; then
    echo "==> torchaudio missing — installing a build that matches the existing torch..."
    read -r _TV _CU <<<"$($COMFY_PYTHON -c 'import torch; v=torch.__version__.split("+"); print(v[0], (v[1] if len(v)>1 else "cpu"))')"
    _MAJ=${_TV%%.*}; _REST=${_TV#*.}; _MIN=${_REST%%.*}
    _TA_OK=0
    for _m in $(seq "$_MIN" -1 $((_MIN > 3 ? _MIN - 3 : 0))); do
        if $COMFY_PIP install -q --no-deps "torchaudio==${_MAJ}.${_m}.*" --index-url "https://download.pytorch.org/whl/${_CU}" >/dev/null 2>&1 \
           && $COMFY_PYTHON -c "import torch, torchaudio; torchaudio.functional.resample(torch.zeros(1,480), 48000, 16000)" >/dev/null 2>&1; then
            _TA_OK=1; break
        fi
    done
    if [ "$_TA_OK" = 1 ]; then
        echo "  ✅ torchaudio $($COMFY_PYTHON -c 'import torchaudio; print(torchaudio.__version__)') installed (torch $_TV kept)"
    else
        echo "  ❌ Could not install a torchaudio compatible with torch $_TV ($_CU) — the T8 audio nodes will fail to import."
        exit 1
    fi
fi

# ── Phase 0b: refresh ComfyUI python deps after install or core upgrade ──
if [ "${UPGRADED:-0}" = "1" ] && [ -f "$COMFYUI_DIR/requirements.txt" ]; then
    echo "==> Phase 0b: Installing ComfyUI requirements..."
    $COMFY_PIP install -q -r "$COMFYUI_DIR/requirements.txt" 2>&1 | tail -3 || true
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

# ── Phase 1: Install only the custom node packs the selected workflows use ──
echo "==> Phase 1: Installing custom node packs for: $SELECTED_WORKFLOWS"
mkdir -p "$CUSTOM_NODES_DIR"

# install_node <repo-url> [dir-name]  — comfy-cli when present, else a shallow clone.
INSTALLED_NODE_DIRS=""
install_node() {
    local url="$1" name="${2:-$(basename "$1")}"
    if [ -d "$CUSTOM_NODES_DIR/$name" ]; then
        echo "  ✅ $name already installed"
    elif command -v comfy >/dev/null 2>&1; then
        echo "  📥 comfy node install $name"
        ( cd "$COMFYUI_DIR" && comfy node install "$url" 2>/dev/null ) || true
    fi
    if [ ! -d "$CUSTOM_NODES_DIR/$name" ]; then
        echo "  📥 git clone $name"
        ( cd "$CUSTOM_NODES_DIR" && git clone --depth=1 "$url" "$name" ) \
            || echo "  ⚠️  $name clone failed (non-fatal)"
    fi
    INSTALLED_NODE_DIRS="$INSTALLED_NODE_DIRS $name"
}

# T8 audio pack: MiniMaxH3AVDecodeT8 / AudioConditioningT8 / AVLatentSeparateT8 and SolAttnMiniMax.
if want bunny || want regen2k; then
    install_node https://github.com/T8mars/comfyui-minimax-h3-audio-T8
fi
# BUNNY SelfLift
if want bunny; then
    install_node https://github.com/slmonker/selflift-Avatar
    install_node https://github.com/yichengup/ComfyUI-YCNodes-MiniMax-H3
    install_node https://github.com/Fannovel16/ComfyUI-Frame-Interpolation
fi
# Pika Regen 2K: Get/SetNode + chunk-FFN (KJNodes), Easy-Use cleanup nodes, tiled upscale, Open-H3 LoRA/VAE
if want regen2k; then
    install_node https://github.com/kijai/ComfyUI-KJNodes
    install_node https://github.com/yolain/ComfyUI-Easy-Use
    install_node https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale
    install_node https://github.com/rdh9616/ComfyUI-Open-H3-Regenerate
    # optional "cut out character/prop references" setting (RMBG-2.0)
    install_node https://github.com/1038lab/ComfyUI-RMBG
fi
# VHS_LoadVideo: every ref2va graph the app builds loads reference videos through it (VHS_VideoCombine in the Regen 2K JSON)
install_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite

# ── Install node dependencies ──
echo "==> Installing node dependencies..."
for repo in $INSTALLED_NODE_DIRS; do
    REQ="$CUSTOM_NODES_DIR/$repo/requirements.txt"
    [ -f "$REQ" ] || REQ="$CUSTOM_NODES_DIR/$repo/requirements-no-cupy.txt"
    if [ -f "$REQ" ]; then
        echo "  Installing $repo deps..."
        $COMFY_PIP install -q -r "$REQ" 2>&1 | tail -5 || true
    fi
done

# ── Verify the nodes that matter ──
if want bunny; then
    grep -q "SelfLiftAvatarH3Sampler" "$CUSTOM_NODES_DIR/selflift-Avatar/nodes.py" 2>/dev/null \
        && echo "  ✅ selflift-Avatar has SelfLiftAvatarH3Sampler" \
        || echo "  ⚠️  selflift-Avatar missing SelfLiftAvatarH3Sampler"
    grep -q "H3SigmaRefiner" "$CUSTOM_NODES_DIR/ComfyUI-YCNodes-MiniMax-H3/py/h3_sigma_refiner.py" 2>/dev/null \
        && echo "  ✅ H3SigmaRefiner present" \
        || echo "  ⚠️  ComfyUI-YCNodes-MiniMax-H3 missing H3SigmaRefiner"
    [ -d "$CUSTOM_NODES_DIR/ComfyUI-Frame-Interpolation" ] \
        && echo "  ✅ ComfyUI-Frame-Interpolation installed (RIFE VFI)" \
        || echo "  ⚠️  ComfyUI-Frame-Interpolation missing"
fi
if want regen2k; then
    [ -d "$CUSTOM_NODES_DIR/Comfyui-MMH3-UltimateUpscale" ] \
        && echo "  ✅ Comfyui-MMH3-UltimateUpscale installed" \
        || echo "  ⚠️  Comfyui-MMH3-UltimateUpscale missing"
    [ -d "$CUSTOM_NODES_DIR/ComfyUI-Open-H3-Regenerate" ] \
        && echo "  ✅ ComfyUI-Open-H3-Regenerate installed" \
        || echo "  ⚠️  ComfyUI-Open-H3-Regenerate missing"
fi

# ── SageAttention v2 (fixes MiniMaxH3MemoryEfficientSageAttentionPatch) ──
if $COMFY_PYTHON -c "from sageattention.core import get_cuda_arch_versions" >/dev/null 2>&1; then
    echo "  ✅ sageattention v2 API (get_cuda_arch_versions) present"
else
    echo "  ⚠️  sageattention missing or stale v1 (lacks get_cuda_arch_versions) — installing v2.2.0..."
    CUDA_MAJOR="$($COMFY_PYTHON -c 'import torch;print((torch.version.cuda or "12.0").split(".")[0])' 2>/dev/null || echo 12)"
    PY_TAG="$($COMFY_PYTHON -c 'import sys;print("cp%d%d" % sys.version_info[:2])' 2>/dev/null || echo cp312)"
    WHEEL_URL="https://github.com/snw35/sageattention-wheel/releases/download/cu12-2.2.0-cu13-2.2.0/sageattention-2.2.0%2Bcu${CUDA_MAJOR}-${PY_TAG}-${PY_TAG}-linux_x86_64.whl"
    echo "  torch is CUDA ${CUDA_MAJOR} → $(basename "$WHEEL_URL")"
    WHEEL_OK=1
    $COMFY_PIP install --no-cache-dir "$WHEEL_URL" > /tmp/sage_wheel.log 2>&1 || WHEEL_OK=0
    tail -3 /tmp/sage_wheel.log 2>/dev/null || true
    if [ "$WHEEL_OK" = "1" ] && \
       $COMFY_PYTHON -c "from sageattention.core import get_cuda_arch_versions" >/dev/null 2>&1; then
        echo "  ✅ SageAttention v2 installed (prebuilt wheel)"
    else
        echo "  ⚠️  Prebuilt wheel unusable for this torch build — compiling v2.0.1 from source..."
        ARCHS="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' .' | sed 's/^/sm/')"
        [ -n "$ARCHS" ] && export TORCH_CUDA_ARCH_LIST="$ARCHS"
        $COMFY_PIP install --no-cache-dir --no-build-isolation \
            'git+https://github.com/thu-ml/SageAttention.git@v2.0.1' > /tmp/sage_src.log 2>&1 || true
        tail -5 /tmp/sage_src.log 2>/dev/null || true
        $COMFY_PYTHON -c "from sageattention.core import get_cuda_arch_versions" >/dev/null 2>&1 \
            && echo "  ✅ SageAttention v2 installed (source build)" \
            || echo "  ⚠️  SageAttention unavailable — not fatal: ModelAttentionBackend fallback is active."
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
        KV="$($COMFY_PYTHON -c 'import kornia;print(kornia.__version__)' 2>/dev/null || echo FAILED)"
        if [ "$KV" = "FAILED" ]; then
            echo "  ❌ kornia still unimportable — ComfyUI will NOT boot on this host."
        else
            echo "  ✅ kornia $KV pinned — ComfyUI can boot on this AVX-less host"
        fi
    else
        echo "  ✅ no AVX2 host, but kornia 0.7.1 is already pinned"
    fi
fi

# ── ComfyUI launch flags for H3 on 24GB ──
H3_FLAGS="--lowvram --disable-pinned-memory"
if ( cd "$COMFYUI_DIR" && "$COMFY_PYTHON" main.py --help 2>&1 ) | grep -q -- "--disable-comfy-compiler"; then
    H3_FLAGS="$H3_FLAGS --disable-comfy-compiler"
    echo "  ✅ build ships the Comfy model compiler — adding --disable-comfy-compiler"
else
    echo "  ℹ️  build has no --disable-comfy-compiler — omitting it"
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
        echo "  📥 Adding missing H3 flags to the supervisor launch line:$MISSING"
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
        echo "   or is shorter than 12 characters. Set it in the pod's environment"
        echo "   (Edit Pod → Environment Variables), restart the pod and run this script again."
        exit 1
    fi
    COMFY_BIND="--listen 127.0.0.1 --port 18188"
    COMFY_LOCAL_PORT=18188
    if ! pgrep -f "$AUTH_PROXY" >/dev/null 2>&1; then
        START_AUTH_PROXY=1
    fi
    echo "  🔒 RunPod password proxy found — ComfyUI goes on 127.0.0.1:18188 behind it (sign in with COMFYUI_PASSWORD)"
else
    COMFY_BIND="--listen 0.0.0.0 --port 8188 --enable-cors-header"
    COMFY_LOCAL_PORT=8188
fi
if [ ! -f /opt/supervisor-scripts/comfyui.sh ]; then
    LAUNCH_PY="$(command -v "$COMFY_PYTHON" 2>/dev/null || command -v python3)"
    if grep -qsF "main.py $COMFY_BIND $H3_FLAGS" "$LAUNCHER" 2>/dev/null; then
        echo "  ✅ $LAUNCHER already carries the H3 flags"
    else
        echo "  📥 Writing launcher $LAUNCHER with H3 memory flags..."
        cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/bin/bash
# Auto-generated by $(basename "$0"). Launch flags: $H3_FLAGS
cd $COMFYUI_DIR
exec $LAUNCH_PY main.py $COMFY_BIND $H3_FLAGS
LAUNCHER_EOF
        chmod +x "$LAUNCHER"
    fi
fi

# ── Sol-Attn (SolAttnMiniMax): BUNNY SelfLift only ──
if want bunny; then
# ── Phase 1f: Sol-Attn provider check (SolAttnMiniMax) ──
echo "==> Verifying the Sol-Attn provider (SolAttnMiniMax)..."
SOLATTN_SRC="$CUSTOM_NODES_DIR/comfyui-minimax-h3-audio-T8/sol_attn_minimax_v2.py"
if grep -q "class SolAttnMiniMax" "$SOLATTN_SRC" 2>/dev/null; then
    echo "  ✅ SolAttnMiniMax provided by comfyui-minimax-h3-audio-T8"
else
    echo "  ⚠️  comfyui-minimax-h3-audio-T8 no longer vendors SolAttnMiniMax — falling back to standalone BSAI pack"
    BSAI_REPO="https://github.com/xm6018924/BSAI-ComfyUI-Sol-H3"
    BSAI_DIR="$CUSTOM_NODES_DIR/BSAI-ComfyUI-Sol-H3"
    if command -v comfy >/dev/null 2>&1; then
        comfy node install "$BSAI_REPO" 2>/dev/null || true
    fi
    [ -f "$BSAI_DIR/sol_attn_minimax_v2.py" ] || \
        ( cd "$CUSTOM_NODES_DIR" && git clone --depth=1 "$BSAI_REPO" BSAI-ComfyUI-Sol-H3 ) \
            || echo "  ⚠️  BSAI fallback clone failed (non-fatal)"
fi

# ── Sol-Attn runtime prerequisites: comfy_kitchen kernels + triton ──
COMFY_KITCHEN_STATE="$("$COMFY_PYTHON" - <<'PYEOF' 2>/dev/null || echo "absent (probe failed)"
try:
    import inspect
    import comfy_kitchen as ck
    from comfy_kitchen.backends import cuda as c
    sig = inspect.signature(c.sol_attn).parameters
    print("%s sink_blocks=%s tail=%s" % (getattr(ck, "__version__", "?"),
                                         "sink_blocks" in sig, "tail" in sig))
except Exception as exc:
    print("absent (%s)" % type(exc).__name__)
PYEOF
)"
COMFY_KITCHEN_STATE=$(printf '%s' "$COMFY_KITCHEN_STATE" | tr -d '\r')
echo "  comfy_kitchen: $COMFY_KITCHEN_STATE"
case "$COMFY_KITCHEN_STATE" in
    *sink_blocks=True*tail=True*) ;;
    *)
        echo "  ⚠️  comfy_kitchen lacks the Sol-Attn sink_blocks/tail kernels — upgrading..."
        $COMFY_PIP install -q -U comfy-kitchen >/tmp/comfy_kitchen_up.log 2>&1 || true
        tail -2 /tmp/comfy_kitchen_up.log 2>/dev/null || true
        ;;
esac
if $COMFY_PYTHON -c "import triton" >/dev/null 2>&1; then
    echo "  ✅ triton present"
else
    echo "  ⚠️  triton NOT importable"
fi

fi

# ── Create model & input directories ──
echo "==> Creating model directories..."
mkdir -p "$BASE_DIR"/{vae,vae_approx,text_encoders,diffusion_models,loras}
mkdir -p "$IMAGES_PATH"
if want bunny || want regen2k; then mkdir -p "$BASE_DIR/latent_upscale_models"; fi

# ── Load shared HF download helper (with built-in fallback) ──
if [ ! -f "$BASE_DIR/_hf_download.sh" ]; then
    echo "  Fetching _hf_download.sh from GitHub..."
    curl -sSL -o "$BASE_DIR/_hf_download.sh" \
        "https://raw.githubusercontent.com/pirenders/auto-startups-vast/main/workflows/setup/_hf_download.sh" || true
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

# link_alias <existing> <alias>  — hardlink (no extra disk), falling back to symlink/copy
link_alias() {
    [ -s "$1" ] && [ ! -e "$2" ] || return 0
    mkdir -p "$(dirname "$2")"
    ln "$1" "$2" 2>/dev/null || ln -s "$1" "$2" 2>/dev/null || cp "$1" "$2"
}

# ── Downloads ──
echo "==> Starting model downloads..."

if [ "$DIFFUSION_REPO" = "$FASTH3_REPO" ]; then
    VAE_REPO="$FASTH3_REPO"
    TEXT_ENC_REPO="$FASTH3_REPO"
else
    VAE_REPO="Comfy-Org/MiniMax-H3"
    TEXT_ENC_REPO="Comfy-Org/MiniMax-H3"
fi

STEP=0
step() { STEP=$((STEP + 1)); echo "[$STEP] $*"; }

# ── Shared by every workflow ──
step "minimax_h3_video_vae_fp16.safetensors (VAE - video, $VAE_REPO)..."
hf_download "$VAE_REPO" "vae/minimax_h3_video_vae_fp16.safetensors" "$BASE_DIR"

step "minimax_h3_audio_vae_fp32.safetensors (VAE - audio, $VAE_REPO)..."
hf_download "$VAE_REPO" "vae/minimax_h3_audio_vae_fp32.safetensors" "$BASE_DIR"

step "qwen3vl_32b_minimax_h3_int8_convrot.safetensors (Text Encoder, $TEXT_ENC_REPO)..."
hf_download "$TEXT_ENC_REPO" "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" "$BASE_DIR"

step "$(basename "$DIFFUSION_FILE") (Diffusion Model)..."
if [ "$DIFFUSION_REPO" = "$FASTH3_REPO" ] || [ "$DIFFUSION_REPO" = "$OFFICIAL_REPO" ]; then
    DIFFUSION_DEST="$BASE_DIR"
else
    DIFFUSION_DEST="$BASE_DIR/diffusion_models"
fi
hf_download "$DIFFUSION_REPO" "$DIFFUSION_FILE" "$DIFFUSION_DEST"
if [ ! -s "$BASE_DIR/diffusion_models/$(basename "$DIFFUSION_FILE")" ]; then
    echo "  ⚠️  expected models/diffusion_models/$(basename "$DIFFUSION_FILE") — not on disk."
fi

step "taeh3.safetensors (Tiny VAE - live preview)..."
hf_download "Kijai/MiniMax-H3-TAE" "vae_approx/taeh3.safetensors" "$BASE_DIR"

# ── LoRAs: all of them, whichever workflows were picked ──
# Turbo (acceleration) slot — web/src/server/render/workflows.ts TURBO_LORAS
step "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors (LoRA - ref2v turbo 4-step v0.1)..."
hf_download "lightx2v/Minimax-h3-Turbo" "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" "$BASE_DIR/loras"

step "pika_h3_flex_ref2va_v1_bf16.safetensors (LoRA - Pika H3 Flex Ref2va V1)..."
hf_download "Comfy-Org/MiniMax-H3" "loras/pika_h3_flex_ref2va_v1_bf16.safetensors" "$BASE_DIR"

step "minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors (LoRA - Turbo v4 step600 EMA pruned)..."
hf_download "Momoking/MiniMax-H3-Turbo-Lora-ComfyUI" "minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors" "$BASE_DIR/loras"

step "minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors (LoRA - DMAD 4-step full)..."
hf_download "Kijai/MiniMax-H3-experimental" "loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors" "$BASE_DIR"

step "minimax_h3_DMAD_8step_full_lora_avg_rank_58_bf16.safetensors (LoRA - DMAD 8-step full)..."
hf_download "Kijai/MiniMax-H3-experimental" "loras/minimax_h3_DMAD_8step_full_lora_avg_rank_58_bf16.safetensors" "$BASE_DIR"

step "minimax_h3_open_regenerate_2k_ic_lora_avg_rank_21_bf16.safetensors (LoRA - Open Regenerate 2K IC upscaler)..."
hf_download "Kijai/MiniMax-H3-experimental" "loras/minimax_h3_open_regenerate_2k_ic_lora_avg_rank_21_bf16.safetensors" "$BASE_DIR"

step "minimax_h3_singularity_v2_lora_avg_rank_351_bf16.safetensors (LoRA - Singularity v2)..."
hf_download "Kijai/MiniMax-H3-experimental" "loras/minimax_h3_singularity_v2_lora_avg_rank_351_bf16.safetensors" "$BASE_DIR"

step "minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors (LoRA - fl2v turbo 4-step v0.1)..."
hf_download "Kijai/MiniMax-H3_comfy" "loras/minimax_h3_fl2v_lightx2v_turbo_4step_v0.1_comfy.safetensors" "$BASE_DIR"

# Fight / motion LoRAs — web/src/server/h3/lora-presets.ts
step "Motion_Repair_V2.safetensors (LoRA - General Motion Continuity Repair V2)..."
hf_download "JOKER141/MiniMax-H3-General-Motion-Continuity-Repair" "Motion_Repair_V2.safetensors" "$BASE_DIR/loras"

step "H3_Combat_V2.safetensors (LoRA - Combat Base V2)..."
hf_download "JOKER141/MiniMax-H3-Combat-Base-V2" "H3_Combat_V2.safetensors" "$BASE_DIR/loras"

step "H3_Fight_Flow_V1.safetensors (LoRA - Fight Flow fight-interaction V1)..."
hf_download "JOKER141/H3-Fight-Flow-Fight-Interaction-LoRA" "H3_Fight_Flow_V1.safetensors" "$BASE_DIR/loras"

step "SuperHunman.safetensors (LoRA - Superhuman Combat)..."
hf_download "JOKER141/H3-superhuman-combat-lora" "SuperHunman.safetensors" "$BASE_DIR/loras"

# Dance pair (JOKER141/H3-Dance-LoRA_Beat-Sync-Concept-Slider). Author's combo: Dance 0.7–0.9 + Slider +0.7–1.2;
# Slider alone +0.5–1.5 snaps hits, negative weights smooth the flow.
step "DANCE-minimax-h3.safetensors (LoRA - Dance Choreography & Groove v1.0)..."
hf_download "JOKER141/H3-Dance-LoRA_Beat-Sync-Concept-Slider" "DANCE-minimax-h3.safetensors" "$BASE_DIR/loras"

step "Dance Beat-Sync Slider.safetensors (LoRA - Dance Beat-Sync Concept Slider v1.0)..."
hf_download "JOKER141/H3-Dance-LoRA_Beat-Sync-Concept-Slider" "Dance Beat-Sync Slider.safetensors" "$BASE_DIR/loras"
# Upstream name has spaces — keep it, plus a space-free alias for graphs and shell tooling.
link_alias "$BASE_DIR/loras/Dance Beat-Sync Slider.safetensors" "$BASE_DIR/loras/Dance_Beat-Sync_Slider.safetensors"

# ── RelayVSR x2 video super-resolution (Comfy-Org/RelayVSR): every workflow selection ──
step "relayvsr_x2_lightx2v_int8_convrot.safetensors (RelayVSR x2 diffusion model, Comfy-Org/RelayVSR)..."
hf_download "Comfy-Org/RelayVSR" "diffusion_models/relayvsr_x2_lightx2v_int8_convrot.safetensors" "$BASE_DIR"

step "relayvsr_flash_vae_x2_fp32.safetensors (RelayVSR x2 flash VAE, Comfy-Org/RelayVSR)..."
hf_download "Comfy-Org/RelayVSR" "vae/relayvsr_flash_vae_x2_fp32.safetensors" "$BASE_DIR"

# ── Latent upscaler: BUNNY SelfLift + Pika Regen 2K ──
if want bunny || want regen2k; then
    step "minimax_h3_latent_upscaler_3d_fp16.safetensors (Latent Upscaler 3D, nested repo)..."
    SRC="minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors"
    TGT="$BASE_DIR/latent_upscale_models/minimax_h3_latent_upscaler_3d_fp16.safetensors"
    if [ ! -s "$TGT" ]; then
        hf_download "LBH-123-AI/Minimax_h3_latent_Upscaler" "$SRC" "$BASE_DIR/latent_upscale_models"
        if [ -s "$BASE_DIR/latent_upscale_models/$SRC" ]; then
            mv "$BASE_DIR/latent_upscale_models/$SRC" "$TGT"
            rmdir "$BASE_DIR/latent_upscale_models/$(dirname "$SRC")" 2>/dev/null || true
            echo "  ✅ flattened to $TGT"
        fi
    else
        echo "  ✅ already present: $TGT"
    fi
    # The workflows' upscaler dropdown names the _V2 file (same weights)
    link_alias "$TGT" "$BASE_DIR/latent_upscale_models/minimax_h3_latent_upscaler_3d_fp16_V2.safetensors"
fi

# ── Pika Regen 2K only ──
if want regen2k; then
    # Fast VAE: NVIDIA StreamRender-H3 non-causal 24L (OpenH3RegenFastVAEDecode)
    step "fast_h3_vae_noncausal_24l.safetensors (Fast VAE - NVIDIA StreamRender-H3)..."
    hf_download "Efficient-Large-Model/Open-H3-Regenerate-2K" "vae_fast/fast_h3_vae_noncausal_24l.safetensors" "$BASE_DIR/vae"
    if [ -s "$BASE_DIR/vae/vae_fast/fast_h3_vae_noncausal_24l.safetensors" ] && [ ! -s "$BASE_DIR/vae/fast_h3_vae_noncausal_24l.safetensors" ]; then
        mv "$BASE_DIR/vae/vae_fast/fast_h3_vae_noncausal_24l.safetensors" "$BASE_DIR/vae/fast_h3_vae_noncausal_24l.safetensors"
        rmdir "$BASE_DIR/vae/vae_fast" 2>/dev/null || true
        echo "  ✅ flattened to models/vae/fast_h3_vae_noncausal_24l.safetensors"
    fi
    link_alias "$BASE_DIR/vae/fast_h3_vae_noncausal_24l.safetensors" "$BASE_DIR/vae/vae_fast/fast_h3_vae_noncausal_24l.safetensors"

    # fl2v turbo v1.2: stage 2 loads it after the regenerate LoRA (web/src/server/comfy/graph.ts FLEX_UPSCALE.turbo).
    # Not a turbo-slot choice any more — Regen 2K only.
    step "minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors (LoRA - fl2v turbo 4-step v1.2 768p, Regen 2K stage 2)..."
    hf_download "lightx2v/Minimax-h3-Turbo" "minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors" "$BASE_DIR/loras"

    # LMS LoRA (MMH3 Ultimate Upscale group)
    step "minimax_h3_lms_v1.0_r64.safetensors (LoRA - MiniMax H3 LMS v1.0 r64)..."
    hf_download "Alissonerdx/Minimax-H3-ComfyUI" "loras/minimax_h3_lms_v1.0_r64.safetensors" "$BASE_DIR"
    link_alias "$BASE_DIR/loras/minimax_h3_lms_v1.0_r64.safetensors" "$BASE_DIR/loras/minimax-h3/minimax_h3_lms_v1.0_r64.safetensors"

    # Sharp curve branches (rdh9616 OpenH3RegenLora curve_name)
    step "sharp_curve_branches.safetensors (LoRA - NVIDIA Open-H3 Sharp Curve)..."
    mkdir -p "$BASE_DIR/loras/Open-H3-Regenerate-2K"
    if [ ! -s "$BASE_DIR/loras/Open-H3-Regenerate-2K/sharp_curve_branches.safetensors" ]; then
        hf_download "Efficient-Large-Model/Open-H3-Regenerate-2K" "lora/sharp_curve_branches.safetensors" "$BASE_DIR/loras"
        if [ -s "$BASE_DIR/loras/lora/sharp_curve_branches.safetensors" ]; then
            mv "$BASE_DIR/loras/lora/sharp_curve_branches.safetensors" "$BASE_DIR/loras/Open-H3-Regenerate-2K/sharp_curve_branches.safetensors"
            rmdir "$BASE_DIR/loras/lora" 2>/dev/null || true
        fi
    else
        echo "  ✅ already present: loras/Open-H3-Regenerate-2K/sharp_curve_branches.safetensors"
    fi
    link_alias "$BASE_DIR/loras/Open-H3-Regenerate-2K/sharp_curve_branches.safetensors" "$BASE_DIR/loras/sharp_curve_branches.safetensors"

    # Regenerate 2K LoRA (refiner + Turbo + Sharp merge), ~12.45GB
    step "open_h3_regenerate_2k_lora.safetensors (LoRA - NVIDIA Open-H3 Regenerate 2K)..."
    if [ ! -s "$BASE_DIR/loras/Open-H3-Regenerate-2K/open_h3_regenerate_2k_lora.safetensors" ]; then
        hf_download "Efficient-Large-Model/Open-H3-Regenerate-2K" "lora/open_h3_regenerate_2k_lora.safetensors" "$BASE_DIR/loras"
        if [ -s "$BASE_DIR/loras/lora/open_h3_regenerate_2k_lora.safetensors" ]; then
            mv "$BASE_DIR/loras/lora/open_h3_regenerate_2k_lora.safetensors" "$BASE_DIR/loras/Open-H3-Regenerate-2K/open_h3_regenerate_2k_lora.safetensors"
            rmdir "$BASE_DIR/loras/lora" 2>/dev/null || true
        fi
    else
        echo "  ✅ already present: loras/Open-H3-Regenerate-2K/open_h3_regenerate_2k_lora.safetensors"
    fi

    # RMBG-2.0 for the optional "cut out character/prop references" setting
    step "RMBG-2.0 (Background Removal model - 1038lab / BiRefNet)..."
    mkdir -p "$BASE_DIR/RMBG/RMBG-2.0"
    for rmbg_file in model.safetensors config.json BiRefNet_config.py birefnet.py; do
        if [ ! -s "$BASE_DIR/RMBG/RMBG-2.0/$rmbg_file" ]; then
            hf_download "1038lab/RMBG-2.0" "$rmbg_file" "$BASE_DIR/RMBG/RMBG-2.0"
        fi
    done
fi

echo "==> All downloads completed!"

# ── Restart ComfyUI ──
echo "==> Starting / restarting ComfyUI..."
COMFY_READY=0
if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui >/dev/null 2>&1; then
    echo "  Restarting via supervisorctl..."
    supervisorctl restart comfyui || true
    COMFYUI_PORT=8188
    COMFY_READY=1
elif [ -x "$LAUNCHER" ]; then
    echo "  No supervisor comfyui service — restarting via tmux launcher $LAUNCHER"
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

# ── Verify every custom node pack imported (ComfyUI only warns and keeps serving) ──
if [ "$COMFY_READY" = "1" ]; then
    _FAILED=$(grep -a "(IMPORT FAILED)" /workspace/comfyui.log 2>/dev/null | sed -E 's/.*\(IMPORT FAILED\): *//' || true)
    if [ -n "$_FAILED" ]; then
        echo "  ❌ Custom node packs failed to import — workflows using them will show missing nodes:"
        printf '      %s\n' $_FAILED
        grep -a -B1 "Cannot import" /workspace/comfyui.log | tail -10
        echo "❌ Setup finished with broken node packs (fix the error above, then restart ComfyUI)."
        exit 1
    fi
    echo "  ✅ All custom node packs imported"
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
        bunny)    echo "👉 Workflow: workflows/BUNNY_SelfLift_12GB_LORA.json" ;;
        regen2k)  echo "👉 Workflow: workflows/MinimaxH3_2Stage_Pika_Regen2K_Final.json" ;;
        flex)     echo "👉 Workflow: workflows/video_pika_h3_flex_ref2va.json" ;;
        standard) echo "👉 Workflow: workflows/minimax-h3.ui_v2_1_stage.json" ;;
    esac
done
echo "👉 Diffusion model on disk: $(basename "$DIFFUSION_FILE")"
echo "👉 Upload an image in the LoadImage node"
if [ -n "$CF_URL" ]; then
    echo "👉 ComfyUI public URL:      $CF_URL (saved in $CF_URL_FILE)"
fi
