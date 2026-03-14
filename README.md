# swift-transcribe

A command-line tool for on-device speech-to-text transcription on macOS, using Apple's SpeechAnalyzer framework.

Records microphone and system audio simultaneously, producing speaker-attributed markdown transcripts in real time. Also supports offline transcription of audio files.

## Install

```bash
brew install johnmatthewtennant/tap/swift-transcribe
```

## Requirements

- macOS 26+ (Tahoe)
- Xcode Command Line Tools (`xcode-select --install`)
- Microphone permission (granted on first run)
- Screen Recording permission (for system audio capture)

### Build from source

```bash
git clone https://github.com/johnmatthewtennant/swift-transcribe.git
cd swift-transcribe
make install
```

## Usage

### Live transcription

```bash
# Start recording with default speaker names (You / Remote)
transcribe

# Set speaker names
transcribe --speakers "Jack,Jeanne"

# Set a session title
transcribe --title "Weekly sync"

# Resume the most recent recording
transcribe --resume-last
```

### File transcription

```bash
# Transcribe an audio file (m4a, wav, mp3, caf)
transcribe --file recording.m4a

# With a custom title and speaker name
transcribe --file call.wav --title "Client call" --speakers "Client"
```

### Manage recordings

```bash
# List past recordings
transcribe --list
```

Transcripts are saved to `~/Documents/transcripts/` as markdown files.
