"""Configuration management using Pydantic Settings"""
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field
from enum import Enum


class ModelSize(str, Enum):
    """Available Whisper model sizes"""
    TINY = "tiny"
    BASE = "base"
    SMALL = "small"
    MEDIUM = "medium"
    LARGE = "large"


class Device(str, Enum):
    """Available compute devices"""
    AUTO = "auto"
    CPU = "cpu"
    CUDA = "cuda"


class StopSignal(str, Enum):
    """Available stop signals for recording"""
    CTRL_C = "ctrl_c"
    ENTER = "enter"
    SPACE = "space"

    def get_key(self) -> str:
        """
        Get the key identifier for this stop signal

        Returns:
            String identifier for the key ("ctrl_c", "enter", or "space")
        """
        return self.value


class Task(str, Enum):
    """Transcription task types"""
    TRANSCRIBE = "transcribe"  # Keep original language
    TRANSLATE = "translate"    # Translate to English
    BOTH = "both"              # Both transcribe and translate


class AppConfig(BaseSettings):
    """Application configuration loaded from .env file"""

    model_config = SettingsConfigDict(
        env_file='.env',
        env_file_encoding='utf-8',
        case_sensitive=False,
        extra='ignore'
    )

    # Model settings
    model_size: ModelSize = Field(
        default=ModelSize.BASE,
        description="Whisper model size (tiny, base, small, medium, large)"
    )
    device: Device = Field(
        default=Device.AUTO,
        description="Compute device (auto, cpu, cuda)"
    )

    # Recording settings
    sample_rate: int = Field(
        default=16000,
        ge=8000,
        le=48000,
        description="Audio sample rate in Hz"
    )
    max_duration_minutes: int = Field(
        default=90,
        ge=1,
        le=300,
        description="Maximum recording duration in minutes"
    )
    stop_signal: StopSignal = Field(
        default=StopSignal.CTRL_C,
        description="Signal to stop recording (ctrl_c, enter, space)"
    )

    # Transcription settings
    language: str = Field(
        default="en",
        description="Language code for transcription (en, es, fr, etc.) or 'auto'"
    )
    task: Task = Field(
        default=Task.TRANSCRIBE,
        description="Task type: 'transcribe', 'translate', or 'both'"
    )

    # File management
    keep_recordings: bool = Field(
        default=False,
        description="Keep audio files after transcription"
    )

    def should_transcribe(self) -> bool:
        """Check if transcription (keeping original language) is enabled"""
        return self.task in (Task.TRANSCRIBE, Task.BOTH)

    def should_translate(self) -> bool:
        """Check if translation (to English) is enabled"""
        return self.task in (Task.TRANSLATE, Task.BOTH)

    def get_device_string(self) -> str:
        """Get device as string, resolving 'auto' if needed"""
        if self.device == Device.AUTO:
            try:
                import torch
                return "cuda" if torch.cuda.is_available() else "cpu"
            except ImportError:
                return "cpu"
        return self.device.value


def load_config(env_file: str = ".env") -> AppConfig:
    """
    Load configuration from .env file

    Args:
        env_file: Path to .env file (relative or absolute).
                 Relative paths are resolved from the current working directory.
                 Example: ".env" or "/absolute/path/to/.env"

    Returns:
        AppConfig instance with validated settings
    """
    return AppConfig(_env_file=env_file)
