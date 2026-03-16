# Name Brainstorm

A macOS CLI that records mic + system audio, transcribes in real-time with speaker attribution, outputs structured markdown. Designed for both humans and AI agents.

## Landscape

Notable existing tools in this exact space:
- **hear** (sveinbjornt/hear) - macOS CLI for built-in speech recognition. Well-known, 500+ stars.
- **yap** (finnvoor/yap) - macOS CLI for on-device transcription with `listen-and-dictate` for calls + speaker labels. Very close to what we're building.
- **scribe** - Extremely crowded name. Multiple repos (trailofbits/scribe, perrette/scribe, etc.) plus the scribe-org organization.

## Top Candidates

### 1. `mic2md` - AVAILABLE
Mic-to-markdown. Descriptive, short, unique on GitHub. Says exactly what it does.
- Pro: Immediately communicates the pipeline (microphone -> markdown)
- Pro: No existing projects found
- Pro: Works great as a CLI command (`mic2md record`, `mic2md listen`)
- Con: Slightly technical/dry, not particularly memorable

### 2. `auditxt` - AVAILABLE
Audio + text portmanteau.
- Pro: No existing projects found
- Pro: Short, distinctive spelling
- Pro: "Audit" subtly implies careful listening/recording
- Con: Could be misread as "audit-text" (security auditing)
- Con: Slightly awkward to say aloud

### 3. `voxlog` - AVAILABLE
Vox (Latin for voice) + log.
- Pro: No existing projects found
- Pro: Short (6 chars), rolls off the tongue
- Pro: "Log" conveys structured output, agent-friendly
- Pro: Works well as CLI command (`voxlog start`, `voxlog stop`)
- Con: "Vox" prefix is used by several other projects (VoxMedia, VoxScribe, etc.)

### 4. `tapescript` - SOFT AVAILABLE
Tape (recording) + script (transcript).
- Pro: Evocative -- tapes + scripts are classic transcription metaphors
- Pro: No well-known CLI project with this name
- Con: A few small repos exist (compatibl/tapescript for algorithmic differentiation, harrycorrigan/TapeScript)
- Con: 10 characters, a bit long for a CLI command

### 5. `hearback` - AVAILABLE
"Hear back" -- play back what was heard, as text.
- Pro: No existing projects found
- Pro: Friendly, conversational name
- Pro: Implies the feedback loop: audio in, text back
- Con: Could be confused with audio monitoring/playback tools

### 6. `transcrybe` - SOFT AVAILABLE
Transcribe with a "y" twist.
- Pro: Immediately communicates purpose
- Con: spacefarers/Transcryb exists (same creative spelling idea)
- Con: Cute misspelling may feel unprofessional
- Con: 10 characters

### 7. `listenup` - AVAILABLE
Friendly command: "listen up!"
- Pro: No well-known project with this name
- Pro: Memorable, conversational
- Pro: Good CLI command (`listenup record`)
- Con: Doesn't convey transcription or structured output
- Con: 8 characters

### 8. `recap` - AVAILABLE
As in: "give me the recap of that meeting."
- Pro: No well-known CLI transcription tool with this name
- Pro: Short (5 chars), everyday English word
- Pro: Perfectly describes the use case (recapping meetings/conversations)
- Pro: Works great as CLI command (`recap start`, `recap stop`)
- Con: Very common English word -- SEO/discoverability could be harder
- Con: Doesn't specifically say "audio" or "transcription"

### 9. `echotext` - SOFT AVAILABLE
Echo (audio) + text.
- Pro: Communicates audio-to-text
- Con: neilflodin/echotext exists (predictive text app, unrelated but same name)
- Con: "Echo" is strongly associated with Amazon Echo
- Con: 8 characters

### 10. `dictate` - TAKEN (crowded)
- Con: Multiple dictation projects exist (exectx/dictation for macOS, OmniDictate-CLI, etc.)
- Con: "Dictation" implies speaking-to-type, not transcription of conversations

## Recommendation

**Top 3 picks:**

1. **`recap`** - Best balance of short, memorable, and descriptive. "Give me the recap" is exactly the use case. Available on GitHub. Works as both repo name and CLI command.

2. **`voxlog`** - Best "invented word" option. Short, distinctive, voice + structured log. Clearly available.

3. **`mic2md`** - Best "does what it says on the tin" option. Unmistakable purpose, completely unique.
