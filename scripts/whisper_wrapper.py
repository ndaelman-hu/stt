#!/usr/bin/env python3
"""
Whisper wrapper script for Haskell STT application.
This script provides a JSON interface to faster-whisper.
"""

import sys
import json
import argparse
from faster_whisper import WhisperModel
import gc

def transcribe_audio(audio_path, model_size, device, language, task):
    """
    Transcribe audio file using faster-whisper.

    Args:
        audio_path: Path to audio file
        model_size: Model size (tiny, base, small, medium, large)
        device: Device to use (cpu, cuda)
        language: Language code (None for auto-detect)
        task: Task type (transcribe, translate, both)

    Returns:
        dict with transcription results
    """
    try:
        # Initialize model
        model = WhisperModel(model_size, device=device, compute_type="float16" if device == "cuda" else "int8")

        # Perform transcription
        result = {"success": True}

        # Handle different task modes
        if task in ["transcribe", "both"]:
            segments, info = model.transcribe(
                audio_path,
                language=language,
                task="transcribe"
            )

            # Collect segments
            text_segments = []
            for segment in segments:
                text_segments.append(segment.text)

            result["text"] = " ".join(text_segments).strip()
            result["language"] = info.language
            result["duration"] = info.duration

        if task in ["translate", "both"]:
            segments, info = model.transcribe(
                audio_path,
                task="translate"
            )

            # Collect translation segments
            translation_segments = []
            for segment in segments:
                translation_segments.append(segment.text)

            translation = " ".join(translation_segments).strip()

            if task == "translate":
                result["text"] = translation
                result["language"] = "en"
                result["duration"] = info.duration
            else:
                result["translation"] = translation

        # Explicit garbage collection to prevent memory leaks
        gc.collect()

        return result

    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }

def main():
    parser = argparse.ArgumentParser(description="Whisper transcription wrapper")
    parser.add_argument("audio_path", help="Path to audio file")
    parser.add_argument("--model-size", default="base", choices=["tiny", "base", "small", "medium", "large"])
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    parser.add_argument("--language", default=None, help="Language code (e.g., 'en', 'es')")
    parser.add_argument("--task", default="transcribe", choices=["transcribe", "translate", "both"])

    args = parser.parse_args()

    # Perform transcription
    result = transcribe_audio(
        args.audio_path,
        args.model_size,
        args.device,
        args.language,
        args.task
    )

    # Output JSON result
    print(json.dumps(result))

if __name__ == "__main__":
    main()
