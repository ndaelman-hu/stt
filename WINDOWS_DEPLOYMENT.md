# Windows Deployment Guide

This guide covers how to install and run the STT Recorder App on Windows.

## Prerequisites

- Windows 10 or Windows 11
- Python 3.8 or higher
- A working microphone
- (Optional) NVIDIA GPU with CUDA support for faster transcription

## Installation Steps

### 1. Install Python

1. Download Python from [python.org](https://www.python.org/downloads/)
2. Run the installer
3. **Important**: Check "Add Python to PATH" during installation
4. Verify installation by opening Command Prompt and running:
   ```cmd
   python --version
   ```

### 2. Download the Project

```cmd
git clone https://github.com/your-username/stt.git
cd stt
```

Or download and extract the ZIP file from GitHub.

### 3. Create Virtual Environment

Open Command Prompt in the project directory:

```cmd
python -m venv .venv
.venv\Scripts\activate
```

You should see `(.venv)` in your command prompt.

### 4. Install Dependencies

```cmd
pip install faster-whisper sounddevice soundfile pydantic pydantic-settings pynput
```

### 5. Configure the Application

1. Copy the example configuration:
   ```cmd
   copy .env.example .env
   ```

2. Edit `.env` with Notepad or your preferred text editor:
   ```cmd
   notepad .env
   ```

3. Customize settings as needed (see Configuration section below)

## Running the Application

With the virtual environment activated:

```cmd
python stt_recorder_app.py
```

## Optional: GPU Acceleration (CUDA)

For faster transcription with NVIDIA GPUs:

### 1. Check GPU Compatibility

Ensure you have an NVIDIA GPU with CUDA support.

### 2. Install CUDA Toolkit

1. Download CUDA Toolkit 11.8 from [NVIDIA's website](https://developer.nvidia.com/cuda-downloads)
2. Run the installer and follow the prompts
3. Restart your computer

### 3. Install PyTorch with CUDA

```cmd
pip install torch --index-url https://download.pytorch.org/whl/cu118
```

### 4. Update Configuration

Edit `.env` and set:
```
DEVICE=cuda
```

Or use `DEVICE=auto` to automatically detect GPU availability.

## Configuration

The `.env` file controls all application settings:

### Model Settings

```env
MODEL_SIZE=base        # Options: tiny, base, small, medium, large
DEVICE=auto           # Options: auto, cpu, cuda
```

**Model Size Guide:**
- `tiny`: Fastest, least accurate (~1GB RAM)
- `base`: Good balance (default)
- `small`: Better accuracy (~2GB RAM)
- `medium`: High accuracy (~5GB RAM)
- `large`: Best accuracy (~10GB RAM)

### Recording Settings

```env
SAMPLE_RATE=16000              # Audio sample rate
MAX_DURATION_MINUTES=90         # Maximum recording length
STOP_SIGNAL=ctrl_c             # Options: ctrl_c, enter, space
```

### Transcription Settings

```env
LANGUAGE=en           # Language code (en, es, fr, de, etc.)
TASK=transcribe       # Options: transcribe, translate, both
```

**Task Options:**
- `transcribe`: Keep original language
- `translate`: Translate to English
- `both`: Output both transcription and translation

### File Management

```env
KEEP_RECORDINGS=false  # Keep audio files after transcription
```

## Troubleshooting

### Python Not Recognized

If you get "python is not recognized":
1. Reinstall Python and ensure "Add to PATH" is checked
2. Or add Python manually to your PATH environment variable

### Virtual Environment Activation Issues

If `.venv\Scripts\activate` doesn't work:
```cmd
# Try using PowerShell
.venv\Scripts\Activate.ps1

# Or run Python directly
.venv\Scripts\python.exe stt_recorder_app.py
```

### Microphone Not Detected

1. Check Windows microphone permissions:
   - Settings → Privacy → Microphone
   - Enable microphone access for desktop apps
2. Run the app and select option "3" to list audio devices
3. Note the device index and modify the code if needed

### CUDA/GPU Issues

If CUDA is not detected:
1. Verify NVIDIA drivers are installed:
   ```cmd
   nvidia-smi
   ```
2. Check CUDA installation:
   ```cmd
   nvcc --version
   ```
3. Reinstall PyTorch with CUDA support
4. Set `DEVICE=cpu` in `.env` to use CPU instead

### Permission Errors with pynput

On Windows, `pynput` generally works without admin privileges. If you encounter issues:
1. Run Command Prompt as Administrator
2. Or use `STOP_SIGNAL=ctrl_c` which uses KeyboardInterrupt

### Installation Errors

If pip installation fails:
```cmd
# Upgrade pip first
python -m pip install --upgrade pip

# Then retry installation
pip install faster-whisper sounddevice soundfile pydantic pydantic-settings pynput
```

### Audio Quality Issues

1. Check your microphone settings in Windows Sound Control Panel
2. Adjust `SAMPLE_RATE` in `.env` (16000 is standard for speech)
3. Ensure microphone is not muted or volume is too low

## Creating a Desktop Shortcut

Create a batch file `run_stt.bat`:

```batch
@echo off
cd /d "%~dp0"
call .venv\Scripts\activate.bat
python stt_recorder_app.py
pause
```

Right-click the batch file → Send to → Desktop (create shortcut)

## Deactivating Virtual Environment

When finished:
```cmd
deactivate
```

## Uninstallation

1. Deactivate virtual environment
2. Delete the project folder
3. (Optional) Uninstall Python from Windows Settings

## Additional Resources

- [Faster Whisper Documentation](https://github.com/guillaumekln/faster-whisper)
- [Python Windows FAQ](https://docs.python.org/3/faq/windows.html)
- [CUDA Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-microsoft-windows/)
