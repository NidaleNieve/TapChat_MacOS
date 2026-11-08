# QuickChat — round 4 feedback

## Window & bar
1. **Squished bar** — the bar's content is pushed down and clipped at the bottom. Cause: the hidden title bar's safe area (~28 pt) still pushes the SwiftUI content down. Fix: ignore the safe area.
2. **Default position** — bottom third and right third of the screen. Reset the saved position once so the new default takes effect.
3. **Shortcut toggles** — if the window is visible, even when it isn't focused, the shortcut hides it.
4. **Same width everywhere** — the bar and the chat window share one width (380–800), so starting a new chat doesn't change the width.
5. **Resize from the top** — a top-edge handle changes the height, with the bottom edge staying put (chat and History).
6. **A little more opaque** — a tinted layer under the glass.
7. **Smoother growth** — the bar's height animates as long text wraps onto new lines.

## Composer & editing
8. **Separate reply box** — inside a chat, the composer becomes a ChatGPT-style card: text on top, controls below (+, web, model, incognito, history, send/stop).
9. **Edit box looks like the composer** — same card, with its own model picker.
10. **Smaller font** in the bar and in the edit box (16 → 14).
11. **Visible incognito button** — redrawn as plain shapes (the Canvas version didn't render) and moved to the right of the model picker.
12. **Drafts never lost** — each chat keeps its unsent text, attachments and half-finished edit, across switching chats, new chats and quitting. The "new chat" draft has a stable home too.

## Chat
13. **Smooth streaming** — text appears at an even, animated pace instead of jumping, with a light trackpad haptic tick while it writes (can be turned off in Settings).
14. **Scroll freely while generating** — stop following the bottom once you scroll up; resume when you're back at the bottom or send something.
15. **Close button on the left** of the header.
16. **Back button in History** when it was opened from a chat.

## App
17. **Option to hide the menu bar icon.**
18. **Recordable History shortcut** (global), next to the Open shortcut.

## Status (2026-11-08)
All 18 items are implemented and installed in /Applications/QuickChat.app.
Checked via the debug hook: drafts kept across chat switches and a restart; default position; shared width; shortcut hides when visible; History shortcut; search focus; streaming completes.
Needs a look by hand (no screen capture available here): the bar no longer squished, glass opacity, reply/edit card style, incognito icon, smooth text and haptics, scrolling up during an answer, dragging the top edge.

# Round 5 feedback

## Window
1. **Default position** a little further left, not touching the screen edge.
2. **Default width** a quarter of the screen's width.
3. **Black outline off the edge** (image 4): the system's titled-window border doesn't match our rounded glass. Make the window borderless (macOS then shapes the shadow to the glass) and add our own edge handles for resizing.
4. **Bigger drop target, clearly shown**: while a file is being dragged anywhere, the bar grows into a visible "Drop files here" area; the whole window accepts the drop.

## Bar, reply box and edit box: one design
5. **One layout everywhere**: [+] text … [model] [incognito] [history], buttons always in the same places. The initial bar, the bar under History, the reply box and the edit box (which swaps History for Cancel/Send) all use it.
6. **Long text**: once it no longer fits on one line, the box switches to text on top with the same control row below (as the reply box does), so the text uses the full width.
7. **Bar too tall**: back to a slimmer bar.
8. **Text sitting low and clipped / needing to scroll** (image 2) and **wrapping at half the width** (image 1): the text view's width wasn't following the box. Fix the width, and allow scrolling only once the text is taller than the box.
9. **Incognito icon**: use an SF Symbol in the same style as the other icons.
10. **Web search always on**: drop the toggle.
11. **Model menu**: shorter (current models first, older versions in a submenu), with each provider's usage in its section header.

## Feedback
12. **Copy / fork**: the icon turns into a checkmark with a light haptic; a fork shows a short "Forked" confirmation in the header of the new chat.
13. **Haptics**: gentler, steadier ticks while writing (word by word, lighter pattern), and a distinct "done" haptic when the answer finishes.

## History
14. **Forks as sub-items** under the original chat (collapsible), named "Fork 1", "Fork 2", …
15. **Search results** show the matching passage with the match highlighted, also when the title matches.

## Shortcuts
16. **⇧⌘N toggles** temporary chat (on and off).

## Round 5 status (2026-11-08)
All 16 items are implemented and installed. Checked via the debug hook: bar height 44 pt; default width a quarter of the screen (379 pt); about 105 pt from the right edge; long text switches to text above the controls and back; search results show the matching passage.
Needs a look by hand: no outline around the window now that it's borderless; the shadow; resizing from the left, right and top edges; the drop zone while dragging files; haptics (word ticks, the double tap at the end, copy/fork taps); checkmarks; the fork tree; the sunglasses icon.

# Round 6 feedback

## Window
1. **Black outline still there** (image 3): borderless windows still get a system outline from their shadow. Turn the system shadow off and draw our own around the glass; the window gets a transparent margin for it.
2. **Can't move the window**: borderless windows lost the title-bar drag. Add a move area behind the glass (anywhere that isn't a control).
3. **Animations out of step** (text moving faster than the box in the bar; pasting or deleting lots of text): the window becomes a fixed transparent canvas, and the glass grows and shrinks inside it with SwiftUI animations, as the reply box already does. Clicks outside the glass pass through to the apps behind.
4. **Fades** where the chat content slides under the header and the reply box (also in History).

## Composer & models
5. **Padding**: more space left of the text when it's multi-line (in line with the +), a little on the right.
6. **Temporary chat icon**: a plain eye-slash in the same style as the other icons.
7. **Codex names without hyphens**: "GPT 6 Sol".
8. **Narrower model menu**: short section headers ("Claude · 15%"); main lists without Haiku or Terra, with GPT 6 Sol added; the rest under "More".

## Reasoning
9. **Separate reasoning button** next to the model picker, drawn as a small gauge (monochrome, not blue) that fills with the level; clicking it lists Instant, Low, Medium, High and Max. Removed from the model menu.
10. **No "Default", no Extra High or Ultra**; Medium on first launch, then always the last one used (kept across new chats and restarts); the button updates right away.
11. **Instant**: Claude without extended thinking; Codex at its lowest level.

## Feel
12. **Haptics** (public API only: three fixed patterns, no intensity; the private trackpad API crashes on Apple Silicon): a steady, sparse light tick synced to screen redraws while text appears, and a distinct three-step "done" roll when the answer finishes.
13. **Text fades in** as it appears: the newest characters ramp up from transparent, so the text glides in instead of popping.

## Round 6 status (2026-11-08)
All 13 items are implemented and installed. Checked via the debug hook: fixed canvas window with the glass growing 44 → 94 → full height and back; clicks pass through outside the glass; reasoning Medium on first launch; a streamed answer completes.
Needs a look by hand: outline gone and the new shadow; moving the window by dragging empty space; animation smoothness; the reasoning gauge; the text fade-in; the haptic rhythm and "done" roll; the edge fades.

# Round 7 feedback

## Drag and drop
1. **Drop area only near the window**: it appears when a dragged file comes within ~90 pt of the glass, and goes away when it moves off.
2. **Bigger drop target**: while files are dragged, the whole canvas (the area above, plus a wider margin around the sides and bottom) takes the drop, so dropping slightly outside the bar still works.
3. **Quieter in a chat**: a thin accent outline and a small "Drop to attach" label instead of the big blue panel.

## History
4. **Search field looks like a search field**: rounded background and a hairline border.
5. **Date** smaller and further right; **no scroll bar**; the same padding left and right.

## Animation
6. **Icons jumping** when the box switches between one line and several: the switch, and each change of text height, now run as one animation across the whole window.
7. **Sending / new chat**: the composer is one view that turns into the reply box and back (no second copy sliding in); a sent message slides up into the chat while the controls stay put.

## Look
8. **Border back**: a hairline that follows the glass's own shape (not the system frame that caused the offset outline).

## Models and reasoning
9. **Usage**: Codex rechecked whenever the window opens (at most once a minute) and after each answer; the model menu shows the reset time on a second line and keeps showing a provider after its window resets (as 0%).
10. **Reasoning icon**: thinner and grey, like the eye and clock icons; its menu opens upwards; Max removed (High keeps its place on the gauge).
11. **Model menu**: anchored so the menu sits left of the button; "More" submenus then open to the right for both providers.
12. **Settings** removed from the model menu; opening the app while it's running opens Settings (⌘, still works).

## Round 7 status (2026-11-08)
All 12 items are implemented and installed. Checked via the debug hook: one line ↔ several lines (44 ↔ 94 pt); send → chat; streaming completes; New Chat → bar; reasoning level kept.
Needs a look by hand: drop area appearing only near the window, and dropping just outside it; the quieter drop outline in a chat; the hairline border; the menus opening upwards with "More" on the right; the smoothness of the bar ↔ reply-card change.
