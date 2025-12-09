# STT Recorder App

A simple yet powerful speech-to-text (STT) application that records audio and transcribes it using OpenAI's Whisper model via the faster-whisper library.

## Features

- Record audio from your microphone with manual or timed recording
- Transcribe recorded audio or existing audio files
- Support for multiple audio formats (WAV, MP3, M4A, FLAC, OGG, Opus, WebM, MP4)
- Multiple language support (automatically transcribes speech from any supported language into English text)
- GPU acceleration support (CUDA)
- Interactive CLI interface
- Automatic cleanup of temporary files

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

# Initialize the app
app = STTRecorderApp(model_size="base", device="cpu")

# Record and transcribe (press Ctrl+C to stop recording)
result = app.record_and_transcribe()
print(result['text'])

# Transcribe an existing file
result = app.transcribe_existing_file("path/to/audio.wav")
print(result['text'])

# Use a different model size
app = STTRecorderApp(model_size="small", device="cuda")

# Configure recording duration limit (default: 60 minutes)
app = STTRecorderApp(max_recording_minutes=120)  # 2-hour limit
```

### Recording Behavior & Limits

**Recording Duration Limits:**
- Default maximum recording duration: **60 minutes**
- Prevents memory issues with very long recordings
- Configurable via `max_recording_minutes` parameter
- When limit is reached, recording automatically proceeds to transcription

**Stopping Recordings:**
- **Manual stop:** Press `Ctrl+C` during recording
- **Automatic stop:** Recording stops when duration limit is reached
- **Partial recordings:** Ctrl+C saves whatever has been recorded (not discarded)
- Both manual and automatic stops preserve the recorded audio

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

### Standard Setup

```bash
# Clone or download this repository
git clone <repository-url>
cd whisper

# Create a virtual environment (recommended)
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install dependencies
pip install faster-whisper sounddevice soundfile
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
