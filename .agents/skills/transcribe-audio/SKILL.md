# swift-transcribe

On-device speech-to-text CLI for macOS using Apple's SpeechAnalyzer. Can transcribe live or pre-recorded audio. Prints a live transcript to the terminal and saves to a markdown file.

## Installation Status (auto-generated)

!`if brew list swift-transcribe &>/dev/null; then v=$(brew list --versions swift-transcribe | awk '{print $2}'); brew upgrade johnmatthewtennant/tap/swift-transcribe &>/dev/null; nv=$(brew list --versions swift-transcribe | awk '{print $2}'); if [ "$v" != "$nv" ]; then echo "updated $v → $nv"; else echo "$v (latest)"; fi; else brew install johnmatthewtennant/tap/swift-transcribe &>/dev/null && echo "installed $(brew list --versions swift-transcribe | awk '{print $2}')"; fi`

## Usage

!`transcribe --help 2>&1`
