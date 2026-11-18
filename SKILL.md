---
name: iphone-mirror
description: See and drive the user's real iPhone, through the iPhone Mirroring window, Xcode's Device Hub, or with no window at all (device mode, which touches through Xcode's private CoreDevice service and leaves the Mac's mouse alone). Screenshots, OCR of what's on screen, tap by label or point, long press, swipe, scroll, pinch, edge swipes, type, record; light/dark, text size, orientation and location through devicectl; plus the devicectl commands to install, launch and read logs from a dev build. Use when asked to look at, tap through, or test something on the iPhone, or to check an app change on the device by hand.
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

## Device Hub instead of Mirroring

Xcode's Device Hub (`DeviceHub.app`, inside Xcode) shows a connected iPhone's screen, or a
simulator's, in a window that takes clicks as touches. `IPHONE_APP=devicehub` points every
window command at it. Unlike Mirroring, the phone stays usable in your hand while Device Hub
shows it, so `state` is not a guard (`connect` presses Device Hub's View Screen): **check that the user isn't using the phone before you
drive it.** `home` presses Device Hub's own Home button through Accessibility; `switcher`
and `spotlight` have no Device Hub equivalent.

## Device mode: no window, no pointer

`IPHONE_APP=device` drives the phone with nothing on the Mac: `shot`, `text`, `tap-text` and
`wait-text` read the device's own screenshots (scaled to points, so a pixel in a shot is
still the point to tap), and `tap`, `double-tap`, `drag`, `swipe`, `scroll`, `pinch`, `back`
and `home` go through CoreDevice's remote digitizer, the service Device Hub turns clicks
into. The user's mouse, keyboard and focus stay theirs. It adds what a pointer can't do:

```
iphone pinch 196 300 40 300 [--ms 400]   # two fingers, gap 40 pt → 300 pt (zoom in)
iphone back                              # the real swipe in from the left edge
iphone home                              # the swipe up from the bottom edge
```

- `bin/iphone-hid` does the touching. CoreDevice is private and ships no Swift interface:
  `hid/CoreDevice.swiftmodule/` is a hand-written slice of it, and `build-hid.sh` builds the
  helper only where the framework exists, again whenever its version changes. If an Xcode
  update breaks it, the window modes still work.
- Slower to look: a screenshot takes ~1.5 s, so an action settles on a fixed 700 ms wait
  rather than watching for stillness. Pass `--wait MS` to change it.
- No typing yet (`type`, `key`), and no `record`: use a window mode for those.
- **Nothing shows the user what you are doing**, and the phone may be in their hand. Take a
  `shot` first and drive only an idle phone, on the screens the task needs.

## Commands on the device itself

These go through Xcode's `devicectl`, to the device rather than a window, so they work
with any window or none, and on a booted simulator too. The device is `IPHONE_DEVICE` if
set, else the first connected physical iPhone, else a booted simulator.

```
iphone screenshot PATH.png               # native resolution; pixels are device pixels, not tap points
iphone screen-record PATH.mp4 [--seconds 10]   # simulators only; on a phone, `record` the window
iphone appearance                        # print light/dark, text size, reduce motion, ...
iphone appearance dark                   # or light; plus any `devicectl device settings appearance` flag:
iphone appearance --text-size axxxl --larger-accessibility-sizes on
iphone orientation [get | portrait | landscapeLeft | landscapeRight | left | right]
iphone location 55.676 12.568 | clear
iphone device info displays              # any `devicectl device` subcommand, on this device
```

Settings changed here are the phone's own: put them back when done (`appearance` bare
shows what they were).

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
- **No back swipe, no pinch** through a window (Mirroring or Device Hub). Device mode does both. Both work from a real trackpad but cannot be synthesized.
  A recording of real two-finger-back and pinch gestures, replayed event for event (scroll,
  gesture and click events, original timing), moved nothing. The likely reason: Mirroring reads these from
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
