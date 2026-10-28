---
name: iphone-mirror
description: See and drive Andreas's real iPhone through the macOS iPhone Mirroring window — screenshots, OCR of what's on screen, tap by label or point, scroll, and the devicectl commands to install, launch and read logs from a dev build. Use when asked to look at, tap through, or test something on the iPhone, or to check an app change on the device by hand.
---

# iphone-mirror

`~/.claude/skills/iphone-mirror/iphone` is a compiled Swift CLI. It rebuilds itself when
`iphone.swift` changes, so it is never rebuilt by hand.

## Before you start

- iPhone Mirroring must be open and connected, with the phone **locked and left alone**.
  Picking it up ends mirroring ("iPhone in Use"). `iphone state` tells you which:
  `connected | in-use | connecting | disconnected | blank`. `iphone connect` presses
  Connect and waits. For `in-use`, ask the user to lock the phone.
- The terminal needs **Screen Recording** (for captures) and **Accessibility** (for input).
- Synthetic input only reaches the frontmost app, so every action brings iPhone Mirroring
  forward, then gives focus and the cursor back. Still, tell the user not to use the
  mouse while you are driving.
- **Privacy.** You are looking at a personal phone. Go only where the task needs. If the
  screen shows something unrelated (mail, messages, notifications), stop and say so
  rather than read it.

## Commands

All coordinates are **window points**. `iphone shot` saves at exactly that size, so a
pixel in the shot is the point to pass to `tap`.

```
iphone state | connect | window
iphone shot PATH                         # look (costs image tokens, see below)
iphone text [--json]                     # OCR: "x y w h<TAB>text" (cheap, prefer it)
iphone tap-text "Build catalogue" [--nth 2] [--regex]   # case and spaces ignored
iphone tap X Y
iphone wait-text "Copy catalogue text" --timeout 300
# wait for something that appears only when the work is done. A counter on screen matches
# while it is still climbing; for a long build, poll the console log for its final line.
iphone scroll -600 [--at X Y]            # negative = down; lists need wheel, not drag
iphone drag X1 Y1 X2 Y2 [--hold 700]     # --hold long-presses first: drag-to-reorder rows
iphone drag X1 Y1 X2 Y2
iphone back                              # the top-left nav back button
iphone home | switcher | spotlight | type TEXT   # see Known issues
```

Any action also takes `--wait MS` (default 700) and `--shot PATH` to act and look in one call.

**Prefer `text` over `shot`.** It returns positions and labels for a few hundred tokens of
text, where a screenshot is an image read into context. Use `shot` when you need to judge
what a photo or layout actually looks like, not to find a button.

## Dev builds on the device (Marble)

Device id: `xcrun devicectl list devices`. Prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```
xcodebuild -project Marble.xcodeproj -scheme Marble -destination "id=<device>" -derivedDataPath <dd> build
xcrun devicectl device install app --device <device> <dd>/Build/Products/Debug-iphoneos/Marble.app
xcrun devicectl device process launch --terminate-existing --device <device> com.dressi.marble
```

Installing drops mirroring for a few seconds; `iphone state` until `connected`.

**Getting text out of the app:** don't read long text off screenshots, and don't rely on the
copy button — Universal Clipboard did not carry it to the Mac. Either launch with
`--console` (run in the background, redirect to a file) to capture `print` output —
**stopping that devicectl process ends the app too**, so leave it running until you are
done with the app — or have
the app write a file and pull it with `xcrun devicectl device copy from --device <device>
--domain-type appDataContainer --domain-identifier com.dressi.marble --source <path> --destination <local>`.

## Known issues

- Relaunching an app drops mirroring to "Connection Paused" for ~10 s and it resumes by
  itself; poll `iphone state` rather than tapping Resume.
- Universal Clipboard works (fixed 2026-10-20): an in-app copy button plus `pbpaste`
  after ~5 s is the quickest way to get a block of text out.
- OCR uses Vision's `.fast` recognizer on the Retina capture. `.accurate` fails on the
  neural engine on this macOS (`e5rt` error 13) and stalls ~60 s on the CPU. Fast reads
  most UI labels; it mangles small icon labels ("Map5"), so match on a distinctive word.
- Capture by window ID sometimes returns a blank frame of the mirrored video; the tool
  then falls back to capturing the window's screen region with it in front.
- `type`, `home`, `switcher` and `spotlight` post keyboard events that did **not** register
  in the one test so far (mirroring was reconnecting at the time, so unconfirmed). Verify
  with `text` after using them; tapping is the reliable path.
