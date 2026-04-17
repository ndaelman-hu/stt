# Whisper-HS: Real-time Speech-to-Text Transcriber

A Haskell implementation of the real-time speech-to-text transcription application using OpenAI's Whisper model. This is a complete port of the Python version with full feature parity.

## Features

### Core Transcription
- **Real-time audio recording** with multiple microphone support
- **Configurable stop signals**: Ctrl+C, Enter, or Space
- **Multiple transcription modes**:
  - Transcribe (keep original language)
  - Translate (translate to English)
  - Both (get both transcription and translation)
- **Audio device enumeration** and selection
- **Automatic language detection**
- **Efficient memory management** for long recordings

### Meeting Minutes & Post-Processing
- **Grammar & punctuation correction** using LLM (llama.cpp)
- **Automatic TODO extraction** from meeting transcripts
- **Markdown meeting minutes** with action items
- **Clean text output** for documentation

## Requirements

### System Dependencies

- **Haskell**: GHC 8.10 or later
- **Cabal**: 3.0 or later
- **whisper.cpp**: C++ implementation of Whisper (no Python needed!)
- **arecord**: ALSA audio recording tool (Linux)

### Installation

1. **Install Haskell and Cabal**:
   ```bash
   # On Ubuntu/Debian
   sudo apt-get install ghc cabal-install

   # Update Cabal package index
   cabal update
   ```

2. **Build whisper.cpp**:
   ```bash
   # Clone and build whisper.cpp
   cd /home/nathan/Programs/whisper
   git clone https://github.com/ggerganov/whisper.cpp.git
   cd whisper.cpp
   make

   # Download a model (base model recommended)
   bash ./models/download-ggml-model.sh base
   # Or download other sizes: tiny, small, medium, large
   ```

3. **Build llama.cpp (for meeting minutes features)**:
   ```bash
   # Clone and build llama.cpp
   cd /home/nathan/Programs/whisper
   git clone https://github.com/ggerganov/llama.cpp.git
   cd llama.cpp
   make

   # Download TinyLlama model (fast, ~600MB)
   wget https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
     -O models/tinyllama-1.1b-chat.gguf
   ```

3. **Install audio tools**:
   ```bash
   # On Ubuntu/Debian
   sudo apt-get install alsa-utils
   ```

4. **Build the Haskell application**:
   ```bash
   cd /home/nathan/Programs/whisper/whisper-hs
   cabal build
   ```

## Configuration

Create a `.env` file in the project root (or copy from `.env.example`):

```bash
# Whisper model size: tiny, base, small, medium, large
MODEL_SIZE=base

# Compute device: auto, cpu, cuda
DEVICE=auto

# Audio sample rate (Hz): 8000-48000
SAMPLE_RATE=16000

# Maximum recording duration (minutes): 1-300
MAX_DURATION_MINUTES=90

# Stop signal: ctrl_c, enter, space
STOP_SIGNAL=ctrl_c

# Language code (leave empty for auto-detection)
# Examples: en, es, fr, de, ja, zh
LANGUAGE=

# Task mode: transcribe, translate, both
TASK=transcribe

# Keep recorded audio files: true, false
KEEP_RECORDINGS=false
```

## Usage

### Running the Application

```bash
# Run with default .env configuration
cabal run whisper-hs

# Or specify a custom config file
cabal run whisper-hs -- /path/to/custom.env
```

### Interactive Menu

The application presents an interactive menu:

```
1. Record and transcribe audio
   - Choose duration (or manual stop)
   - Select audio device
   - Get transcription results

2. Transcribe existing audio file
   - Provide path to audio file
   - Supports: WAV, MP3, M4A, FLAC, OGG, Opus, WebM, MP4

3. List audio devices
   - Shows available microphones

4. Clean transcription file
   - Fix grammar and punctuation using LLM
   - Outputs cleaned version to new file

5. Extract TODOs from file
   - Extract action items from meeting transcript
   - Generates markdown meeting minutes with TODO list

6. Quit
```

### Recording Options

**Timed Recording**:
```
Duration in seconds: 10
```

**Manual Stop**:
```
Duration in seconds: [press Enter]
```
Then press your configured stop signal (Ctrl+C, Enter, or Space).

### Example Workflow

1. Start the application
2. Choose option 1 (Record and transcribe)
3. Press Enter for manual stop
4. Start speaking
5. Press your stop signal when done
6. View transcription results

## Configuration Options

### Model Sizes

- `tiny`: Fastest, lowest accuracy (~1GB RAM)
- `base`: Good balance (~1GB RAM)
- `small`: Better accuracy (~2GB RAM)
- `medium`: High accuracy (~5GB RAM)
- `large`: Best accuracy (~10GB RAM)

### Device Options

- `auto`: Automatically detect CUDA availability
- `cpu`: Force CPU usage
- `cuda`: Use NVIDIA GPU (requires CUDA toolkit)

### Task Modes

- `transcribe`: Keep original language
- `translate`: Translate to English
- `both`: Get both transcription and translation

### Stop Signals

- `ctrl_c`: Press Ctrl+C to stop (traditional)
- `enter`: Press Enter to stop (convenient)
- `space`: Press Space to stop (quick)

## Architecture

### Module Structure

```
whisper-hs/
├── src/
│   └── STT/
│       ├── Config.hs      -- Configuration management
│       ├── Audio.hs       -- Audio recording
│       ├── Whisper.hs     -- Whisper integration
│       └── App.hs         -- Main application logic
├── app/
│   └── Main.hs            -- Entry point
└── scripts/
    ├── whisper_wrapper.py -- [DEPRECATED] Old Python wrapper
    └── DEPRECATED.md      -- Migration notes
```

### How It Works

1. **Configuration Loading**: Reads `.env` file using `dotenv` package
2. **Audio Capture**: Uses `arecord` via system process
3. **Stop Signal Detection**: Monitors terminal input with async threads
4. **Transcription**: Calls `whisper.cpp` binary with JSON output
5. **Result Display**: Parses JSON response and displays formatted results

### Whisper Integration

The application uses **whisper.cpp** - a pure C++ implementation of OpenAI's Whisper:

```
Haskell App → whisper.cpp binary → GGML Model
```

This approach:
- **No Python dependency** - fully self-contained
- **Fast** - C++ implementation with optimizations
- **Lightweight** - quantized GGML models
- **Cross-platform** - builds on Linux, macOS, Windows
- **Simple integration** - subprocess with JSON output

## Troubleshooting

### "arecord: command not found"

Install ALSA utilities:
```bash
sudo apt-get install alsa-utils
```

### "No audio devices found"

Check your audio devices:
```bash
arecord -L
```

### "whisper.cpp failed" or "whisper.cpp/main: not found"

Ensure whisper.cpp is built and in the correct location:
```bash
cd /home/nathan/Programs/whisper/whisper.cpp
make
ls -la main  # Should show the compiled binary
```

The application expects `whisper.cpp/main` relative to the whisper directory.

### "Model not found"

Download the model you're trying to use:
```bash
cd /home/nathan/Programs/whisper/whisper.cpp
bash ./models/download-ggml-model.sh base
# Or: tiny, small, medium, large
```

Models are downloaded to `whisper.cpp/models/` directory.

### CUDA/GPU Support

whisper.cpp supports CUDA, but requires recompiling with CUDA support:
```bash
cd whisper.cpp
make clean
WHISPER_CUBLAS=1 make
```

Or use CPU-only (default) which works well for real-time transcription.

### Build errors

Update Cabal dependencies:
```bash
cabal update
cabal clean
cabal build
```

## Comparison with Python Version

This Haskell port provides:
- ✅ Full feature parity
- ✅ Type-safe configuration
- ✅ Functional architecture
- ✅ Concurrent recording and monitoring
- ✅ Same user experience
- ✅ **No Python dependency** - uses whisper.cpp instead

Differences:
- Uses Cabal instead of pip
- Audio via `arecord` instead of `sounddevice`
- STM for thread-safe state instead of `threading.Lock`
- whisper.cpp (C++) instead of faster-whisper (Python)
- Fully self-contained binary (no Python runtime needed)

## Contributing

Contributions welcome! Areas for improvement:
- PortAudio FFI for cross-platform audio
- Native whisper.cpp bindings
- Additional stop signal options
- GUI interface
- Streaming transcription

## License

MIT License

## Credits

- Original Python version by Nathan Daelman
- OpenAI Whisper model
- faster-whisper library by Guillaume Klein
