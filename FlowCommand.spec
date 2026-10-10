# PyInstaller recipe for the Mac app (GitHub runs this — you never need to)
from PyInstaller.utils.hooks import collect_all

datas = [("commands.yaml", ".")]
binaries, hiddenimports = [], ["Quartz", "AppKit", "ApplicationServices"]
for pkg in ["faster_whisper", "ctranslate2", "sounddevice", "tokenizers", "onnxruntime", "rumps"]:
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hiddenimports += h

a = Analysis(["app.py"], datas=datas, binaries=binaries, hiddenimports=hiddenimports)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="FlowCommand",
          console=False, argv_emulation=False)
coll = COLLECT(exe, a.binaries, a.datas, name="FlowCommand")
app = BUNDLE(
    coll,
    name="FlowCommand.app",
    icon="icon.icns",
    bundle_identifier="com.sharad.flowcommand",
    info_plist={
        "CFBundleDisplayName": "Flow Command",
        "CFBundleName": "Flow Command",
        "CFBundleShortVersionString": "1.0.0",
        "LSUIElement": True,  # menu bar only, no Dock icon
        "NSMicrophoneUsageDescription":
            "Flow Command listens only while you hold the hotkey, to hear your voice commands.",
        "NSAppleEventsUsageDescription": "Flow Command opens apps to carry out your commands.",
    },
)
