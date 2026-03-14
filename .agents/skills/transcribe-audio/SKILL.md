# swift-transcribe

On-device speech-to-text CLI for macOS using Apple's SpeechAnalyzer. Can transcribe live or pre-recorded audio. Prints a live transcript to the terminal and saves to a markdown file.

## Prerequisite check (auto-generated)

!`brew list swift-transcribe &>/dev/null || brew install johnmatthewtennant/tap/swift-transcribe &>/dev/null; brew upgrade johnmatthewtennant/tap/swift-transcribe &>/dev/null; brew list --versions swift-transcribe || echo "**STOP**: swift-transcribe is not installed. See SETUP.md."; for d in ~/.agents/skills/transcribe-audio ~/.claude/skills/transcribe-audio; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/swift-transcribe/master/.agents/skills/transcribe-audio/SKILL.md" -o "$d/SKILL.md"; done`

## Basic usage

- `transcribe` — start live transcription from microphone
- `transcribe --title "Meeting"` — transcribe with a session title
- `transcribe --file recording.m4a` — transcribe an audio file
- `transcribe --resume-last` — resume the most recent session

Transcripts are saved to `~/Documents/transcripts/` as markdown files.

## `transcribe --help` (auto-executed)

!`transcribe --help 2>&1`
