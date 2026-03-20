# transcribe-cli

On-device speech-to-text for macOS using Apple's SpeechAnalyzer (Neural Engine). Records mic + system audio with speaker attribution. Also transcribes audio files.

## Install

```bash
brew install johnmatthewtennant/tap/transcribe-cli
transcribe --install-skill
```

Requires macOS 26+ (Tahoe).

## Claude Code

```
/transcribe-audio
```

## CLI

```
transcribe                                 # start recording
transcribe --title "Weekly sync"           # with title
transcribe --speakers "Alice,Bob"          # custom speaker names
transcribe --file recording.m4a            # transcribe audio file
transcribe --resume                        # resume last session
transcribe --resume-file foo.md            # resume specific file
transcribe --list                          # list past recordings
transcribe --help                          # full usage
```

Transcripts saved to `~/Documents/transcripts/`.

## Private API Notice

Uses Apple's private `SpeechAnalyzer.framework`. Not endorsed by Apple. May break with macOS updates.
