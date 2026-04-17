# Python Wrapper - DEPRECATED

This Python wrapper (`whisper_wrapper.py`) is **no longer used** as of the whisper.cpp migration.

The application now uses **whisper.cpp** directly via subprocess calls, eliminating the Python dependency.

## Why was it removed?

- **Simpler deployment**: No Python runtime or pip packages needed
- **Faster**: whisper.cpp is highly optimized C++ code
- **Lighter**: GGML quantized models are smaller
- **Self-contained**: Single binary + whisper.cpp executable

## Migration

If you were using the Python version:

**Before (Python)**:
```bash
pip install faster-whisper
python3 scripts/whisper_wrapper.py audio.wav --model-size base
```

**After (whisper.cpp)**:
```bash
# Build whisper.cpp once
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && make
./models/download-ggml-model.sh base

# Use it
./whisper.cpp/main -m models/ggml-base.bin -f audio.wav -oj
```

The Haskell application handles this automatically!
