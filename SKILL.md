---
name: iphone-mirror
description: See and drive the user's real iPhone through the macOS iPhone Mirroring window — screenshots, OCR of what's on screen, tap by label or point, long press, swipe, scroll, type, record — plus the devicectl commands to install, launch and read logs from a dev build. Use when asked to look at, tap through, or test something on the iPhone, or to check an app change on the device by hand.
---

# iphone-mirror

`~/.claude/skills/iphone-mirror/iphone` is a compiled Swift CLI. It rebuilds itself when
`iphone.swift` changes, so it is never rebuilt by hand.

Every input is a real touch as far as the phone is concerned: the tool moves and clicks
the Mac's pointer over the mirrored screen. Nothing is installed on the phone or in the
app under test.

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
iphone text [--json] [--region X Y W H]  # OCR: "x y w h<TAB>text" (cheap, prefer it)
iphone shot PATH [--grid]                # look; --grid numbers the coordinates
iphone shot PATH --crop X Y W H          # one area at full Retina resolution

iphone tap X Y [--hold MS]               # --hold 900: long press (context menus)
iphone tap-text "Save" [--nth 2] [--regex] [--offset DX DY] [--hold MS] [--region X Y W H]
iphone double-tap X Y
iphone swipe X1 Y1 X2 Y2 [--ms 150]      # flick, released moving: pages, swipe actions
iphone drag X1 Y1 X2 Y2 [--hold 700]     # slow, rests before lifting; --hold reorders rows
iphone scroll -600 [--dx -400] [--at X Y]  # negative = down / right; lists want wheel, not drag
iphone back                              # the top-left back button
iphone type "Lima\n" | key delete [--cmd] | home | switcher | spotlight

iphone wait-text "Done" --timeout 300    # until it appears
iphone wait-gone "Scanning" --timeout 60 # until it disappears
iphone wait-stable                       # until the screen stops moving
iphone record PATH.mov [--seconds 10]    # video of the window, clicks shown
iphone run <<'EOF'                       # several steps in one call, focus held throughout
tap-text Trips
tap-text "Peru trip"
text --region 0 80 398 200
EOF
```

**Every action waits for the screen to settle** before returning: until it has changed,
then stopped moving (a caret or a small spinner doesn't count as moving). When nothing
changed it prints `screen did not change` — the tap probably missed. `--wait MS` sleeps a
fixed time instead, `--wait 0` not at all, and `--shot PATH` looks right after.

**Prefer `text` over `shot`.** It returns positions and labels for a few hundred tokens of
text, where a screenshot is an image read into context. Use `shot` when you need to judge
what a photo or layout actually looks like. For an icon with no text (heart, share, ×,
+), `tap-text` the label beside it with `--offset`, or take `shot --grid` once and read
the point off the grid.

**Use `run` for a sequence.** One process, one focus switch, and each step still settles.
It stops at the first failing step and names it. Lines are split like a shell, `#` comments.

## Gotchas

- **Home-screen app names are not part of the icon.** Tapping the label does nothing;
  tap the icon: `tap-text Settings --offset 0 -25`.
- **Rows behind a floating bar.** Text OCR can read under a bottom search or tab bar is
  not tappable there. Scroll it up first.
- **No back swipe, no pinch.** Both work from a real trackpad but cannot be synthesized.
  A recording of real two-finger-back and pinch gestures, replayed event for event (scroll,
  gesture and click events, original timing), moved nothing: Mirroring takes these from
  the trackpad itself, not from the event stream, so posted events never reach them.
  Hand-built phased scrolls and magnify events fail the same way. `back` taps the button,
  and `double-tap` zooms a map in; there is no way to zoom out.
- **Swipes that start on a widget** go to the widget, not the page under it.
- **`tap-text` matches any text**, a heading included: on a page titled "General", the
  title matches before anything else does. Use `--region` or `--nth` when it's ambiguous.
- **`record` captures the window's screen region**, so it must stay uncovered: start it
  in the background and drive with `run`, which keeps Mirroring in front. Pull frames
  with `ffmpeg -i rec.mov -vf fps=10 frame-%03d.png`. The top edge of the video can catch
  a sliver of whatever is just above the window, the Mac's menu bar included.

## Dev builds on the device

Device id: `xcrun devicectl list devices`. Prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
if `xcode-select` points at the Command Line Tools.

```
xcodebuild -project <App>.xcodeproj -scheme <Scheme> -destination "id=<device>" -derivedDataPath <dd> build
xcrun devicectl device install app --device <device> <dd>/Build/Products/Debug-iphoneos/<App>.app
xcrun devicectl device process launch --terminate-existing --device <device> <bundle.id>
```

Installing drops mirroring for a few seconds; `iphone state` until `connected`.

**Getting text out of the app:** don't read long text off screenshots. Either launch with
`--console` (run in the background, redirect to a file) to capture `print` output —
**stopping that devicectl process ends the app too**, so leave it running until you are
done with the app — or have the app write a file and pull it with `xcrun devicectl device
copy from --device <device> --domain-type appDataContainer --domain-identifier <bundle.id>
--source <path> --destination <local>`. Universal Clipboard also works: an in-app copy
button, then `pbpaste` after ~5 s.

## Known issues

- Relaunching an app drops mirroring to "Connection Paused" for ~10 s and it resumes by
  itself; poll `iphone state` rather than tapping Resume.
- OCR uses Vision's `.fast` recognizer, twice: once as captured and once on a darkened
  greyscale copy, which is what finds white labels on a light wallpaper. `.accurate`
  failed on the neural engine on macOS 26 (`e5rt` error 13) and stalls ~60 s on the CPU.
  Fast mangles small icon labels ("Map5"), so match on a distinctive word.
- Capture by window ID sometimes returns a blank frame of the mirrored video; the tool
  then falls back to capturing the window's screen region with it in front.
- `type` presses real keys on the Mac's current layout; a character the layout can't
  type is skipped with a warning.
