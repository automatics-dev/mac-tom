# TOM Desktop for Mac

**Everything you record, searchable. Every recording makes TOM smarter.**

Records meetings, voice notes, and screen feedback for advisors, lawyers, therapists, and founders who can't put client audio in someone else's cloud. Native macOS app with a menu bar shortcut. Fully on-device AI — your recordings, your transcripts, your summaries, your search, all on your Mac. Nothing is ever uploaded. Free and open source under the Apache License 2.0 — no account, no licence keys, no recording caps.

*Requires an Apple Silicon Mac running macOS 14.6 (Sonoma) or later.*

*Current version: v1.25.0*

---

## What TOM Does

TOM lives in your Dock and menu bar. Press ⌘⇧R (or click Start Recording) to open the record panel, pick Meeting, Voice note, or Feedback, choose a window or screen, and hit record. TOM captures the meeting silently — no bot joining your call, no participants notified, nothing uploaded anywhere. TOM transcribes while you record, word by word. When you stop, it writes a structured summary (TL;DR, action items, decisions, discussion topics, and open questions) and indexes every word for search across all your recordings — all on your Mac.

Meetings are one of three modes. Voice notes record just your mic. Feedback sessions record a window or your screen while you talk through what should change: press ⌥A to draw on the screen and ⌥M to mark a moment, and TOM pairs each mark with what you said in a Review tab. One click copies the annotated screenshots, the notes, and the full transcript, ready to paste into Claude or ChatGPT.

The longer you use TOM, the smarter it gets. After 60 recordings, you can ask *"what did we agree on pricing with Acme?"* and get a cited answer across 8 conversations with video timestamps. After 120 recordings, you have institutional memory — every decision, every promise, searchable by meaning.

> **Questions you can ask TOM:**
>
> - *"What did we promise Acme on the security-review timeline?"*
> - *"Which objections did EU customers raise about pricing in Q1?"*
> - *"Did we ever decide who owns the onboarding rewrite?"*
>
> TOM searches across every recording and returns a cited answer with the recording title, date, and a video timestamp you can click into.

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
| **Video + audio** | Full HEVC/AAC MP4 retained locally. Re-watch screen shares, demos, presentations — not just text. |
| **Dual-stream capture** | System audio (the other side) and your microphone recorded in parallel, then mixed into one stream for transcription and playback. A voice that reaches both (speakers, sidetone) is transcribed once, not twice. |
| **Live transcript** | Parakeet TDT v3 (via FluidAudio) transcribes word by word while you record, about a second behind the speaker, so the transcript is ready when you stop. Whisper large-v3-turbo (WhisperKit) is the alternative engine, and an optional Whisper pass can refine the live transcript after each recording. Audio never leaves your Mac. |
| **Structured summaries** | Every recording gets a TL;DR, action items, decisions, discussion topics, and open questions. Generated entirely on-device by Qwen 3 4B Instruct (4-bit MLX). |
| **Map-reduce for long meetings** | Transcripts past ~48K characters (~50 minutes) are chunked, extracted in parallel passes, then reduced to a single coherent summary so 2-hour meetings don't blow the context window. |
| **Editable AI prompts** | Tune the summary and title prompts in Settings → General → Advanced if you want a different style, length, or set of sections. Prompts use `{{kindNoun}}` and `{{language}}` placeholders. |
| **Search across recordings** | Ask questions in natural language. TOM embeds your query locally, shows the matching recordings straight away, then streams an answer with inline `[1]` citations to the source recordings (title + date) and video timestamps. |
| **Multilingual** | Embeddings via `multilingual-e5-small` cover 100+ languages. Whisper detects the spoken language and TOM passes it as a hint to the summary/title prompt, so non-English recordings get non-English writeups. |
| **Karaoke video playback** | Watch the recording back with subtitles that highlight the word actually being spoken, using per-word timings from the transcriber. |
| **Voice notes** | Mic-only recordings for solo capture — same pipeline, same library. |
| **Feedback sessions** | Record a window or the whole screen while you narrate. Draw on the screen (⌥A) or mark a moment (⌥M); each annotation gets a screenshot and the words you said around it. Send to Claude or ChatGPT copies the notes, transcript, and annotated screenshots to the clipboard and opens a new chat. Export ▸ Spec Folder writes `review.md`, `screens/`, and `annotations.json` for a coding agent. |
| **Export** | Markdown, MP4 video, or M4A audio for any recording. Video and audio exports always include both mic and system audio. |
| **Rename** | Double-click a title or use Rename… on the card. Custom titles survive re-summarising and re-transcribing; clear one to hand it back to the AI. |
| **File import** | Drop in any `.mp4`, `.m4a`, `.mp3`, `.wav`, `.mov` and TOM transcribes and indexes it. |
| **Groups** | Apple Notes–style folders. Drag recordings between groups. |
| **Auto meeting detection** | Spots Zoom, Google Meet, Teams, Webex and Slack Huddle windows and offers a one-click record prompt. |
| **Serialised processing queue** | Multiple recordings, retranscribes, or imports queue up FIFO instead of fighting over the GPU. You see a "Queued" badge on recordings waiting their turn. |
| **Idle model unload** | Whisper and Qwen are dropped from RAM between pipeline stages and after the Ask box has been idle, so TOM doesn't sit on ~4 GB of weights when you're not using it. |
| **Light & dark mode** | Follows the system appearance by default; the toolbar button cycles System / Light / Dark. Orange accent. |
| **Five languages** | Interface in English, German, Spanish, French, and Italian. |

---

## Privacy

TOM does all AI processing on your Mac. There is no automatics server, no account, no telemetry, no analytics, no sync. Recordings, transcripts, embeddings, summaries, and model weights all stay on your Mac — nothing is ever uploaded.

Network activity is limited to: the one-time AI model download from Hugging Face on first launch, and a once-a-day check for app updates. Neither touches your meeting data.

---

## On-Device Model Stack

| Stage | Model | Size | License | Backend |
|---|---|---|---|---|
| Live transcription (default) | NVIDIA Parakeet TDT 0.6B v3 | ~500 MB | CC-BY-4.0 | FluidAudio (CoreML) |
| Transcription / refinement | Whisper large-v3-turbo | ~1.5 GB | MIT | WhisperKit (CoreML) |
| Summaries / Title / RAG synthesis | Qwen 3 4B Instruct 2507 (4-bit) | ~2.4 GB | Apache 2.0 | MLXLLM |
| Embeddings | intfloat/multilingual-e5-small | ~120 MB | MIT | MLXEmbedders |

Every stage runs locally on Apple Silicon — your meetings never leave your Mac. First launch downloads ~4 GB (Whisper, Qwen, and the embedder) from Hugging Face. Parakeet is an extra ~500 MB, downloaded from Settings → AI Models; once it's ready, TOM uses it for live transcription and falls back to Whisper otherwise. Recommended free space: 6 GB. Whisper and the embedder cache under `~/Documents/huggingface/`, the LLM under `~/Library/Caches/models/`, and Parakeet in FluidAudio's folder under `~/Library/Application Support/`. You can re-download or wipe them from Settings → AI Models.

---

## How It Works

1. **Record.** Press ⌘⇧R or click Start Recording, pick a mode and a window or screen. ScreenCaptureKit captures HEVC video at native resolution, 30 fps, with system audio and your mic in parallel. Window recordings stay locked to that window even if you switch apps.
2. **Transcribe live.** Mic and system audio are mixed into one stream and fed to Parakeet (or Whisper) in short chunks while you record. Every half second TOM re-decodes the newest audio, so words show up about a second after they're spoken. Silent stretches are skipped and common no-speech hallucinations ("Thank you.", "Vielen Dank", subtitle credits) are filtered out.
3. **Queue.** When you stop, the recording enters a serial processing queue. Work already in flight finishes before yours starts, so overlapping stops and imports don't fight over the GPU.
4. **Refine (optional).** If *Refine with Whisper after each recording* is on, Whisper large-v3-turbo re-transcribes the whole file and replaces the live transcript. Whisper also detects the spoken language.
5. **Drop the voice model.** The transcriber is unloaded from RAM before the summariser runs, so the two heavyweights never coexist.
6. **Summarise.** With language as a hint, TOM generates a title and structured summary (TL;DR, action items, decisions, discussion topics, open questions) locally on Qwen 3 4B. Short transcripts go in one pass; long transcripts use map-reduce: chunked extraction with rolling context, then a final reduce pass.
7. **Index.** Transcript chunked into ~500-token segments, embedded via `multilingual-e5-small` (384-dim, 100+ languages), stored as float32 vectors in SQLite.
8. **Search.** Ask a question. TOM embeds your query, brute-force scans every vector with Apple's Accelerate framework (vDSP SIMD), shows the sources, and streams Qwen's cited answer into the view.
9. **Unload.** After ~5 minutes of inactivity in the Ask box, the summariser model is dropped from RAM.

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
  - Show menu bar icon (the Dock icon always stays).
  - Notify when a meeting starts.
  - Transcribe live while recording. Keeps the transcription model in memory (~2 GB); turn it off on Macs with less than 16 GB if recordings stutter.
  - Software Updates: automatic checks, automatic downloads, manual *Check Now*.
  - **Advanced** (collapsible): edit the summary prompt and the title prompt as plain markdown, reset to default at any time. Templates support `{{kindNoun}}` and `{{language}}` placeholders. Also holds the Chrome / Arc black-video workaround.
- **AI Models** (three cards, top to bottom, plus *Download all*)
  - **Voice AI**: engine picker (Parakeet or Whisper), a Download / Re-download card for each, and the *Refine with Whisper after each recording* toggle.
  - **Think AI**: Qwen 3 4B. Download status + Re-download.
  - **Search AI**: multilingual-e5-small. Download / Re-download.
- **Storage**
  - Disk usage for `~/.tom/data`, recording count, *Open Data Folder*.
  - Diagnostic log: *Reveal in Finder* opens `~/Library/Logs/TOM/tom.log`.
- **About**
  - App name and version.

---

## Diagnostics

TOM writes a plain-text diagnostic log to `~/Library/Logs/TOM/tom.log` on every launch. The file is truncated on each launch — one session per file — and the first line is a banner:

```
==== TOM session started 2026-07-02 19:01:54.514 version 1.25.0 ====
```

Subsequent lines tag every major lifecycle event: queue draining, model load/unload, transcription start/stop, routing decisions ("Routing: LOCAL (Qwen 3 4B)"), and any errors. If you need to share a session with support, *Settings → Storage → Diagnostic log → Reveal in Finder* opens it directly.

---

## Updates

TOM ships fixes and new features through a fully automatic update channel. You don't redownload anything from the website — once you're on TOM, you stay on the latest version.

### How TOM checks for updates

When TOM launches, it starts a background timer that ticks every 24 hours. On each tick — and once on launch if more than 24 hours have passed since the last check — TOM fetches a small XML file (an "appcast") from `meettom.ai` listing the current version. Each request carries a unique query parameter so neither a CDN nor the local URL cache can serve a stale copy. The feed is a few hundred bytes; TOM never downloads anything more unless a newer version actually exists.

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

If your meeting library is your single most important asset, the relevant guarantee is that Sparkle's caches are entirely separate from TOM's data paths — an auto-update can't delete or corrupt your recordings, transcripts, or embeddings.

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

**TOM's unique combination:** local recordings + retained video + live on-device transcription, summarisation, and search + cross-meeting semantic search with cited answers — all running entirely on your Mac.

---

## Licence

- **Free and open source.** TOM is released under the [Apache License 2.0](LICENSE) — no tiers, no meeting caps, no feature gates, no licence keys. Every feature is unlocked.
- **No ongoing AI fees, ever** — all inference runs on your hardware. TOM never charges a markup or routes anything through third-party infrastructure.
- Direct `.zip` download containing the signed, notarized `TOM.app` — not the Mac App Store — or build it yourself from source.

---

## System Requirements

- **macOS 14.6 (Sonoma)+** on Apple Silicon (M1 or later)
- **~6 GB free disk space** for the model cache (first launch only)
- **~50 MB app** + storage scales with your recording library

---

## Tech Stack

Native, signed, hardened-runtime macOS app built with Swift, SwiftUI, and Apple's ScreenCaptureKit / AVFoundation / Accelerate frameworks. Fully on-device AI via FluidAudio and WhisperKit (CoreML) and MLX (MLXLLM + MLXEmbedders). Unit tests run on Swift Testing in GitHub Actions. Auto-updates via [Sparkle 2](https://sparkle-project.org) with Ed25519 signing. No Electron, no web wrapper, no telemetry.

---

## FAQ

**Will TOM run on my Intel Mac or older macOS?**
No. TOM requires an Apple Silicon Mac (M1 or later) on macOS 14.6 (Sonoma) or later. The on-device AI stack (WhisperKit, MLX) targets Apple Silicon's Neural Engine and unified memory; running Parakeet, Whisper turbo, Qwen 3 4B, and multilingual-e5 on Intel would be slow to the point of unusable.

**The first launch downloads ~4 GB of models. Why so much, and where does it live?**
Whisper large-v3-turbo (~1.5 GB), Qwen 3 4B Instruct (~2.4 GB), and multilingual-e5-small (~120 MB), plus Parakeet (~500 MB) if you pick it for live transcription. Together they do on your Mac what cloud meeting apps do on someone else's GPUs. Whisper and the embedder cache under `~/Documents/huggingface/`, the LLM under `~/Library/Caches/models/`, Parakeet under `~/Library/Application Support/`. You can re-download or wipe them from Settings → AI Models at any time.

**How does TOM's summary quality compare to Granola or Otter?**
On short, single-speaker recordings: comparable. On long, multi-stakeholder meetings: Granola and Otter have an edge because they run frontier-class cloud models on someone else's servers. TOM runs a 4B-parameter model entirely on your Mac. That's the trade: TOM keeps every word on your machine, which is the whole point if your meetings are confidential enough that cloud tools aren't an option — and its summaries are still good.

**Does TOM transcribe live during the meeting?**
Yes. With *Transcribe live while recording* on (the default on Macs with 16 GB or more), the transcript fills in word by word on the Transcript tab and is ready when you stop. Parakeet handles 25 languages in real time; switch to Whisper in Settings → AI Models if you prefer accuracy over speed, or keep Parakeet live and turn on *Refine with Whisper* for both.

**Does TOM identify speakers by name?**
Not yet. TOM mixes your mic and the system audio into one stream before transcribing, so the same voice is never written down twice, and groups words into turns by silence gaps. Feedback sessions read as running text. On-device speaker diarization is on the roadmap.

**Can I edit how TOM writes summaries and titles?**
Yes. Settings → General → Advanced exposes the summary and title prompts as plain markdown. Customise the structure, add a section, change tone, or write the prompts in another language. Placeholders `{{kindNoun}}` (meeting / voice note / recording) and `{{language}}` (detected language or fallback) are substituted at render time.

**What happens if I record a long meeting?**
Transcripts past ~48K characters (~50 minutes) automatically use a map-reduce flow: TOM chunks the transcript on speaker-turn boundaries, extracts action items and decisions from each chunk in sequence (with rolling context from prior chunks), then runs a final reduce pass to produce a single coherent summary. You'll see this reflected in `~/Library/Logs/TOM/tom.log` as `Map-reduce summarisation: N chunks (X chars)`.

**How does TOM stay up to date?**
TOM checks for a new version once a day, downloads it silently, and installs it the next time you quit. Updates are cryptographically signed and Apple-notarized — TOM verifies both before replacing the app. If you prefer to review each update first, turn off *Automatically download updates* in Settings → Software Updates.

---

## Coming Soon

- Speaker diarization on-device
- TOM for Teams (shared and private in-meeting bots for participants who can't install desktop apps)

---

*Built by [automatics](https://automatics.dev) — we ship custom workflow automation for professionals. TOM is what we built for ourselves.*
