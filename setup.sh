#!/bin/bash
set -e  # Exit on error

echo "========================================="
echo "  Whisper-HS Setup Script"
echo "========================================="
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Configuration
WHISPER_MODEL="${1:-base}"  # Default to base model
LLAMA_MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
# Note: "recongition" is a genuine typo in the upstream sherpa-onnx release tag
DIARIZE_SEG_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
DIARIZE_EMB_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

echo "Step 1/6: Checking system dependencies..."
# Check for required tools
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git first."
    exit 1
fi

if ! command -v make &> /dev/null; then
    echo "Error: make is not installed. Please install build-essential."
    exit 1
fi

if ! command -v cabal &> /dev/null; then
    echo "Error: cabal is not installed. Please install ghc and cabal-install."
    exit 1
fi

if ! command -v wget &> /dev/null; then
    echo "Warning: wget not found, will try curl..."
    USE_CURL=1
else
    USE_CURL=0
fi

echo "✓ All required tools found"
echo ""

echo "Step 2/6: Building whisper.cpp..."
if [ ! -d "whisper.cpp" ]; then
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git
else
    echo "whisper.cpp already exists, updating..."
    cd whisper.cpp
    git pull
    cd ..
fi

cd whisper.cpp
echo "Building whisper.cpp..."
make -j$(nproc)
echo "✓ whisper.cpp built successfully"
echo ""

echo "Step 3/6: Downloading Whisper model ($WHISPER_MODEL)..."
if [ ! -f "models/ggml-${WHISPER_MODEL}.bin" ]; then
    bash ./models/download-ggml-model.sh "$WHISPER_MODEL"
    echo "✓ Whisper model downloaded"
else
    echo "✓ Whisper model already exists"
fi
cd ..
echo ""

echo "Step 4/6: Building llama.cpp and downloading TinyLlama..."
if [ ! -d "llama.cpp" ]; then
    echo "Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git
else
    echo "llama.cpp already exists, updating..."
    cd llama.cpp
    git pull
    cd ..
fi

cd llama.cpp
echo "Building llama.cpp with CMake..."
cmake -B build
cmake --build build --config Release -j$(nproc)
# Create symlink for backward compatibility
ln -sf build/bin/llama-cli main 2>/dev/null || true
echo "✓ llama.cpp built successfully"

# Create models directory if it doesn't exist
mkdir -p models

echo "Downloading TinyLlama model..."
if [ ! -f "models/tinyllama-1.1b-chat.gguf" ]; then
    if [ $USE_CURL -eq 1 ]; then
        curl -L "$LLAMA_MODEL_URL" -o models/tinyllama-1.1b-chat.gguf
    else
        wget "$LLAMA_MODEL_URL" -O models/tinyllama-1.1b-chat.gguf
    fi
    echo "✓ TinyLlama model downloaded"
else
    echo "✓ TinyLlama model already exists"
fi
cd ..
echo ""

echo "Step 5/6: Building sherpa-onnx and downloading diarization models..."
if ! command -v cmake &> /dev/null; then
    echo "Warning: cmake not found; skipping speaker diarization setup."
    echo "Install cmake and re-run setup.sh to enable diarization."
else
    # v1.10.30 pins onnxruntime 1.17.1, which links against older libstdc++
    # (GCC 9 compatible); newer sherpa-onnx bundles an onnxruntime that
    # requires GCC 11+.
    SHERPA_ONNX_VERSION=v1.10.30
    if [ ! -d "sherpa-onnx" ]; then
        echo "Cloning sherpa-onnx ($SHERPA_ONNX_VERSION)..."
        git clone --depth 1 --branch "$SHERPA_ONNX_VERSION" https://github.com/k2-fsa/sherpa-onnx.git
    else
        echo "sherpa-onnx already exists, pinning $SHERPA_ONNX_VERSION..."
        cd sherpa-onnx
        git fetch --depth 1 origin tag "$SHERPA_ONNX_VERSION"
        git checkout "$SHERPA_ONNX_VERSION"
        cd ..
    fi

    cd sherpa-onnx
    echo "Building sherpa-onnx (fetches onnxruntime at configure time; needs network)..."
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DSHERPA_ONNX_ENABLE_TESTS=OFF
    cmake --build build --config Release -j$(nproc) --target sherpa-onnx-offline-speaker-diarization
    echo "✓ sherpa-onnx built successfully"

    mkdir -p models

    echo "Downloading speaker segmentation model (pyannote segmentation-3.0)..."
    if [ ! -d "models/sherpa-onnx-pyannote-segmentation-3-0" ]; then
        if [ $USE_CURL -eq 1 ]; then
            curl -L "$DIARIZE_SEG_MODEL_URL" -o segmentation-model.tar.bz2
        else
            wget "$DIARIZE_SEG_MODEL_URL" -O segmentation-model.tar.bz2
        fi
        tar xf segmentation-model.tar.bz2 -C models
        rm segmentation-model.tar.bz2
        echo "✓ Segmentation model downloaded"
    else
        echo "✓ Segmentation model already exists"
    fi

    echo "Downloading speaker embedding model (3D-Speaker ERes2Net)..."
    EMB_MODEL_FILE="models/$(basename "$DIARIZE_EMB_MODEL_URL")"
    if [ ! -f "$EMB_MODEL_FILE" ]; then
        if [ $USE_CURL -eq 1 ]; then
            curl -L "$DIARIZE_EMB_MODEL_URL" -o "$EMB_MODEL_FILE"
        else
            wget "$DIARIZE_EMB_MODEL_URL" -O "$EMB_MODEL_FILE"
        fi
        echo "✓ Embedding model downloaded"
    else
        echo "✓ Embedding model already exists"
    fi
    cd ..
fi
echo ""

echo "Step 6/6: Building Haskell application..."
cabal update
cabal build
echo "✓ Haskell application built successfully"
echo ""

echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo ""
echo "Models installed:"
echo "  - Whisper: whisper.cpp/models/ggml-${WHISPER_MODEL}.bin"
echo "  - LLM: llama.cpp/models/tinyllama-1.1b-chat.gguf"
echo "  - Diarization: sherpa-onnx/models/ (segmentation + speaker embedding)"
echo ""
echo "Speaker diarization:"
echo "  Set DIARIZATION_ENABLED=true in .env (or toggle it in the app menu)"
echo "  to label transcript turns per speaker. Requires SAMPLE_RATE=16000."
echo ""
echo "To run the application:"
echo "  cabal run whisper-hs"
echo ""
echo "To download other Whisper models, run:"
echo "  cd whisper.cpp && bash ./models/download-ggml-model.sh <model>"
echo "  where <model> is: tiny, base, small, medium, or large"
echo ""
echo "Configuration:"
echo "  Copy .env.example to .env and customize settings"
echo ""
