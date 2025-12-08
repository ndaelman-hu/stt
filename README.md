# STT Recorder App

A simple yet powerful speech-to-text (STT) application that records audio and transcribes it using OpenAI's Whisper model via the faster-whisper library.

## Features

- Record audio from your microphone with manual or timed recording
- Transcribe recorded audio or existing audio files
- Support for multiple audio formats (WAV, MP3, M4A, FLAC, OGG, Opus, WebM, MP4)
- Multiple language support
- GPU acceleration support (CUDA)
- Interactive CLI interface
- Automatic cleanup of temporary files

## Requirements

- Python 3.8 or higher
- A working microphone for recording
- (Optional) NVIDIA GPU with CUDA for faster transcription

## Installation

### 1. Clone or download this repository

```bash
git clone <repository-url>
cd whisper
```

### 2. Create a virtual environment (recommended)

```bash
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
```

### 3. Install dependencies

```bash
pip install faster-whisper sounddevice soundfile
```

### Optional: GPU Support

For GPU acceleration, install PyTorch with CUDA support:

```bash
pip install torch --index-url https://download.pytorch.org/whl/cu118
```

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

# Record and transcribe (press Enter to stop recording)
result = app.record_and_transcribe()
print(result['text'])

# Transcribe an existing file
result = app.transcribe_existing_file("path/to/audio.wav")
print(result['text'])
```

### Model Sizes

The Whisper model comes in different sizes. Choose based on your needs:

- `tiny` - Fastest, least accurate (~1GB VRAM)
- `base` - Good balance (default) (~1GB VRAM)
- `small` - Better accuracy (~2GB VRAM)
- `medium` - High accuracy (~5GB VRAM)
- `large` - Best accuracy (~10GB VRAM)

Example with a different model:

```python
app = STTRecorderApp(model_size="small", device="cuda")
```

## Supported Audio Formats

- WAV (.wav)
- MP3 (.mp3)
- M4A (.m4a)
- FLAC (.flac)
- OGG (.ogg)
- Opus (.opus)
- WebM (.webm)
- MP4 (.mp4)

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
