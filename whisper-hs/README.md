# Whisper-HS: Real-time Speech-to-Text Transcriber

A Haskell implementation of the real-time speech-to-text transcription application using OpenAI's Whisper model. This is a complete port of the Python version with full feature parity.

## Features

- **Real-time audio recording** with multiple microphone support
- **Configurable stop signals**: Ctrl+C, Enter, or Space
- **Multiple transcription modes**:
  - Transcribe (keep original language)
  - Translate (translate to English)
  - Both (get both transcription and translation)
- **Flexible configuration** via `.env` files
- **Audio device enumeration** and selection
- **Automatic language detection**
- **Efficient memory management** for long recordings

## Requirements

### System Dependencies

- **Haskell**: GHC 8.10 or later
- **Cabal**: 3.0 or later
- **Python 3**: For Whisper wrapper script
- **faster-whisper**: Python package for speech recognition
- **arecord**: ALSA audio recording tool (Linux)

### Installation

1. **Install Haskell and Cabal**:
   ```bash
   # On Ubuntu/Debian
   sudo apt-get install ghc cabal-install

   # Update Cabal package index
   cabal update
   ```

2. **Install Python dependencies**:
   ```bash
   # Install faster-whisper
   pip3 install faster-whisper
   ```

3. **Install audio tools**:
   ```bash
   # On Ubuntu/Debian
   sudo apt-get install alsa-utils
   ```

4. **Build the Haskell application**:
   ```bash
   cd whisper-hs
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

4. Quit
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
    └── whisper_wrapper.py -- Python Whisper wrapper
```

### How It Works

1. **Configuration Loading**: Reads `.env` file using `dotenv` package
2. **Audio Capture**: Uses `arecord` via system process
3. **Stop Signal Detection**: Monitors terminal input with async threads
4. **Transcription**: Calls Python wrapper script that uses `faster-whisper`
5. **Result Display**: Parses JSON response and displays formatted results

### Whisper Integration

The application wraps the `faster-whisper` Python library via a subprocess interface:

```
Haskell App → Python Script → faster-whisper → Whisper Model
```

This approach:
- Avoids complex FFI bindings
- Leverages mature Python ML ecosystem
- Maintains separation of concerns
- Allows easy updates to Whisper versions

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

### "Whisper process failed"

Ensure `faster-whisper` is installed:
```bash
pip3 install --upgrade faster-whisper
```

### CUDA errors

If using CUDA, ensure:
- NVIDIA drivers are installed
- CUDA toolkit is installed
- `nvidia-smi` command works

Or set `DEVICE=cpu` in `.env` to use CPU only.

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

Differences:
- Uses Cabal instead of pip
- Audio via `arecord` instead of `sounddevice`
- STM for thread-safe state instead of `threading.Lock`
- Subprocess wrapper for Whisper instead of direct library calls

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
