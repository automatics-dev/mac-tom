# TOM Desktop for Mac

**Meeting intelligence that compounds. Every meeting makes TOM smarter.**

Meeting intelligence for advisors, lawyers, therapists, and founders who can't put client audio in someone else's cloud. Native macOS menu bar app. Fully on-device AI — your recordings, your transcripts, your summaries, your search, all on your Mac. Nothing is ever uploaded. Free and open source under the Apache License 2.0 — no account, no licence keys, no meeting caps.

*Requires an Apple Silicon Mac running macOS 14.6 (Sonoma) or later.*

*Current version: v1.18.0*

---

## What TOM Does

TOM lives in your menu bar. Pick a window, hit record, and it captures the meeting silently — no bot joining your call, no participants notified, nothing uploaded anywhere. When the meeting ends, TOM transcribes it, writes a structured summary (TL;DR, action items, decisions, discussion topics, and open questions), and indexes every word for cross-meeting search — all on your Mac.

The longer you use TOM, the smarter it gets. After 60 meetings, you can ask *"what did we agree on pricing with Acme?"* and get a cited answer across 8 conversations with video timestamps. After 120 meetings, you have institutional memory — every decision, every promise, searchable by meaning.

> **Questions you can ask TOM:**
>
> - *"What did we promise Acme on the security-review timeline?"*
> - *"Which objections did EU customers raise about pricing in Q1?"*
> - *"Did we ever decide who owns the onboarding rewrite?"*
>
> TOM searches across every meeting and returns a cited answer with the meeting title, date, and a video timestamp you can click into.

---

## Who TOM Is For

TOM is built for professionals who run a lot of meetings and can't put the audio in someone else's cloud.

- **Regulated solo practitioners** — lawyers, therapists, coaches, financial advisors, M&A advisors, healthcare consultants, journalists. Privilege, HIPAA, and source confidentiality make cloud meeting tools a liability. TOM runs end-to-end on your machine, so it's an option where Granola, Otter, and Fireflies are not.
- **Independent advisors and operators** — consultants, fractional executives, indie founders, sales-led founders. You take 15+ meetings a week, you remember client commitments by hunting through old notes, and you'd rather not feed every conversation into a SaaS to find them again.
- **Mac-native technical operators** — engineering managers, CTOs, indie hackers. You want a local-first tool you can inspect: model weights cache to `~/Library/Caches`, prompts live in plain markdown you can edit, diagnostic logs live in `~/Library/Logs/TOM/tom.log`, the binary is signed and hardened-runtime.

If you take fewer than two meetings a week, or you're on Windows or an Intel Mac, TOM is probably not for you.

---

## Core Features

| Feature | What it means |
|---|---|
| **Invisible recording** | ScreenCaptureKit captures any window — Zoom, Meet, Teams, Webex, Slack huddles, in-person on speakerphone. No bot joins your call. |
| **Video + audio** | Full H.264/AAC MP4 retained locally. Re-watch screen shares, demos, presentations — not just text. |
| **Dual-stream capture** | System audio (the other side) and your microphone recorded in parallel, then muxed for playback. |
| **On-device transcription** | WhisperKit + Whisper large-v3-turbo runs locally on Apple Silicon. Audio never leaves your Mac. |
| **Structured summaries** | Every recording gets a TL;DR, action items, decisions, discussion topics, and open questions. Generated entirely on-device by Qwen 3 4B Instruct (4-bit MLX). |
| **Map-reduce for long meetings** | Transcripts past ~48K characters (~50 minutes) are chunked, extracted in parallel passes, then reduced to a single coherent summary so 2-hour meetings don't blow the context window. |
| **Editable AI prompts** | Tune the summary and title prompts in Settings → General → Advanced if you want a different style, length, or set of sections. Prompts use `{{kindNoun}}` and `{{language}}` placeholders. |
| **Cross-meeting semantic search** | Ask questions in natural language. TOM embeds your query locally, searches every meeting, and returns answers with inline `[1]` citations to the source meetings (title + date) and video timestamps. |
| **Multilingual** | Embeddings via `multilingual-e5-small` cover 100+ languages. Whisper detects the spoken language and TOM passes it as a hint to the summary/title prompt, so non-English meetings get non-English writeups. |
| **Karaoke video playback** | Watch the recording back with synchronised subtitles that highlight word-by-word as you listen. |
| **Voice notes** | Mic-only recordings for solo capture — same pipeline, same library. |
| **File import** | Drop in any `.mp4`, `.m4a`, `.mp3`, `.wav`, `.mov` and TOM transcribes and indexes it. |
| **Meeting groups** | Apple Notes–style folders. Drag meetings between groups. |
| **Auto meeting detection** | Spots Zoom, Google Meet, Teams, Webex and Slack Huddle windows and offers a one-click record prompt. |
| **Serialised processing queue** | Multiple recordings, retranscribes, or imports queue up FIFO instead of fighting over the GPU. You see a "Queued" badge on meetings waiting their turn. |
| **Idle model unload** | Whisper and Qwen are dropped from RAM between pipeline stages and after the Ask box has been idle, so TOM doesn't sit on ~4 GB of weights when you're not using it. |
| **Light & dark mode** | Adaptive semantic colors with an orange accent. |

---

## Privacy

TOM does all AI processing on your Mac. There is no automatics server, no account, no telemetry, no analytics, no sync. Recordings, transcripts, embeddings, summaries, and model weights all stay on your Mac — nothing is ever uploaded.

Network activity is limited to: the one-time AI model download from Hugging Face on first launch, and a once-a-day check for app updates. Neither touches your meeting data.

---

## On-Device Model Stack

| Stage | Model | Size | License | Backend |
|---|---|---|---|---|
| Transcription | Whisper large-v3-turbo | ~1.5 GB | MIT | WhisperKit (CoreML) |
| Summaries / Title / RAG synthesis | Qwen 3 4B Instruct 2507 (4-bit) | ~2.4 GB | Apache 2.0 | MLXLLM |
| Embeddings | intfloat/multilingual-e5-small | ~120 MB | MIT | MLXEmbedders |

Every stage runs locally on Apple Silicon — your meetings never leave your Mac. First launch downloads ~4 GB total from Hugging Face. Recommended free space: 6 GB. Whisper and the embedder cache under `~/Documents/huggingface/`; the LLM caches to `~/Library/Caches/models/`. You can re-download or wipe them from Settings → AI Models.

---

## How It Works

1. **Record.** Click the menu bar icon, pick a window. ScreenCaptureKit captures video at 2x Retina, 30 fps, with system audio + your mic in parallel.
2. **Queue.** When you stop, the meeting enters a serial processing queue. Existing in-flight work finishes before yours starts, so concurrent stops/imports don't fork competing pipelines.
3. **Transcribe.** Whisper large-v3-turbo runs locally via WhisperKit on the system-audio track and the mic track in parallel, then merges them into speaker-labelled turns (Me / Speaker). Whisper also detects the spoken language.
4. **Drop the voice model.** Whisper is unloaded from RAM before the summariser runs, so the two heavyweights never coexist.
5. **Summarise.** With language as a hint, TOM generates a title and structured summary (TL;DR, action items, decisions, discussion topics, open questions) locally on Qwen 3 4B. Short transcripts go in one pass; long transcripts use map-reduce — chunked extraction with rolling context, then a final reduce pass.
6. **Index.** Transcript chunked into ~500-token segments, embedded via `multilingual-e5-small` (384-dim, 100+ languages), stored as float32 vectors in SQLite.
7. **Search.** Ask a question. TOM embeds your query, brute-force scans every vector with Apple's Accelerate framework (vDSP SIMD), and feeds the top matches back to Qwen for a cited answer.
8. **Unload.** After ~5 minutes of inactivity in the Ask box, the summariser model is dropped from RAM.

Local search at 1,000 meetings: **~50ms**. 100% recall (exact KNN, no approximation).

---

## How TOM Tunes the Local LLM

TOM runs Qwen 3 4B with three generation settings. Think of them as knobs on a vending machine for words.

### `maxTokens: 1024`

The length limit on the answer. A "token" is roughly 3–4 characters of English text, so 1024 tokens ≈ 700–800 words ≈ a couple of pages. More tokens = more time to generate (the AI writes one token at a time) and more memory needed during generation. 1024 leaves room for a structured meeting summary (TL;DR + action items + decisions + discussion + open questions) without letting the AI ramble or chew through more memory than is safe on a typical Mac.

### `temperature: 0.3`

The creativity dial. Runs from 0 to roughly 1.5. When the AI picks each word, it actually has many candidates — each with a probability. Temperature controls how willing it is to pick a less-likely word.

- **Temperature 0** — always picks the single most likely word. Very predictable, sometimes robotic, sometimes repetitive.
- **Temperature 1** — picks roughly according to the natural probabilities. Varied, more "human" sounding, but can wander.
- **Temperature 1.5+** — aggressively picks unusual words. Creative, sometimes nonsense.

0.3 is "low temperature" — the AI strongly prefers the most likely word but with just enough variation to not sound like a robot. Good for tasks where you want consistency and accuracy rather than flair.

### `topP: 0.9`

A safety net for the creativity dial. Also called "nucleus sampling." Imagine the AI ranks all possible next words by likelihood. `topP: 0.9` says: *"Only consider the top words whose combined probability adds up to 90% of the total. Ignore the bottom 10% of unlikely candidates entirely."* Even if temperature would technically let the AI pick a wild word, topP throws away the genuinely weird options before that decision is even made.

---

## Settings

All settings live under **Settings…** in the menu-bar dropdown or the TOM app menu.

- **General**
  - Launch at Login.
  - Notify me when a meeting starts.
  - Software Updates: automatic checks, automatic downloads, manual *Check Now*.
  - Screen-recording troubleshooting notes (Chrome / Arc hardware-acceleration workaround).
  - **Advanced** (collapsible): edit the summary prompt and the title prompt as plain markdown. Reset to default at any time. Templates support `{{kindNoun}}` and `{{language}}` placeholders.
- **AI Models** (three vertical cards, top → bottom)
  - **Voice AI** — Whisper large-v3-turbo. Always on-device. Per-model Download / Re-download.
  - **Think AI** — Qwen 3 4B. Runs on-device. Download status + Re-download.
  - **Search AI** — multilingual-e5-small. Always on-device. Per-model Download / Re-download.
- **Storage**
  - Disk usage for `~/.tom/data`, meeting count, *Open Data Folder*.
  - *Reveal diagnostic log in Finder* — opens `~/Library/Logs/TOM/tom.log`.
- **About**
  - App name and version.

---

## Diagnostics

TOM writes a plain-text diagnostic log to `~/Library/Logs/TOM/tom.log` on every launch. The file is truncated on each launch — one session per file — and the first line is a banner:

```
==== TOM session started 2026-07-02 19:01:54.514 version 1.18.0 ====
```

Subsequent lines tag every major lifecycle event: queue draining, model load/unload, transcription start/stop, routing decisions ("Routing: LOCAL (Qwen 3 4B)"), and any errors. If you need to share a session with support, *Settings → About → Reveal diagnostic log in Finder* opens it directly.

---

## Updates

TOM ships fixes and new features through a fully automatic update channel. You don't redownload anything from the website — once you're on TOM, you stay on the latest version.

### How TOM checks for updates

When TOM launches, it starts a background timer that ticks every 24 hours. On each tick — and once on launch if more than 24 hours have passed since the last check — TOM fetches a small XML file (an "appcast") from `meettom.ai` listing the current version. The feed is a few hundred bytes; TOM never downloads anything more unless a newer version actually exists.

### The three update modes

**1. Automatic (default).** Both *Automatically check for updates* and *Automatically download updates* are on. When TOM finds a newer version it downloads the update archive silently to a private cache, verifies two cryptographic signatures, and atomically swaps the new bundle into `/Applications/TOM.app` the next time you quit. No prompt, no interruption.

**2. Prompt-then-install.** Turn off *Automatically download updates* but leave *Automatically check for updates* on, and TOM still finds new versions in the background but stops there. You see a dialog with release notes and *Install Update / Remind Me Later / Skip This Version* buttons.

**3. Manual.** Turn off automatic checks entirely. TOM only reaches the update server when you click *Check Now* in Settings → General → Software Updates, the menu-bar dropdown, or the TOM menu.

### The trust chain

Two independent signatures must pass before any replacement:

1. **Ed25519 signature.** Each release is signed with a private key held on the release operator's hardware and in a hardware-backed CI secret. TOM stores the matching 32-byte public key in `Info.plist` under `SUPublicEDKey`.
2. **Apple notarization.** The signed `TOM.app` (zipped) is submitted to Apple's notary service; Gatekeeper checks the stapled ticket on every launch.

Versions are strictly monotonic — TOM refuses downgrades. If a malicious actor served an older version through the update channel, your installed copy ignores it.

### Under the hood

TOM uses [Sparkle 2](https://sparkle-project.org) — the de-facto auto-update framework for macOS apps outside the Mac App Store, used by 1Password, Bear, Things, and Tower. The appcast lives at `https://meettom.ai/updates/appcast.xml`, and each release is a zipped, notarized `TOM.app`. Downloaded updates live in `~/Library/Caches/ai.meettom/Sparkle/`. The actual install is performed by Sparkle's `Autoupdate` XPC helper using an atomic `rename(2)` so a power loss mid-update can never leave a half-installed bundle.

If your meeting library is your single most important asset, the relevant guarantee is that Sparkle's caches are entirely separate from TOM's data paths — an auto-update can't delete or corrupt your recordings, transcripts, embeddings, or licence.

---

## How It Compares

| Tool | Bot-free | Video kept | Default data location | Cross-meeting Q&A | Works offline |
|---|---|---|---|---|---|
| **TOM Desktop** | **Yes** | **Yes (full MP4)** | **100% local** | **Yes (local RAG)** | **Yes** |
| Granola | Yes | No | Granola cloud | Cloud (capped) | No |
| Otter.ai | No | Via bot | Otter cloud | Cloud | No |
| Fireflies | No | Business+ | Fireflies cloud | Cloud | No |
| Fathom | No | No | Fathom cloud | No | No |
| Zoom AI Companion | Native | Yes | Zoom cloud | No | No |

**TOM's unique combination:** local recordings + retained video + on-device transcription, summarisation, and search + cross-meeting semantic search with cited answers — all running entirely on your Mac.

---

## Licence

- **Free and open source.** TOM is released under the [Apache License 2.0](LICENSE) — no tiers, no meeting caps, no feature gates, no licence keys. Every feature is unlocked.
- **No ongoing AI fees, ever** — all inference runs on your hardware. TOM never charges a markup or routes anything through third-party infrastructure.
- Direct `.zip` download containing the signed, notarized `TOM.app` — not the Mac App Store — or build it yourself from source.

---

## System Requirements

- **macOS 14.6 (Sonoma)+** on Apple Silicon (M1 or later)
- **~6 GB free disk space** for the model cache (first launch only)
- **~50 MB app** + storage scales with your meeting library (typical: ~50 MB per hour of recording)

---

## Tech Stack

Native, signed, hardened-runtime macOS app built with Swift, SwiftUI, and Apple's ScreenCaptureKit / AVFoundation / Accelerate frameworks. Fully on-device AI via WhisperKit (CoreML) and MLX (MLXLLM + MLXEmbedders). Auto-updates via [Sparkle 2](https://sparkle-project.org) with Ed25519 signing. No Electron, no web wrapper, no telemetry.

---

## FAQ

**Will TOM run on my Intel Mac or older macOS?**
No. TOM requires an Apple Silicon Mac (M1 or later) on macOS 14.6 (Sonoma) or later. The on-device AI stack (WhisperKit, MLX) targets Apple Silicon's Neural Engine and unified memory; running Whisper turbo + Qwen 3 4B + multilingual-e5 on Intel would be slow to the point of unusable.

**The first launch downloads ~4 GB of models. Why so much, and where does it live?**
Whisper large-v3-turbo (~1.5 GB), Qwen 3 4B Instruct (~2.4 GB), and multilingual-e5-small (~120 MB). Together they do on your Mac what cloud meeting apps do on someone else's GPUs. Whisper and the embedder cache under `~/Documents/huggingface/`; the LLM caches to `~/Library/Caches/models/`. You can re-download or wipe them from Settings → AI Models at any time.

**How does TOM's summary quality compare to Granola or Otter?**
On short, single-speaker recordings: comparable. On long, multi-stakeholder meetings: Granola and Otter have an edge because they run frontier-class cloud models on someone else's servers. TOM runs a 4B-parameter model entirely on your Mac. That's the trade: TOM keeps every word on your machine, which is the whole point if your meetings are confidential enough that cloud tools aren't an option — and its summaries are still good.

**Does TOM transcribe live during the meeting?**
Not yet. Transcription runs after the recording ends. Live transcription is on the roadmap.

**Does TOM identify speakers by name?**
Not yet. TOM groups word-level segments into speaker turns by silence gaps, and labels them as "Me" (your microphone) and "Speaker" (the other party's audio). On-device speaker diarization is on the roadmap.

**Can I edit how TOM writes summaries and titles?**
Yes. Settings → General → Advanced exposes the summary and title prompts as plain markdown. Customise the structure, add a section, change tone, or write the prompts in another language. Placeholders `{{kindNoun}}` (meeting / voice note / recording) and `{{language}}` (detected language or fallback) are substituted at render time.

**What happens if I record a long meeting?**
Transcripts past ~48K characters (~50 minutes) automatically use a map-reduce flow: TOM chunks the transcript on speaker-turn boundaries, extracts action items and decisions from each chunk in sequence (with rolling context from prior chunks), then runs a final reduce pass to produce a single coherent summary. You'll see this reflected in `~/Library/Logs/TOM/tom.log` as `Map-reduce summarisation: N chunks (X chars)`.

**How does TOM stay up to date?**
TOM checks for a new version once a day, downloads it silently, and installs it the next time you quit. Updates are cryptographically signed and Apple-notarized — TOM verifies both before replacing the app. If you prefer to review each update first, turn off *Automatically download updates* in Settings → Software Updates.

---

## Coming Soon

- Live transcription during recording
- Speaker diarization on-device
- TOM for Teams (shared and private in-meeting bots for participants who can't install desktop apps)

---

*Built by [automatics](https://automatics.dev) — we ship custom workflow automation for professionals. TOM is what we built for ourselves.*
