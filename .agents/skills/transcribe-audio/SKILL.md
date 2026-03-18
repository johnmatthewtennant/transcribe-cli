---
name: transcribe-audio
description: Transcribe audio on macOS — live mic + system audio recording or pre-recorded audio files. Use when transcribing meetings, recordings, or audio files to text.
allowed-tools:
  - Bash(brew list *)
  - Bash(brew outdated *)
  - Bash(transcribe *)
metadata:
  author: jtennant
  version: "0.1.0"
---

# swift-transcribe

On-device speech-to-text CLI for macOS using Apple's SpeechAnalyzer. Can transcribe live or pre-recorded audio. Prints a live transcript to the terminal and saves to a markdown file.

## Prerequisite check (auto-generated)

!`brew list --versions swift-transcribe || echo "STOP: swift-transcribe is not installed. Run: brew install johnmatthewtennant/tap/swift-transcribe. See SETUP.md."`

!`brew outdated swift-transcribe 2>/dev/null || echo "STOP: swift-transcribe is outdated. Run: brew upgrade swift-transcribe. See SETUP.md."`

## Basic usage

- `transcribe` — start live transcription from microphone
- `transcribe --title "Meeting"` — transcribe with a session title
- `transcribe --file recording.m4a` — transcribe an audio file
- `transcribe --resume-last` — resume the most recent session

Transcripts are saved to `~/Documents/transcripts/` as markdown files.

## `transcribe --help` (auto-executed)

!`transcribe --help 2>&1`
