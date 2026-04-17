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

echo "Step 1/5: Checking system dependencies..."
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

echo "Step 2/5: Building whisper.cpp..."
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

echo "Step 3/5: Downloading Whisper model ($WHISPER_MODEL)..."
if [ ! -f "models/ggml-${WHISPER_MODEL}.bin" ]; then
    bash ./models/download-ggml-model.sh "$WHISPER_MODEL"
    echo "✓ Whisper model downloaded"
else
    echo "✓ Whisper model already exists"
fi
cd ..
echo ""

echo "Step 4/5: Building llama.cpp and downloading TinyLlama..."
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

echo "Step 5/5: Building Haskell application..."
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
