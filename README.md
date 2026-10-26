# Nova

> Project repository for the **Meta Global AI Developer Hackathon**
> (Oct 26 – Nov 4, 2026). Rules, dates, and judging criteria:
> [HACKATHON.md](HACKATHON.md).

## Overview

Nova is a macOS AI companion that helps users understand on-screen content,
translate and rewrite text, and complete desktop tasks through voice commands
and a contextual radial menu.

**Status:** 🚧 Early prototype. This description is a working draft.

## How It Works

1. The user shares context (on-screen content or selected text) by voice or
   through the radial menu.
2. Meta open-weight models, deployed behind inference endpoints on
   [Modal](https://modal.com) GPU infrastructure, interpret the context and
   plan multi-step actions.
3. The macOS app executes approved actions through local tools and verifies
   the results.

## Key Features

- Understand and explain on-screen content
- Translate and rewrite text
- Complete desktop tasks with voice commands
- Contextual radial menu for quick actions
- User approval before any action runs

## Tech Stack

- **Client:** native macOS app
- **Models:** Meta open-weight models
- **Inference:** Modal GPU endpoints, also used to measure latency,
  reliability, and inference cost during prototyping

## Getting Started

### Prerequisites

- macOS with Python 3.10+ (standard library only, nothing to install)
- Chrome or Edge, for microphone recording and verified file saving
- A Meta Model API key from https://dev.meta.ai (API keys, then Create API key)

### Installation

```bash
git clone https://github.com/aobasar/Nova.git
cd Nova
cp .env.example .env.local   # then set MODEL_API_KEY
```

### Running the local web prototype

```bash
scripts/serve.sh             # serves http://127.0.0.1:9005 on this Mac only
```

A small Python server reads
`MODEL_API_KEY` from `.env.local` on each request and forwards calls to the Meta
Model API, so the key never reaches the browser.

1. Record with the microphone, or add an audio file. The page converts it to
   24 kHz mono WAV.
2. Press **Send for transcription** to get the transcript (Muse Voice
   Transcribe).
3. Pick an action (Auto, Ask, Translate, Rewrite, Summarize, Plan task) and
   press **Run** (Muse Spark 1.3).
4. Copy the result, or save it as a text file. The file is read back to
   verify the write.

**Conversation mode.** Tap the microphone once to start talking with Nova:
- Nova sends what you said as soon as you pause.
- It answers out loud with the macOS system voice, then listens again.
- If you start talking while Nova is speaking, it stops.
- Tap the microphone again to end, or stay quiet for a minute.
- Headphones keep Nova from hearing its own voice.

Paste a screenshot with ⌘V, or use **Attach image**, to ask about an image.
Nothing is stored: recordings, images and results live only in the open tab.

### Tests

```bash
python3 -m unittest discover -s web-prototype/tests
node --test web-prototype/tests/
```

## Project Structure

```
Nova/
├── README.md          # This file
├── HACKATHON.md       # Hackathon rules, dates, and judging criteria
├── CLAUDE.md          # Rules for AI-assisted development in this repo
├── .env.example       # Required environment variables (copy to .env.local)
├── scripts/serve.sh   # Starts the local web prototype on port 9005
└── web-prototype/
    ├── server.py      # Local server: UI files + Meta Model API proxy
    ├── static/        # Browser UI (HTML, CSS, JavaScript)
    └── tests/         # Server (Python) and audio helper (Node) tests
```

## Hackathon Submission Checklist

Submissions are due **Nov 4, 9:00 PM ET (6:00 PM PT)**.

- [ ] Pick the problem statement Nova fits
- [ ] Choose the track (Indie or Startup)
- [ ] Claim Meta Model API credits (by Nov 4, 9:00 PM ET)
- [ ] Finalize the product concept and tech stack
- [ ] Build the MVP
- [ ] Record the demo video
- [ ] Decide on repository visibility (currently private) and add a license
- [ ] Submit through the Cerebral Valley portal

## Team

- **Ahmet Basar** ([@aobasar](https://github.com/aobasar))

## Language Policy

Everything in this repository (code, comments, documentation, commit
messages, issues, and pull requests) is written in **English**.
