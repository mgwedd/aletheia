# Aletheia — Setup Guide

This is a one-time setup. After this, using the app day-to-day is just:
open it, pick a patient, hit Record.

Before you record your first real session, please read **[CONSENT.md](../CONSENT.md)**
in this repository — recording a therapy session has consent and
licensing-board requirements that are your responsibility, not something
this app handles for you.

## What you'll install

| Tool | What it's for | How you get it |
|---|---|---|
| Aletheia.app | The app itself | Built from this repository (see below), or provided to you as a ready-made `.app` |
| Ollama | Runs the local AI model that writes summaries and answers questions | Normal Mac app install from [ollama.com](https://ollama.com) |

That's it. Unlike earlier drafts of this app, there's **no Homebrew, no
ffmpeg, no whisper.cpp command-line tool, and no BlackHole virtual audio
driver to install** — speech-to-text runs inside Aletheia itself, and
call audio is captured using a built-in macOS feature (the same permission
screen recorders use), not a third-party audio driver.

## Step 1 — Install Ollama

1. Go to [ollama.com](https://ollama.com) and download Ollama for Mac.
2. Open the downloaded file and drag Ollama into your Applications folder,
   like any other Mac app.
3. Open Ollama once. You'll see a small icon appear in the menu bar at the
   top of your screen — that means it's running in the background. Leave
   it running; Aletheia talks to it automatically.

## Step 2 — Install Aletheia

If you were given a ready-made `Aletheia.app`, skip to Step 3.

If you're building it yourself from this repository, you'll need Xcode
(free, from the App Store) installed first. Then, in Terminal:

```bash
cd path/to/aletheia
./scripts/build.sh
```

This creates `dist/Aletheia.app`. Move it into your Applications
folder.

## Step 3 — First launch

macOS will refuse to open the app the normal way the first time, because
it isn't notarized by Apple (that would require a paid Apple Developer
account). This is expected and only needs doing once:

1. In Finder, find **Aletheia** in Applications.
2. **Right-click** (or Control-click) it and choose **Open**.
3. A dialog will warn you it's from an unidentified developer — click
   **Open** to confirm. macOS will remember this and you can double-click
   normally from now on.

## Step 4 — Grant permissions

The app will ask for two permissions the first time it needs them:

- **Microphone** — so it can record your voice.
- **Screen & System Audio Recording** — so it can capture the other side
  of your video call. (This is the same permission any screen recorder
  app uses; Aletheia never records or stores video, only audio.)

If you accidentally deny either one, go to **System Settings > Privacy &
Security**, find the relevant section, and turn Aletheia on there.
You may need to quit and reopen the app afterward.

## Step 5 — Choose your data folder

The first time you open Aletheia, it'll ask where to keep your
patient data. Pick a folder inside **iCloud Drive** if you want it to back
up automatically — the app will suggest that location for you. All your
notes are saved there as plain files you can also browse directly in
Finder if you ever want to.

## Step 6 — Download the AI models

Open **Settings** inside Aletheia (the gear icon) and:

1. Under **Speech-to-Text Model**, click **Download**. The default
   ("Small") is a good balance of speed and accuracy on a MacBook Air —
   about 500 MB.
2. Under **AI Summaries & Chat**, click **Download llama3.1:8b**. This is
   a few gigabytes and can take a while depending on your internet
   connection.

The **Status** section at the bottom of Settings tells you, in plain
language, exactly what's ready and what isn't — check back here any time
something doesn't seem to be working.

## Using the app

1. Add a patient.
2. Open a patient, click **New Session**.
3. Click **Record Session** right when your video call starts, **Stop
   Recording** when it ends. Any call app works — Zoom, a browser (Tebra),
   FaceTime — because Aletheia captures your Mac's system audio, not one app.
   You can also Start / Pause / Stop from the menu-bar icon with the call
   window in front.
4. Click **Transcribe** — this runs entirely on your Mac and can take a
   few minutes for a longer session.
5. Click **Summarize with AI** on the Summary tab.
6. Use the **Ask** tab to ask questions about that session, or "Ask About
   All Sessions" on the patient screen to ask across everything you've
   recorded for that patient.

Everything above happens locally. Nothing is uploaded anywhere.
