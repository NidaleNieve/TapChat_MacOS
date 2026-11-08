# TapChat performance work — results and how to check them

8 November 2026 · branch `main`, commits `11b5a71..44db17c` · baseline `bca225d` (measured as `83c1b02`, which only adds the benchmark code)

> **Update (`d25cc2d`):** the message-list rewrite from `d6c4a17` was reverted, because it kept the first
> answer of a new chat from drawing until it was finished. The list is the original one again, plus the
> chevron fix and a top margin. All other changes stay. The table below was measured before that revert,
> so the fast-scroll, open-from-History and long-chat memory figures are likely somewhat lower now. It has
> not been re-measured. Re-measure with `scripts/compare.sh HEAD after 2`.

## Results

Measured in the real window, with the same benchmark code built into both versions
(`scripts/compare.sh` copies this checkout's `Bench.swift` and `DebugHooks.swift` over the old revision).
Medians of 2 runs each, Apple M5 Pro, macOS 27.2. Baseline `83c1b02`, optimised `2d6cfb3`.

| Figure | Before | After | Change |
|---|---:|---:|---:|
| Stream a 12k-char answer: TapChat CPU | 11.1 CPU s | 6.6 CPU s | **1.7× less** |
| Same, at the end of a 300-message chat: CPU | 11.2 CPU s | 6.5 CPU s | **1.7× less** |
| Same: peak memory | 220 MB | 158 MB | **1.4× less** |
| Open a 300-message chat from History, first time | 79 ms | 51 ms | **1.5× faster** |
| Open it again, median | 66 ms | 38 ms | **1.8× faster** |
| Fast scroll (600 pt per frame), average frame | 16.3 ms | 8.2 ms | **2.0× faster** |
| Fast scroll, p95 frame | 23.5 ms | 15.0 ms | **1.6× faster** |
| Fast scroll, worst frame | 35 ms | 59 ms | 1.7× slower (one frame; see below) |
| Memory with a 300-message chat open | 200 MB | 84 MB | **2.4× less** |
| Add 8 screenshots (2400×1500) | 286 ms | 79 ms | **3.6× faster** |
| Remove one attachment | 8.0 ms | 0.5 ms | **15× faster** |
| Memory still held after removing them | 63 MB | 15 MB | **4.2× less** |
| Window open, idle: CPU | 1.9 % | 0.1 % | **~20× less** |
| Window open, idle: TapChat + CLI memory | 139 MB | 131 MB | 1.1× less |
| Hidden after use: memory | 130 MB | 83 MB | **1.6× less** |

Not in the table, because the benchmark calls `open` directly instead of clicking:

- **Clicking a chat in History.** Every click used to wait out the double-click interval, because a double-click rename gesture sat on each row. Now the chat opens on the first click.
- **Clicking an attachment's ✕.** It had the same wait, from double-click-to-open. That gesture now covers only the picture.

These waits were the "takes a second" you felt (about 0.3–0.5 s each, the system double-click interval), and they're now gone.

### Against the targets (2× faster, 3× fewer resources)

- **Met:**
  - Fast scrolling: 2.0×.
  - Attachments: 3.6× and 15× faster, 4.2× less memory held.
  - Idle CPU with the window open: about 20× less.
- **Close:**
  - Opening from History: 1.8×, plus the click wait removed.
  - Streaming CPU: 1.7×.
  - Memory with a long chat: 2.4×.
- **Not met:**
  - Idle memory with the window open (1.1×). 110 MB of the 131 MB is the Claude CLI started in advance so the first answer comes quickly. I tried starting it only once you type, which brought idle memory to 22 MB (6×), but it made the first message noticeably slower, so I reverted it. It now stops after 3 minutes open with nothing written, and when the window hides.
  - Streaming wall time stays ~13.5 s: that's the simulated 1,000 chars/s answer itself, not TapChat.

### Caveats

- **The worst scroll frame (59 ms) is a single frame out of ~290.** It is most likely when a not-yet-parsed answer first scrolls into view: answers are pre-parsed in the background, newest 200 first, and the fling reaches the top of the chat within 0.3 s. Average and p95 both improved.
- **"Hidden, a minute after use: 1.9 % CPU".** The minute-later reading includes the moment 60 s after hiding when caches are released, which is a one-off.
- **The machine was in normal use during the runs** (browser, Claude app). Runs agree within about 10 % except where noted.
- **Not measured by the harness:**
  - Real CLI latency.
  - The reveal timer sleeping while waiting for the model or while hidden, the typing dots pausing while hidden, the History search cache, and the recently opened chats cache (all in `408c489`, after the measured commit).
  - The content-based titles (`2d6cfb3`).

## What changed, commit by commit

| Commit | What | Why it's faster / lighter |
|---|---|---|
| `11b5a71`, `83c1b02`, `61c4133` | Benchmark harness | Measures the real window; build output moved out of iCloud (a synced 200 MB `.build` had stalled iCloud Drive and the compiler) |
| `d6c4a17` | Long chats and streaming | See the first list below |
| `92d5319` | Attachments | See the second list below |
| `8814667` | Spare CLI only while writing (later adjusted in `2d7260a`); caches released 60 s after hiding | Memory when idle or hidden |
| `588426c` | Runners | Prompt building was quadratic (copied the whole prompt on each append); log writes off the main thread |
| `2d7260a` | Feedback fixes | See the third list below |
| `44d03ac` | Review fixes | No GPS data in copied photos; icons per file when there's no extension; pre-parsing capped at 200 answers |
| `408c489` | From the Codex branch's review | Reveal timer sleeps when there's nothing to show; typing dots pause while hidden; History search caches folded text; last 4 chats stay decoded |
| `2d6cfb3` | New feature | Chat titles written by Haiku from the first exchange |

**`d6c4a17`, long chats and streaming:**
- Markdown is parsed once per message and cached. While streaming, only the text after the last finished block is parsed again.
- Each block is its own view, compared by identity, so finished blocks aren't evaluated, laid out or redrawn.
- The 300-row list no longer re-evaluates every frame: scroll state lives in an object only the bottom spacer and the follow-scroll read.
- Row buttons are built only on hover.
- A chat opens at its end.
- Answers are pre-parsed in the background.
- The reveal cursor no longer counts the whole answer each frame.
- Includes the fix for the jump-to-bottom chevron not following the answer.

**`92d5319`, attachments:**
- Chips decoded every full-size image from disk on every redraw; they now use 108 px cached thumbnails.
- Images are imported with ImageIO, which decodes at the target size, in parallel, with a faster PNG filter.

**`2d7260a`, feedback fixes:**
- The CLI starts when the window opens again.
- History opens on the first click.
- ✕ on attachments is instant.
- The first message is no longer in the top fade.
- A chat whose last exchange is short opens at its real end.

## Comparison with Codex's branch (`codex/tapchat-performance-optimized`)

Read in full, together with its review packet in `~/Documents/Codex/2026-11-08/please-make-performance-for-longer-chats`. Not merged.

- **It starts from an older snapshot (`18f1e97`).** That's before UI rounds 8–9, so merging would undo or conflict with that work, in `ChatModel`, `Views`, `Panel` and `Haptics`.
- **It's a much larger change.** 46 files and ~2,800 lines, including an asynchronous storage layer, a split of `Views.swift`, and a separate "TapChat Performance" app.
- **Its headline figures come from a synthetic, non-UI workload.** Examples: "prompt assembly 847×", "warm retrieval 53,760×". These are real but mostly measure in-memory lookups. Its own UI measurements show reopening the same chat 5×, switching to a different chat 1.26×, and fast-scroll p95 14.6 → 9.3 ms.
- **Its approach is weaker on streaming.** It caches Markdown by the full text and skips the cache while streaming, so a streaming answer is fully re-parsed every frame. This branch parses only the new tail and redraws only the last block.
- **It didn't find the click-wait problems** in History and attachment chips, because its benchmarks also call `open` directly.

**Taken from it:**
- Linear prompt assembly.
- A cursor-based reveal.
- Background logging.
- The reveal timer sleeping when caught up or hidden.
- Pausing the dots while hidden.
- Caching folded search text.
- Keeping recent chats decoded.

All are credited in the commit messages.

**Not taken:**
- **The async storage rewrite.** At TapChat's chat sizes, reading and decoding a 300-message chat takes a few milliseconds, and the rewrite adds ordering and race risks that its own review had to fix.
- **Keeping the transcript mounted under History.**
- **The separate app identity.**

## Code review

The available `code-review` skill was run on `83c1b02..HEAD` (the "thermal nuclear review" and "improve architecture" skills you named aren't installed; `code-review` and `simplify` are the closest).

Eight findings:

**Fixed (6):**
- A failing spare CLI was restarted on every keystroke.
- A chat whose last exchange is short opened above its end.
- Small JPEGs kept GPS data.
- Starting the CLI only on typing slowed the first message.
- Pre-parsing could evict on-screen answers in chats with over 600 answers.
- File icons were cached per extension, so extensionless files shared an icon.

**Left (2):**
- Follow mode infers "you scrolled up" from the offset decreasing, rather than from scroll phases. It works, but it is a heuristic.
- Log lines queued just before quitting can be lost.

`simplify` was not run. It applies its own changes, and you made the speed-ups conditional on usability being unchanged, so I'd run it only on your go-ahead.

## How to check

```bash
# Rebuild a revision and benchmark it (the window opens repeatedly; don't use TapChat meanwhile).
scripts/compare.sh 83c1b02 before 2
scripts/compare.sh HEAD after 2
scripts/summarize.py before after      # the table above
./build.sh                              # reinstall the current app
```

- **Raw data:** `bench/before-*.json` and `bench/after-*.json`.
- **Per-commit review:** `git show <commit>`; every commit builds on its own.
- **By hand:**
  - Open a long chat from History: one click, opens at its end.
  - Remove an attachment with ✕: immediate.
  - Send a first message in a new chat: dots, then streamed text, then a short title after a few seconds.
  - While an answer is written, scroll up, then tap the chevron: it keeps following.
