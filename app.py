"""
Flow Command for Mac — hold Control+Option, speak a command, let go.

Lives in the menu bar (🎙). Commands live in
~/Library/Application Support/FlowCommand/commands.yaml  (menu → Edit Commands…)
"""

from __future__ import annotations

import json
import logging
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

import yaml
from rapidfuzz import fuzz

APP_NAME = "Flow Command"
BUNDLE_ID = "com.sharad.flowcommand"
SUPPORT_DIR = Path.home() / "Library/Application Support/FlowCommand"
USER_COMMANDS = SUPPORT_DIR / "commands.yaml"
LOG_FILE = Path.home() / "Library/Logs/FlowCommand.log"
LAUNCH_AGENT = Path.home() / f"Library/LaunchAgents/{BUNDLE_ID}.plist"

DEFAULT_SETTINGS = {
    "hotkey": "control+option",
    "whisper_model": "base.en",
    "page_load_wait": 3.0,
    "min_match_score": 70,
    "confirm_before_send": False,
    "ai_fallback": True,
    "anthropic_api_key": "",
    "sounds": True,
}


def resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return base / name


def out(msg: str):
    """Print that works even inside a windowed .app."""
    try:
        os.write(1, (msg + "\n").encode())
    except OSError:
        pass


log = logging.getLogger("flow")


def setup_logging():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=LOG_FILE, level=logging.INFO,
        format="%(asctime)s  %(message)s", datefmt="%H:%M:%S",
    )


# ════════════════════════════════════════════════════════════
#  Commands file
# ════════════════════════════════════════════════════════════

class CommandBook:
    def __init__(self, path: Path):
        self.path = path
        self._mtime = 0.0
        self.settings: dict = dict(DEFAULT_SETTINGS)
        self.commands: list[dict] = []
        self.error: str | None = None
        self.reload_if_changed()

    def reload_if_changed(self) -> bool:
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            return False
        if mtime == self._mtime:
            return False
        self._mtime = mtime
        try:
            data = yaml.safe_load(self.path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as e:
            self.error = f"commands.yaml has a typo: {e}".splitlines()[0]
            log.error(self.error)
            return False
        self.error = None
        self.settings = {**DEFAULT_SETTINGS, **(data.get("settings") or {})}
        self.commands = [c for c in (data.get("commands") or [])
                         if isinstance(c, dict) and c.get("phrases") and c.get("steps")]
        return True


def ensure_user_commands():
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    if not USER_COMMANDS.exists():
        USER_COMMANDS.write_text(resource("commands.yaml").read_text(encoding="utf-8"), encoding="utf-8")


# ════════════════════════════════════════════════════════════
#  Matching speech → command
# ════════════════════════════════════════════════════════════

WORD_RE = re.compile(r"[A-Za-z0-9']+")


def _norm(s: str) -> str:
    return " ".join(w.lower() for w in WORD_RE.findall(s))


@dataclass
class Match:
    command: dict
    text: str
    score: float
    prefix_len: int


def match_command(transcript: str, commands: list[dict], min_score: float = 70) -> Match | None:
    words = list(WORD_RE.finditer(transcript))
    norm_words = [w.group().lower() for w in words]
    full_norm = " ".join(norm_words)
    best: Match | None = None
    for cmd in commands:
        for phrase in cmd["phrases"]:
            phrase = str(phrase)
            if "{text}" in phrase:
                prefix = _norm(phrase.split("{text}")[0])
                k0 = len(prefix.split())
                for k in {max(1, k0 - 1), k0, k0 + 1}:
                    if k >= len(norm_words):
                        continue
                    score = fuzz.ratio(" ".join(norm_words[:k]), prefix)
                    if score < min_score:
                        continue
                    rest = transcript[words[k].start():].strip(" ,.:;-")
                    best = _pick(Match(cmd, rest, score, k0), best)
            else:
                score = fuzz.ratio(full_norm, _norm(phrase))
                if score >= min_score:
                    best = _pick(Match(cmd, "", score, len(phrase.split())), best)
    return best


def _pick(a: Match, b: Match | None) -> Match:
    if b is None:
        return a
    if round(a.score) != round(b.score):
        return a if a.score > b.score else b
    return a if a.prefix_len > b.prefix_len else b


def ai_pick_command(transcript: str, commands: list[dict], api_key: str) -> Match | None:
    key = api_key or os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    import anthropic
    catalog = "\n".join(f"- {c['name']}: " + " | ".join(map(str, c["phrases"])) for c in commands)
    prompt = (
        "You route spoken voice commands to a fixed list of computer actions.\n"
        f"Available commands (name: example phrases; {{text}} = free text slot):\n{catalog}\n\n"
        f'Spoken command: "{transcript}"\n\n'
        'Reply with JSON only: {"command": "<exact name or null>", "text": "<value for {text}, or empty>"}. '
        "Clean up the text slot (fix obvious transcription errors, keep the meaning). Use null if nothing fits."
    )
    try:
        resp = anthropic.Anthropic(api_key=key).messages.create(
            model="claude-haiku-5-5", max_tokens=400,
            messages=[{"role": "user", "content": prompt}],
        )
        raw = resp.content[0].text
        data = json.loads(raw[raw.find("{"): raw.rfind("}") + 1])
    except Exception as e:
        log.warning(f"AI fallback failed: {e}")
        return None
    for c in commands:
        if c["name"] == data.get("command"):
            return Match(c, data.get("text") or "", 100, 0)
    return None


# ════════════════════════════════════════════════════════════
#  Keyboard + clipboard (native macOS, no extra libraries)
# ════════════════════════════════════════════════════════════

KEYCODES = {
    **dict(zip("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])),
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
}


def _flag_for(name: str):
    import Quartz
    return {
        # "ctrl" in commands.yaml means the Mac's normal shortcut key (Command)
        "ctrl": Quartz.kCGEventFlagMaskCommand, "cmd": Quartz.kCGEventFlagMaskCommand,
        "command": Quartz.kCGEventFlagMaskCommand,
        "control": Quartz.kCGEventFlagMaskControl,
        "alt": Quartz.kCGEventFlagMaskAlternate, "option": Quartz.kCGEventFlagMaskAlternate,
        "shift": Quartz.kCGEventFlagMaskShift,
    }.get(name)


def post_key(code: int, flags: int = 0):
    import Quartz
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        time.sleep(0.012)


def send_hotkey(combo: str):
    flags, key = 0, None
    for part in combo.lower().replace(" ", "").split("+"):
        f = _flag_for(part)
        if f is not None:
            flags |= f
        else:
            key = part
    if key not in KEYCODES:
        raise ValueError(f"Unknown key '{key}' in '{combo}'")
    post_key(KEYCODES[key], flags)


def type_text(text: str):
    import Quartz
    for i in range(0, len(text), 20):
        chunk = text[i:i + 20]
        n = len(chunk.encode("utf-16-le")) // 2
        for down in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(ev, n, chunk)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        time.sleep(0.01)


_UTF8 = {**os.environ, "LANG": "en_US.UTF-8"}


def clip_get() -> str:
    return subprocess.run(["pbpaste"], capture_output=True, text=True, env=_UTF8).stdout


def clip_set(text: str):
    subprocess.run(["pbcopy"], input=text, text=True, env=_UTF8)


def play(sound: str):
    subprocess.Popen(["afplay", f"/System/Library/Sounds/{sound}.aiff"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ════════════════════════════════════════════════════════════
#  Running a command's steps
# ════════════════════════════════════════════════════════════

CHROME = "/Applications/Google Chrome.app"


class Executor:
    def __init__(self, book: CommandBook, status):
        self.book = book
        self.status = status

    def run(self, match: Match):
        steps = match.command["steps"]
        for i, step in enumerate(steps):
            (kind, value), = step.items()
            is_send = (kind == "press" and str(value).lower() in ("enter", "return")
                       and i > 0 and "paste" in steps[i - 1])
            if is_send and self.book.settings.get("confirm_before_send"):
                continue
            fn = getattr(self, f"do_{kind}", None)
            if not fn:
                raise ValueError(f"Unknown step type: {kind}")
            fn(self._fill(value, match.text))

    @staticmethod
    def _fill(value, text):
        return (str(value).replace("{text_url}", urllib.parse.quote_plus(text))
                .replace("{text}", text))

    def do_open_url(self, url):
        if Path(CHROME).exists():
            subprocess.Popen(["open", "-na", "Google Chrome", "--args", "--new-window", url])
        else:
            subprocess.Popen(["open", url])
        time.sleep(0.4)

    def do_new_tab(self, url):
        subprocess.Popen(["open", "-a", "Google Chrome" if Path(CHROME).exists() else "Safari", url])
        time.sleep(0.4)

    def do_launch(self, app):
        subprocess.Popen(["open", "-a", app])
        time.sleep(0.8)

    def do_hotkey(self, combo):
        send_hotkey(combo)
        time.sleep(0.1)

    def do_press(self, key):
        send_hotkey(key)
        time.sleep(0.1)

    def do_type(self, text):
        type_text(text)

    def do_paste(self, text):
        old = clip_get()
        clip_set(text)
        time.sleep(0.05)
        send_hotkey("cmd+v")
        time.sleep(0.35)
        threading.Timer(1.5, lambda: clip_set(old)).start()

    def do_wait(self, secs):
        time.sleep(float(self.book.settings["page_load_wait"] if str(secs) == "page" else secs))

    def do_screenshot(self, _):
        folder = Path.home() / "Pictures/FlowCommand"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / time.strftime("shot_%Y%m%d_%H%M%S.png")
        subprocess.run(["screencapture", "-x", str(path)])

    def do_shell(self, cmd):
        subprocess.Popen(cmd, shell=True)


# ════════════════════════════════════════════════════════════
#  Microphone + Whisper
# ════════════════════════════════════════════════════════════

class Recorder:
    RATE = 16000

    def __init__(self):
        self.chunks: list = []
        self.stream = None

    def start(self):
        import sounddevice as sd
        self.chunks = []
        self.stream = sd.InputStream(samplerate=self.RATE, channels=1, dtype="float32",
                                     callback=lambda d, *_: self.chunks.append(d.copy()))
        self.stream.start()

    def stop(self):
        import numpy as np
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        return np.concatenate(self.chunks)[:, 0] if self.chunks else np.zeros(0, "float32")


class Transcriber:
    def __init__(self, model_name: str):
        from faster_whisper import WhisperModel
        self.model = WhisperModel(model_name, device="cpu", compute_type="int8")

    def __call__(self, audio) -> str:
        segments, _ = self.model.transcribe(
            audio, language="en", beam_size=1, vad_filter=True,
            initial_prompt="Ask Claude, ChatGPT, Gmail, GoHighLevel, Google Docs.",
        )
        return " ".join(s.text.strip() for s in segments).strip()


# ════════════════════════════════════════════════════════════
#  Hold-to-talk modifier hotkey (native NSEvent monitor)
# ════════════════════════════════════════════════════════════

MOD_BITS = {
    "control": 1 << 18, "ctrl": 1 << 18,
    "option": 1 << 19, "alt": 1 << 19, "opt": 1 << 19,
    "shift": 1 << 17, "command": 1 << 20, "cmd": 1 << 20, "fn": 1 << 23,
}
ALL_MODS = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)


def hotkey_mask(spec: str) -> int:
    mask = 0
    for part in str(spec).lower().replace(" ", "").split("+"):
        if part not in MOD_BITS:
            raise ValueError(f"Hotkey must be modifier keys only (control, option, shift, command, fn) — got '{part}'")
        mask |= MOD_BITS[part]
    return mask


def accessibility_ok(prompt: bool) -> bool:
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
        return bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: prompt}))
    except Exception:
        return True


# ════════════════════════════════════════════════════════════
#  Login item
# ════════════════════════════════════════════════════════════

def app_bundle_path() -> Path | None:
    exe = Path(sys.executable).resolve()
    for p in exe.parents:
        if p.suffix == ".app":
            return p
    return None


def set_login_item(enabled: bool):
    if enabled:
        bundle = app_bundle_path()
        if not bundle:
            raise RuntimeError("Only works from the installed app")
        LAUNCH_AGENT.parent.mkdir(parents=True, exist_ok=True)
        LAUNCH_AGENT.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{BUNDLE_ID}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>{bundle}</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
""")
    elif LAUNCH_AGENT.exists():
        LAUNCH_AGENT.unlink()


# ════════════════════════════════════════════════════════════
#  Menu bar app
# ════════════════════════════════════════════════════════════

ICON_IDLE, ICON_REC, ICON_BUSY, ICON_OK, ICON_ERR = "🎙", "🔴", "⏳", "✅", "⚠️"


def build_app():
    import rumps
    from AppKit import NSEvent

    class FlowApp(rumps.App):
        def __init__(self):
            super().__init__(APP_NAME, title=ICON_BUSY, quit_button=None)
            ensure_user_commands()
            self.book = CommandBook(USER_COMMANDS)
            self.executor = Executor(self.book, self.set_status)
            self.recorder = Recorder()
            self.transcriber: Transcriber | None = None
            self.recording = False
            self.busy = False
            self.flags = 0
            self.q: queue.Queue = queue.Queue()
            self._revert_at = 0.0

            self.status_item = rumps.MenuItem("Starting…")
            self.login_item = rumps.MenuItem("Start at Login", callback=self.toggle_login)
            self.login_item.state = LAUNCH_AGENT.exists()
            self.menu = [
                self.status_item,
                None,
                rumps.MenuItem("Edit Commands…", callback=self.edit_commands),
                rumps.MenuItem("How to Use", callback=self.how_to),
                self.login_item,
                rumps.MenuItem("Show Log", callback=lambda _: subprocess.Popen(["open", "-a", "Console", str(LOG_FILE)])),
                None,
                rumps.MenuItem("Quit Flow Command", callback=lambda _: rumps.quit_application()),
            ]

            self._apply_hotkey()
            handler = self._on_flags
            self._mon_global = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(1 << 12, handler)
            self._mon_local = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
                1 << 12, lambda e: (handler(e), e)[1])
            self._timer = rumps.Timer(self._pump, 0.08)
            self._timer.start()

            if not accessibility_ok(prompt=True):
                self.set_status("Allow Flow Command in Settings → Accessibility, then reopen it", ICON_ERR)
            threading.Thread(target=self._load_model, daemon=True).start()

        # ---------- status (thread-safe) ----------
        def set_status(self, text: str, icon: str | None = None, hold: float | None = None):
            self.q.put((text, icon, hold))

        def _pump(self, _):
            try:
                while True:
                    text, icon, hold = self.q.get_nowait()
                    self.status_item.title = text[:90]
                    if icon:
                        self.title = icon
                    self._revert_at = time.time() + hold if hold else 0
            except queue.Empty:
                pass
            if self._revert_at and time.time() > self._revert_at and not self.busy:
                self._revert_at = 0
                self.title = ICON_IDLE
                self.status_item.title = f"Ready — hold {self._hk_label} and speak"

        # ---------- setup ----------
        def _apply_hotkey(self):
            spec = self.book.settings["hotkey"]
            try:
                self.mask = hotkey_mask(spec)
            except ValueError as e:
                log.error(e)
                spec = DEFAULT_SETTINGS["hotkey"]
                self.mask = hotkey_mask(spec)
            self._hk_label = " + ".join(p.capitalize() for p in spec.split("+"))

        def _load_model(self):
            name = self.book.settings["whisper_model"]
            self.set_status(f"Loading speech model ({name})… first time downloads ~150 MB", ICON_BUSY)
            try:
                self.transcriber = Transcriber(name)
            except Exception as e:
                log.exception("model load failed")
                self.set_status(f"Couldn't load speech model: {e}", ICON_ERR)
                return
            log.info("model ready")
            self.set_status(f"Ready — hold {self._hk_label} and speak", ICON_IDLE)

        # ---------- hotkey ----------
        def _on_flags(self, event):
            self.flags = int(event.modifierFlags()) & ALL_MODS
            held = (self.flags & self.mask) == self.mask
            if held and not self.recording and not self.busy:
                if not self.transcriber:
                    self.set_status("Still loading the speech model — one moment", ICON_BUSY, hold=2)
                    return
                try:
                    self.recorder.start()
                except Exception as e:
                    self.set_status(f"Microphone error: {e}", ICON_ERR, hold=4)
                    return
                self.recording = True
                self.title = ICON_REC
                self.status_item.title = "Listening…"
                if self.book.settings.get("sounds"):
                    play("Pop")
            elif not held and self.recording:
                self.recording = False
                audio = self.recorder.stop()
                if len(audio) < Recorder.RATE * 0.4:      # a quick tap, not a command
                    self.title = ICON_IDLE
                    return
                self.busy = True
                self.title = ICON_BUSY
                threading.Thread(target=self._handle, args=(audio,), daemon=True).start()

        # ---------- pipeline ----------
        def _handle(self, audio):
            snd = self.book.settings.get("sounds")
            try:
                if self.book.reload_if_changed():
                    self._apply_hotkey()
                    log.info("commands.yaml reloaded")
                if self.book.error:
                    self.set_status(self.book.error, ICON_ERR, hold=6)
                    return
                text = self.transcriber(audio)
                log.info(f"heard: {text!r}")
                if not text:
                    self.set_status("Didn't catch that", ICON_ERR, hold=2)
                    return
                s = self.book.settings
                match = match_command(text, self.book.commands, s["min_match_score"])
                if not match and s.get("ai_fallback"):
                    self.set_status(f"Thinking: “{text}”", ICON_BUSY)
                    match = ai_pick_command(text, self.book.commands, s.get("anthropic_api_key", ""))
                if not match:
                    if snd:
                        play("Basso")
                    self.set_status(f"No command for: “{text}”", ICON_ERR, hold=4)
                    return
                label = match.command["name"] + (f": {match.text}" if match.text else "")
                log.info(f"run: {label}")
                self.set_status(f"▶ {label}", ICON_BUSY)
                self._wait_keys_up()
                self.executor.run(match)
                if snd:
                    play("Tink")
                self.set_status(f"Done — {label}", ICON_OK, hold=2)
            except Exception as e:
                log.exception("command failed")
                self.set_status(f"Error: {e}", ICON_ERR, hold=5)
            finally:
                self.busy = False

        def _wait_keys_up(self, timeout=1.5):
            end = time.time() + timeout
            while self.flags and time.time() < end:
                time.sleep(0.03)
            time.sleep(0.1)

        # ---------- menu actions ----------
        def edit_commands(self, _):
            subprocess.Popen(["open", "-e", str(USER_COMMANDS)])

        def how_to(self, _):
            rumps.alert(
                "How to use Flow Command",
                f"Hold {self._hk_label}, say a command, then let go.\n\n"
                "Try:\n• “Ask Claude write me 5 hooks for a coaching ad”\n• “Open Gmail”\n"
                "• “Google best CRM for coaches”\n• “Open GHL”\n• “Type see you tomorrow”\n\n"
                "Add your own: menu → Edit Commands… (saves apply instantly).",
            )

        def toggle_login(self, item):
            try:
                set_login_item(not item.state)
                item.state = not item.state
            except Exception as e:
                rumps.alert("Couldn't change login setting", str(e))

    return FlowApp()


# ════════════════════════════════════════════════════════════

def selftest():
    """Used by the GitHub build to check everything was bundled."""
    try:
        import faster_whisper, ctranslate2, sounddevice, rumps, Quartz, AppKit, anthropic  # noqa
        from ApplicationServices import AXIsProcessTrustedWithOptions  # noqa
        book = CommandBook(resource("commands.yaml"))
        cases = {
            "Ask Claude, write me a post about funnels.": ("Ask Claude", "write me a post about funnels"),
            "Open GHL": ("Open GoHighLevel", ""),
            "Type and send see you soon": ("Type this and send", "see you soon"),
        }
        for said, (name, text) in cases.items():
            m = match_command(said, book.commands)
            assert m and m.command["name"] == name and m.text == text, (said, m)
        hotkey_mask(book.settings["hotkey"])
        out("SELFTEST OK")
        return 0
    except Exception as e:
        out(f"SELFTEST FAILED: {e!r}")
        return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) > 2 and sys.argv[1] == "--test":
        book = CommandBook(resource("commands.yaml"))
        m = match_command(" ".join(sys.argv[2:]), book.commands, book.settings["min_match_score"])
        out(f"{m.command['name']} | text={m.text!r} | score={m.score:.0f}" if m else "no match")
        sys.exit(0)
    setup_logging()
    log.info("starting")
    build_app().run()
