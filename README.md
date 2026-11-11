<p align="center">
  <img src="docs/images/tapchat-icon.png" width="96" height="96" alt="TapChat icon">
</p>

<h1 align="center">TapChat</h1>
<p align="center">A quick chat window for Claude and Codex, one shortcut away.</p>
<p align="center">
  <a href="https://github.com/NidaleNieve/TapChat_MacOS/releases/latest/download/TapChat-0.3.1-arm64.dmg"><strong>Download for Mac</strong></a>
  · <a href="https://github.com/NidaleNieve/TapChat_MacOS/issues">Report an issue</a>
</p>
<p align="center">Apple Silicon · macOS 26 or later · Signed &amp; notarized</p>

<p align="center">
  <img src="docs/images/chat.png" width="433" height="760" alt="TapChat with a short chat">
</p>

TapChat opens a small chat window over whatever you're doing with **⌥ Space**, and hides again just as fast. It runs on the Claude Code and Codex command-line tools, so it uses your existing Claude or ChatGPT subscription. No API keys.

Vibecoded with Claude Code, but very polished.

## Get started

1. Download the **DMG**, open it, and drag **TapChat** into **Applications**.
2. Open TapChat. Its setup window installs Claude or Codex and signs you in.
3. Press **⌥ Space**.

## Features

- **Models and reasoning:** Claude and Codex models, with reasoning from Instant to High. Web search is always on.
- **Usage limits:** A quiet note when the 5-hour or weekly limit is close; TapChat switches provider when one runs out.
- **Side chats:** Select text and ask about it in a second window, without leaving the chat.
- **Replies and highlights:** Select text to reply to that part, or highlight it for later.
- **Edits and forks:** Edit any message and flip between versions, or fork a chat from any point.
- **Attachments:** Drop, paste or pick files, folders and images, or take a photo with your iPhone.
- **Temporary chats:** Never saved to History.
- **History:** Search every chat; titles follow what the chat is about.
- **Automatic updates.**

## Private

There are no accounts, no analytics and no telemetry. Chats stay on your Mac. Messages go only to the provider you choose, through its own command-line tool. TapChat itself only connects to check for updates and, during setup, to download the tools.

## For developers

Native Swift, SwiftUI and AppKit, built with Swift Package Manager. Requires Apple Silicon, macOS 26 and Xcode:

```sh
./build.sh --open
```

Released under the [MIT license](LICENSE).
