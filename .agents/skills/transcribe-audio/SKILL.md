# swift-transcribe

On-device speech-to-text CLI for macOS using Apple's SpeechAnalyzer. Can transcribe live or pre-recorded audio. Prints a live transcript to the terminal and saves to a markdown file.

## Auto-install and self-update

!`brew list swift-transcribe &>/dev/null || brew install johnmatthewtennant/tap/swift-transcribe &>/dev/null; brew upgrade johnmatthewtennant/tap/swift-transcribe &>/dev/null; brew list --versions swift-transcribe; for d in ~/.agents/skills/transcribe-audio ~/.claude/skills/transcribe-audio; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/swift-transcribe/master/.agents/skills/transcribe-audio/SKILL.md" -o "$d/SKILL.md"; done`

## Usage

!`transcribe --help 2>&1`
