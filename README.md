# STT Recorder App

A simple yet powerful speech-to-text (STT) application that records audio and transcribes it using OpenAI's Whisper model via the faster-whisper library.

## Features

- **Flexible configuration** via `.env` file - no code changes needed
- **Record audio** from your microphone with manual or timed recording
- **Configurable stop signals** - use Ctrl+C, Enter, or Space to stop recording
- **Transcribe** recorded audio or existing audio files
- **Translation mode** - transcribe, translate to English, or both
- **Multiple audio formats** - WAV, MP3, M4A, FLAC, OGG, Opus, WebM, MP4
- **Multiple language support** - auto-detect or specify language
- **GPU acceleration** - CUDA support for faster transcription
- **Interactive CLI** - easy-to-use menu interface
- **Automatic cleanup** - optionally keep or delete recordings

### Supported Audio Formats

- WAV (.wav)
- MP3 (.mp3)
- M4A (.m4a)
- FLAC (.flac)
- OGG (.ogg)
- Opus (.opus)
- WebM (.webm)
- MP4 (.mp4)

### Available Model Sizes

The Whisper model comes in different sizes. Choose based on your needs:

- `tiny` - Fastest, least accurate (~1GB VRAM)
- `base` - Good balance (default) (~1GB VRAM)
- `small` - Better accuracy (~2GB VRAM)
- `medium` - High accuracy (~5GB VRAM)
- `large` - Best accuracy (~10GB VRAM)

## Configuration

The application is configured using a `.env` file. Create one from the example:

```bash
cp .env.example .env
```

Edit `.env` to customize settings:

```env
# Model settings
MODEL_SIZE=base        # Options: tiny, base, small, medium, large
DEVICE=auto           # Options: auto, cpu, cuda

# Recording settings
SAMPLE_RATE=16000
MAX_DURATION_MINUTES=90
STOP_SIGNAL=ctrl_c    # Options: ctrl_c, enter, space

# Transcription settings
LANGUAGE=en           # Language code or 'auto'
TASK=transcribe       # Options: transcribe, translate, both

# File management
KEEP_RECORDINGS=false
```

### Configuration Options

**Model Size**: Choose based on accuracy vs. speed tradeoff
- `tiny` - Fastest, least accurate (~1GB VRAM)
- `base` - Good balance (default)
- `small` - Better accuracy (~2GB VRAM)
- `medium` - High accuracy (~5GB VRAM)
- `large` - Best accuracy (~10GB VRAM)

**Stop Signal**: How to stop recording
- `ctrl_c` - Press Ctrl+C to stop (default)
- `enter` - Press Enter key to stop
- `space` - Press Space bar to stop

**Task**: What to do with the audio
- `transcribe` - Keep original language
- `translate` - Translate to English
- `both` - Output both transcription and translation

## Usage

### Interactive Mode

Run the application in interactive mode:

```bash
python stt_recorder_app.py
```

You'll be presented with a menu:

1. **Record and transcribe** - Record audio and transcribe it immediately
2. **Transcribe existing file** - Transcribe an audio file from disk
3. **List audio devices** - Show available microphones
4. **Exit** - Quit the application

### Programmatic Usage

You can also use the `STTRecorderApp` class in your own Python scripts:

```python
from stt_recorder_app import STTRecorderApp

# Initialize with default .env configuration
app = STTRecorderApp()

# Or specify a custom config file
app = STTRecorderApp(config_path="/path/to/custom.env")

# Record and transcribe (uses configured stop signal)
result = app.record_and_transcribe()
print(result['text'])

# For task="both", result includes both fields:
if 'translation' in result:
    print(f"Original: {result['text']}")
    print(f"English: {result['translation']}")

# Transcribe an existing file
result = app.transcribe_existing_file("path/to/audio.wav")
print(result['text'])
```

### Recording Behavior & Limits

**Recording Duration Limits:**
- Default maximum recording duration: **90 minutes**
- Prevents memory issues with very long recordings
- Configurable via `max_recording_minutes` parameter
- When limit is reached, recording automatically proceeds to transcription

**Stopping Recordings:**
- **Manual stop:** Press the configured stop signal (Ctrl+C, Enter, or Space)
- **Automatic stop:** Recording stops when duration limit is reached
- **Partial recordings:** Manual stop saves whatever has been recorded (not discarded)
- Both manual and automatic stops preserve the recorded audio
- Configure stop signal in `.env` with `STOP_SIGNAL` setting

**Result Dictionary:**
```python
result = {
    'text': str,        # Transcribed text
    'language': str,    # Detected language code
    'duration': float   # Audio duration in seconds
}
```

**Memory Optimization:**
- Optimized for multi-hour recordings
- Pre-allocated buffers for efficient memory usage
- Incremental transcription processing
- Suitable for long-form content like lectures or meetings

## Installation

### Requirements

- Python 3.8 or higher
- A working microphone for recording
- (Optional) NVIDIA GPU with CUDA for faster transcription

**Windows Users**: See [WINDOWS_DEPLOYMENT.md](WINDOWS_DEPLOYMENT.md) for detailed Windows-specific installation instructions.

### Standard Setup

```bash
# Clone or download this repository
git clone <repository-url>
cd whisper

# Create a virtual environment (recommended)
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Create configuration file
cp .env.example .env
# Edit .env to customize settings
```

### Optional: GPU Support

For GPU acceleration, install PyTorch with CUDA support:

```bash
pip install torch --index-url https://download.pytorch.org/whl/cu118
```

## Troubleshooting

### Audio Recording Issues

If you encounter audio device errors:

1. List available audio devices using option 3 in the interactive menu
2. Note the device index you want to use
3. Modify the code or specify the device parameter when calling recording functions

### GPU Not Detected

Make sure you have:
- NVIDIA GPU with CUDA support
- CUDA toolkit installed
- PyTorch with CUDA support installed

### Model Download

The first time you run the app with a specific model size, it will download the model automatically. This may take a few minutes depending on your internet connection.

## License

This project is provided as-is for educational and personal use.

## Acknowledgments

- [faster-whisper](https://github.com/guillaumekln/faster-whisper) - Fast implementation of OpenAI's Whisper
- [OpenAI Whisper](https://github.com/openai/whisper) - Original Whisper model
