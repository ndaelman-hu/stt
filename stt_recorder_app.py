from faster_whisper import WhisperModel
import sounddevice as sd
import soundfile as sf
import numpy as np
import os
import tempfile
import time
import threading
import sys
import select
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, Any
from config import AppConfig, load_config, StopSignal, Task

class STTRecorderApp:
    def __init__(self, config_path: str = ".env"):
        """
        Initialize the STT Recorder App

        Args:
            config_path: Path to configuration file (relative or absolute).
                        Relative paths are resolved from the current working directory.
                        Example: ".env" or "/absolute/path/to/.env"
        """
        # Load configuration
        self.config = load_config(config_path)

        # Get settings from config
        model_size = self.config.model_size.value
        device = self.config.get_device_string()
        self.sample_rate = self.config.sample_rate
        self.max_recording_minutes = self.config.max_duration_minutes

        print(f"Loading Whisper model '{model_size}' on {device}...")
        self.model = WhisperModel(model_size, device=device, compute_type="float16" if device == "cuda" else "int8")
        self.is_recording = False
        self.stop_requested = threading.Event()

        # Calculate maximum buffer size to prevent unbounded memory growth
        # At 16kHz sample rate, float32 (4 bytes): ~3.66 MiB / min
        self.max_audio_samples = int(self.sample_rate * 60 * self.max_recording_minutes)
        
    def list_audio_devices(self):
        """List available audio input devices"""
        print("Available audio devices:")
        print(sd.query_devices())
    
    def record_audio(self, duration=None, device=None):
        """
        Record audio for specified duration or until stopped

        Args:
            duration: Recording duration in seconds (None for manual stop)
            device: Audio device index (None for default)

        Returns:
            Path to temporary audio file
        """
        # Create temporary file
        temp_file = tempfile.NamedTemporaryFile(
            suffix='.wav',
            delete=False,
            prefix=f'recording_{datetime.now().strftime("%Y%m%d_%H%M%S")}_'
        )
        temp_path = temp_file.name
        temp_file.close()

        audio_data = None
        stream = None  # Track stream for cleanup in exception handlers
        try:
            if duration:
                print(f"Recording for {duration} seconds...")
                audio_data = sd.rec(
                    int(duration * self.sample_rate),
                    samplerate=self.sample_rate,
                    channels=1,
                    device=device,
                    dtype='float32'
                )
                try:
                    sd.wait()  # Wait until recording is finished
                    print("Recording finished!")
                except KeyboardInterrupt:
                    print("\nRecording interrupted by user during timed recording.")
                    audio_data = None
                    return None
            else:
                # Get stop signal configuration and display message
                stop_key = self.config.stop_signal.get_key()
                stop_msg = {
                    StopSignal.CTRL_C: "Ctrl+C",
                    StopSignal.ENTER: "Enter",
                    StopSignal.SPACE: "Space"
                }.get(self.config.stop_signal, "configured key")

                print(f"Recording... (Press {stop_msg} to stop, or auto-stop at {self.max_recording_minutes} min)")
                self.is_recording = True
                self.stop_requested.clear()

                # Pre-allocate buffer for maximum recording duration
                # This avoids memory reallocation and extend() calls during recording
                audio_buffer = np.zeros((self.max_audio_samples, 1), dtype='float32')
                buffer_position = 0
                buffer_full_warning_shown = False
                warning_lock = threading.Lock()  # Protects buffer_full_warning_shown flag
                buffer_lock = threading.Lock()   # Protects buffer_position and buffer writes

                # Start recording in background
                # Note: sounddevice typically calls callbacks sequentially from a single audio thread,
                # but we use locks for formal thread safety as defensive programming
                def record_callback(indata, frames, time, status):
                    nonlocal buffer_position, buffer_full_warning_shown
                    if self.is_recording:
                        frames_to_write = len(indata)
                        buffer_full = False

                        # Protect buffer operations from race with main thread
                        # Note: We avoid nested lock acquisition to prevent potential deadlocks
                        with buffer_lock:
                            # Check if buffer has space
                            if buffer_position + frames_to_write > self.max_audio_samples:
                                buffer_full = True
                            else:
                                # Write directly into pre-allocated array (no reallocation needed)
                                audio_buffer[buffer_position:buffer_position + frames_to_write] = indata
                                buffer_position += frames_to_write

                        # Handle buffer full condition outside buffer_lock to avoid nested locks
                        if buffer_full:
                            with warning_lock:
                                if not buffer_full_warning_shown:
                                    print(f"\nMaximum recording duration reached. Proceeding to transcription...")
                                    buffer_full_warning_shown = True
                            self.is_recording = False
                            return

                stream = sd.InputStream(
                    callback=record_callback,
                    samplerate=self.sample_rate,
                    channels=1,
                    device=device,
                    dtype='float32'
                )

                # Set up stdin listener for stop signal (only responds when terminal is focused)
                def stdin_listener():
                    """Monitor stdin for key presses - only works when terminal has focus"""
                    if stop_key == "ctrl_c":
                        return  # Ctrl+C handled via KeyboardInterrupt

                    try:
                        while self.is_recording and not self.stop_requested.is_set():
                            # Use select to check if input is available (non-blocking)
                            # Timeout of 0.1 seconds to check recording status regularly
                            if sys.stdin in select.select([sys.stdin], [], [], 0.1)[0]:
                                char = sys.stdin.read(1)

                                # Check for Enter key (newline)
                                if stop_key == "enter" and char in ('\n', '\r'):
                                    self.stop_requested.set()
                                    break
                                # Check for Space key
                                elif stop_key == "space" and char == ' ':
                                    self.stop_requested.set()
                                    break
                    except Exception:
                        pass  # Silently handle any stdin errors

                listener_thread = None
                if stop_key != "ctrl_c":
                    listener_thread = threading.Thread(target=stdin_listener, daemon=True)
                    listener_thread.start()

                stream.start()

                try:
                    # Monitor recording status - exit when buffer fills or stop requested
                    while self.is_recording and not self.stop_requested.is_set():
                        time.sleep(0.1)  # Check every 100ms

                    if self.stop_requested.is_set():
                        print("\nRecording stopped by user.")
                except KeyboardInterrupt:
                    # User pressed Ctrl+C (for ctrl_c mode or as fallback)
                    print("\nRecording stopped by user.")

                self.is_recording = False
                if listener_thread and listener_thread.is_alive():
                    # Thread will exit on its own when is_recording becomes False
                    listener_thread.join(timeout=0.5)
                stream.stop()
                stream.close()

                # Trim buffer to actual recorded size
                # Lock to ensure we read the final buffer_position atomically
                with buffer_lock:
                    final_position = buffer_position
                audio_data = audio_buffer[:final_position]

            # Validate we have audio data before saving
            if audio_data is None:
                raise ValueError("No audio data object returned (recording failed or interrupted)")
            if audio_data.size == 0:
                raise ValueError("Recorded audio is empty (zero length). Check device and settings.")

            # Save to temporary file
            sf.write(temp_path, audio_data, self.sample_rate)
            print(f"Audio saved to: {temp_path}")
            return temp_path

        except Exception as e:
            # Clean up temp file on any error
            print(f"Error during recording: {e}")
            if os.path.exists(temp_path):
                try:
                    os.unlink(temp_path)
                    print(f"Cleaned up temporary file: {temp_path}")
                except OSError:
                    pass  # File may not exist or already deleted
            raise

        finally:
            # Always clean up stream if it was created
            if stream is not None:
                try:
                    stream.stop()
                    stream.close()
                except Exception:
                    pass  # Stream may already be stopped or not started
    
    @staticmethod
    def _collect_segments(segments) -> str:
        """
        Collect text from segments into a single string

        Args:
            segments: Iterator of transcription segments

        Returns:
            Combined text from all segments
        """
        text_parts = []
        for segment in segments:
            text_parts.append(segment.text)
        return " ".join(text_parts).strip()

    def transcribe_file(self, audio_path: str) -> Dict[str, Any]:
        """
        Transcribe audio file using configured task settings

        Args:
            audio_path: Path to audio file

        Returns:
            Dictionary with transcription results.
            For task="both", includes both 'text' (original) and 'translation' (English).
        """
        import gc

        result: Dict[str, Any] = {}

        # Handle "transcribe" or "both" tasks
        if self.config.should_transcribe():
            print("Transcribing audio (keeping original language)...")
            segments, info = self.model.transcribe(audio_path, language=self.config.language, task="transcribe")
            result['text'] = self._collect_segments(segments)
            result['language'] = info.language
            result['duration'] = info.duration
            gc.collect()

        # Handle "translate" or "both" tasks
        if self.config.should_translate():
            print("Translating audio to English...")
            segments, info = self.model.transcribe(audio_path, language=self.config.language, task="translate")
            translation = self._collect_segments(segments)

            # If only translating (not "both"), put in 'text' field
            if self.config.task == Task.TRANSLATE:
                result['text'] = translation
                result['language'] = info.language
                result['duration'] = info.duration
            else:
                # For "both", add as separate 'translation' field
                result['translation'] = translation

            gc.collect()

        return result
    
    def record_and_transcribe(self, duration: Optional[int] = None, device: Optional[int] = None) -> Dict[str, Any]:
        """
        Complete workflow: Record -> Transcribe -> Clean up

        Args:
            duration: Recording duration in seconds (None for manual stop)
            device: Audio device to use (None for default)

        Returns:
            Transcription result
        """
        audio_path = None
        try:
            # Record audio
            audio_path = self.record_audio(duration=duration, device=device)

            if audio_path is None:
                return {}

            # Transcribe
            result = self.transcribe_file(audio_path)

            # Display results
            print(f"\n--- Transcription Result ---")
            if 'language' in result:
                print(f"Language: {result['language']}")
            if 'duration' in result:
                print(f"Duration: {result['duration']:.2f} seconds")
            if 'text' in result:
                print(f"Text: {result['text']}")
            if 'translation' in result:
                print(f"Translation (English): {result['translation']}")
            print("--- End Result ---\n")

            return result

        finally:
            # Clean up audio file based on config
            if audio_path and os.path.exists(audio_path) and not self.config.keep_recordings:
                os.unlink(audio_path)
                print(f"Cleaned up audio file: {audio_path}")
    
    def transcribe_existing_file(self, file_path: str) -> Optional[Dict[str, Any]]:
        """
        Transcribe an existing audio file

        Args:
            file_path: Path to existing audio file

        Returns:
            Transcription result or None on error
        """
        # Validate file extension
        valid_extensions = {'.wav', '.mp3', '.m4a', '.flac', '.ogg', '.opus', '.webm', '.mp4'}
        file_ext = Path(file_path).suffix.lower()

        if file_ext not in valid_extensions:
            print(f"Error: '{file_path}' is not a supported audio file.")
            print(f"Supported formats: {', '.join(sorted(valid_extensions))}")
            return None

        try:
            result = self.transcribe_file(file_path)

            # Display results
            print(f"\n--- Transcription Result ---")
            print(f"File: {file_path}")
            if 'language' in result:
                print(f"Language: {result['language']}")
            if 'duration' in result:
                print(f"Duration: {result['duration']:.2f} seconds")
            if 'text' in result:
                print(f"Text: {result['text']}")
            if 'translation' in result:
                print(f"Translation (English): {result['translation']}")
            print("--- End Result ---\n")

            return result

        except Exception as e:
            print(f"Error transcribing file: {e}")
            return None


def main():
    """Interactive CLI for the STT Recorder App"""
    print("STT Recorder App")
    print("================")

    # Initialize app with config
    app = STTRecorderApp()

    while True:
        print("\nOptions:")
        print("1. Record and transcribe (manual stop)")
        print("2. Transcribe existing file")
        print("3. List audio devices")
        print("4. Exit")

        choice = input("\nEnter choice (1-4): ").strip()

        if choice == "1":
            try:
                app.record_and_transcribe()
            except Exception as e:
                print(f"Error: {e}")

        elif choice == "2":
            file_path = input("Enter path to audio file: ").strip()
            if os.path.exists(file_path):
                try:
                    app.transcribe_existing_file(file_path)
                except Exception as e:
                    print(f"Error: {e}")
            else:
                print("File not found!")

        elif choice == "3":
            app.list_audio_devices()

        elif choice == "4":
            print("Goodbye!")
            break

        else:
            print("Invalid choice. Please try again.")


if __name__ == "__main__":
    main()
