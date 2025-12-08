from faster_whisper import WhisperModel
import sounddevice as sd
import soundfile as sf
import os
import tempfile
import time
import threading
from datetime import datetime
from pathlib import Path

class STTRecorderApp:
    def __init__(self, model_size="base", sample_rate=16000, device="cpu"):
        """
        Initialize the STT Recorder App
        
        Args:
            model_size: Whisper model size (tiny, base, small, medium, large)
            sample_rate: Audio sample rate in Hz
            device: "cpu" or "cuda" for GPU acceleration
        """
        print(f"Loading Whisper model '{model_size}' on {device}...")
        self.model = WhisperModel(model_size, device=device, compute_type="float16" if device == "cuda" else "int8")
        self.sample_rate = sample_rate
        self.is_recording = False
        self.audio_data = []
        
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
                sd.wait()  # Wait until recording is finished
                print("Recording finished!")
            else:
                print("Recording... Press Enter to stop.")
                self.is_recording = True
                self.audio_data = []
                
                # Start recording in background
                def record_callback(indata, frames, time, status):
                    if self.is_recording:
                        self.audio_data.extend(indata.copy())
                
                stream = sd.InputStream(
                    callback=record_callback,
                    samplerate=self.sample_rate,
                    channels=1,
                    device=device,
                    dtype='float32'
                )
                
                stream.start()
                input()  # Wait for Enter key
                self.is_recording = False
                stream.stop()
                stream.close()
                
                audio_data = self.audio_data
                print("Recording stopped!")
            
            # Save to temporary file
            sf.write(temp_path, audio_data, self.sample_rate)
            print(f"Audio saved to: {temp_path}")
            return temp_path
            
        except Exception as e:
            # Clean up on error
            if os.path.exists(temp_path):
                os.unlink(temp_path)
            raise e
    
    def transcribe_file(self, audio_path, language="en"):
        """
        Transcribe audio file
        
        Args:
            audio_path: Path to audio file
            language: Language code (en, es, fr, etc.)
            
        Returns:
            Dictionary with transcription results
        """
        print("Transcribing audio...")
        segments, info = self.model.transcribe(audio_path, language=language)
        
        # Convert segments generator to list and extract text
        segments_list = list(segments)
        full_text = " ".join([segment.text for segment in segments_list]).strip()
        
        return {
            'text': full_text,
            'language': info.language,
            'segments': segments_list,
            'duration': info.duration
        }
    
    def record_and_transcribe(self, duration=None, language="en", device=None, keep_file=False):
        """
        Complete workflow: Record -> Transcribe -> Clean up
        
        Args:
            duration: Recording duration in seconds (None for manual stop)
            language: Language for transcription
            device: Audio device to use
            keep_file: If True, don't delete the audio file
            
        Returns:
            Transcription result
        """
        audio_path = None
        try:
            # Record audio
            audio_path = self.record_audio(duration=duration, device=device)
            
            # Transcribe
            result = self.transcribe_file(audio_path, language=language)
            
            print(f"\n--- Transcription Result ---")
            print(f"Language: {result['language']}")
            print(f"Duration: {result['duration']:.2f} seconds")
            print(f"Text: {result['text']}")
            print("--- End Result ---\n")
            
            return result
            
        finally:
            # Clean up audio file
            if audio_path and os.path.exists(audio_path) and not keep_file:
                os.unlink(audio_path)
                print(f"Cleaned up audio file: {audio_path}")
    
    def transcribe_existing_file(self, file_path, language="en", delete_after=False):
        """
        Transcribe an existing audio file

        Args:
            file_path: Path to existing audio file
            language: Language for transcription
            delete_after: Whether to delete file after transcription
        """
        # Validate file extension
        valid_extensions = {'.wav', '.mp3', '.m4a', '.flac', '.ogg', '.opus', '.webm', '.mp4'}
        file_ext = Path(file_path).suffix.lower()

        if file_ext not in valid_extensions:
            print(f"Error: '{file_path}' is not a supported audio file.")
            print(f"Supported formats: {', '.join(sorted(valid_extensions))}")
            return None

        try:
            result = self.transcribe_file(file_path, language=language)

            print(f"\n--- Transcription Result ---")
            print(f"File: {file_path}")
            print(f"Language: {result['language']}")
            print(f"Duration: {result['duration']:.2f} seconds")
            print(f"Text: {result['text']}")
            print("--- End Result ---\n")

            return result

        except Exception as e:
            print(f"Error transcribing file: {e}")
            return None

        finally:
            if delete_after and os.path.exists(file_path):
                os.unlink(file_path)
                print(f"Deleted file: {file_path}")


def main():
    """Interactive CLI for the STT Recorder App"""
    print("STT Recorder App")
    print("================")
    
    # Check for GPU availability
    try:
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
    except ImportError:
        device = "cpu"
    print(f"Using device: {device}")
    
    # Initialize app
    app = STTRecorderApp(model_size="base", device=device)
    
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
                delete_after = input("Delete file after transcription? (y/n): ").lower().startswith('y')
                try:
                    app.transcribe_existing_file(file_path, delete_after=delete_after)
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