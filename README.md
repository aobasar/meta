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

_TBD_

### Installation

```bash
git clone https://github.com/aobasar/Nova.git
cd Nova
cp .env.example .env.local   # then fill in your API keys
# further setup steps will be added once the stack is chosen
```

### Running

_TBD_

## Project Structure

```
Nova/
├── README.md     # This file
├── HACKATHON.md  # Hackathon rules, dates, and judging criteria
├── CLAUDE.md     # Rules for AI-assisted development in this repo
├── .env.example  # Required environment variables (copy to .env.local)
└── .gitignore
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
