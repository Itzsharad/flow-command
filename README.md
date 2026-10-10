# Flow Command for Mac

Hold **Control + Option**, say what you want, let go — your Mac does it.

> *"Ask Claude write me 5 hooks for a coaching ad"* → Chrome opens a new window → new Claude chat → prompt pasted and sent.

Lives in your menu bar as 🎙. Speech recognition runs on your Mac — it only listens while you hold the keys.

## Install

1. Go to **Releases → latest** on this page and download **FlowCommand.dmg**.
2. Open it and drag **Flow Command** into **Applications**.
3. Open Flow Command from Applications. macOS will say it can't verify the developer — click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Allow the permissions it asks for:
   - **Microphone** — to hear you
   - **Accessibility** — to press keys and paste for you (System Settings → Privacy & Security → Accessibility → turn on Flow Command)
5. Quit it from the 🎙 menu and open it again. The first launch downloads the speech model (~150 MB, one time).

When the menu bar shows 🎙 and says *Ready*, you're set. Turn on **Start at Login** in the 🎙 menu so it's always there.

## Use it

| Say | What happens |
|---|---|
| "Ask Claude …" / "Claude …" | New Claude chat, your prompt pasted and sent |
| "Open Claude" | Empty new Claude chat |
| "Ask ChatGPT …" | Same, in ChatGPT |
| "Google …" / "Search YouTube for …" | Opens the search |
| "Open Gmail" / "New email" / "Open calendar" | Opens it |
| "Open GHL" / "Open my CRM" | Opens GoHighLevel |
| "New doc" / "New sheet" / "Open Drive" | Google Docs / Sheets / Drive |
| "Type …" | Pastes your words where your cursor is |
| "Send …" | Pastes and presses Enter |
| "New tab" / "Close tab" / "Undo" / "Copy that" / "Paste" / "Screenshot" | Does it |

Menu bar icon: 🎙 ready · 🔴 listening · ⏳ working · ✅ done · ⚠️ something went wrong (click 🎙 to see what).

## Add your own commands

🎙 menu → **Edit Commands…** Copy any block, change it, save (⌘S). It applies instantly.

```yaml
  - name: Write ad script
    phrases: ["ad script {text}", "write an ad script about {text}"]
    steps:
      - open_url: https://claude.ai/new
      - wait: page
      - paste: "Write a 30-second Facebook ad script for coaches about: {text}. Hook in the first 3 seconds."
      - press: enter
```

## After an update

macOS ties permissions to each build. If you install a newer version and commands stop working: System Settings → Privacy & Security → **Accessibility** → select Flow Command → **–** to remove it, then reopen the app and allow it again.
