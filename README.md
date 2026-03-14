# swift-transcribe

On-device speech-to-text for macOS using Apple's SpeechAnalyzer (Neural Engine). Records mic + system audio with speaker attribution. Also transcribes audio files.

Live recordings stream to the terminal in real time and save to a markdown file. Have an AI agent tail the transcript file during a meeting and it becomes a live meeting assistant — answering questions, taking notes, and tracking action items from the ongoing conversation.

## Install

```bash
brew install --with-skill johnmatthewtennant/tap/swift-transcribe
```

Requires macOS 26+ (Tahoe).

## Claude Code

```
/transcribe-audio
```

## CLI

```bash
transcribe                                 # start recording
transcribe --title "Weekly sync"           # with title
transcribe --speakers "Alice,Bob"        # custom speaker names
transcribe --file recording.m4a            # transcribe audio file
transcribe --resume-last                   # resume last session
transcribe --list                          # list past recordings
transcribe --help                          # full usage
```

Transcripts saved to `~/Documents/transcripts/`.
