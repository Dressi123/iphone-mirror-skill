# iphone-mirror-skill

A [Claude Code](https://claude.com/claude-code) skill that lets Claude see and drive your
**real iPhone**. It reads the screen with OCR, taps by label, long presses, swipes,
scrolls, pinches, types, waits for animations to settle and records video.

Nothing is installed on the phone, and nothing is added to the app you are testing, so
what Claude exercises is the build your users get. There are three ways in:

| Mode | How it sees | How it touches | Your mouse |
|---|---|---|---|
| **iPhone Mirroring** (default) | the Mirroring window | the Mac's pointer and keyboard | taken while it acts |
| **Device Hub** (`IPHONE_APP=devicehub`) | Xcode's Device Hub window | the Mac's pointer and keyboard | taken while it acts |
| **Device** (`IPHONE_APP=device`, new, fragile) | the phone's own screenshots | Xcode's private touch service | **never touched** |

Device mode is the new one: Claude drives the phone while you keep using your Mac, and it
can do what a pointer can't (pinch, the edge back swipe). It relies on a private Apple
framework, so read [Device mode](#device-mode-no-window-no-pointer) before you rely on it.

```
you:     open my app on the phone, add a trip to Lisbon and check the map updates
claude:  iphone tap-text "New trip"   →  iphone type "Lisbon\n"  →  iphone shot map.png ...
```

## Requirements

- A Mac with **iPhone Mirroring** working: macOS 15 or later and iOS 18 or later, signed
  in to the same Apple Account, with Wi-Fi and Bluetooth on. Apple doesn't offer iPhone
  Mirroring in every region.
- The Xcode command-line tools, to compile the CLI on first run: `xcode-select --install`.
- [Claude Code](https://claude.com/claude-code).
- Optional: `ffmpeg`, to pull frames out of recordings.

## Setup

**1. Install the skill**

```sh
git clone https://github.com/Dressi123/iphone-mirror-skill ~/.claude/skills/iphone-mirror
```

**2. Connect iPhone Mirroring once by hand.** Open the iPhone Mirroring app, follow its
setup, and check that you can see and click your phone. Then **lock the phone and put it
down**: picking it up ends mirroring.

**3. Grant permissions to the app Claude Code runs in.** That's Terminal, iTerm, Warp,
VS Code or whatever you use, not the skill itself. In **System Settings → Privacy &
Security**, turn it on under both:

- **Screen Recording**: to see the phone.
- **Accessibility**: to tap and type.

Quit and reopen that app afterwards; macOS only applies the change on relaunch.

**4. Check it works**

```sh
~/.claude/skills/iphone-mirror/iphone state   # → connected
~/.claude/skills/iphone-mirror/iphone text    # → what's on the phone's screen, one line each
```

The first run compiles the CLI, which takes a few seconds. If `state` prints `in-use`, lock
the phone. If `text` prints nothing or fails, recheck Screen Recording.

## Device mode: no window, no pointer

```sh
IPHONE_APP=device ~/.claude/skills/iphone-mirror/iphone state      # → connected
IPHONE_APP=device ~/.claude/skills/iphone-mirror/iphone text       # → the screen, read off the phone
IPHONE_APP=device ~/.claude/skills/iphone-mirror/iphone pinch 196 300 40 300   # zoom in, two fingers
```

It needs **Xcode** (not only the command-line tools) and a phone connected to it: paired,
unlocked, and listed by `xcrun devicectl list devices`. No Screen Recording or
Accessibility permission is needed, since nothing on the Mac is captured or clicked.

**How it works.** Xcode's Device Hub shows a connected phone and turns your clicks into
touches through a service in Xcode's private `CoreDevice` framework, a remote digitizer
that takes one or two touch points and an edge, and a remote keyboard beside it. The skill calls that service directly from
a small helper, `bin/iphone-hid`. Screenshots come from `devicectl`, Xcode's supported
command-line tool for devices.

**Why it's fragile.** `CoreDevice` is private: Apple publishes no interface for it and
promises nothing about it. The skill carries a hand-written description of the few types it
needs (`hid/CoreDevice.swiftmodule/`), worked out from the framework's exported symbols on
Xcode 27 (CoreDevice 642.16). So:

- **Any Xcode update can break it.** The helper rebuilds itself whenever CoreDevice's
  version changes. If Apple renames or reshapes one of those types, the build fails and
  device mode stops working until the interface is updated; the window modes are
  unaffected.
- **A wrong declaration crashes rather than errors.** If a type changes shape without its
  name changing, the helper can crash or send a garbled touch.
- **It is not an Apple-supported way to drive a phone.** It uses the same service Device
  Hub uses, but nothing guarantees it keeps working, or keeps working the same way.
- **You can't see what Claude is doing** unless Device Hub is open, and the phone may be in
  your hand. The skill tells Claude to check the phone is idle first.

It is also slower to look (about 1.5 s per screenshot, so actions settle on a fixed wait),
and it can't record yet: use a window mode for that. It types as a US hardware keyboard,
so symbols come out right only if the phone's hardware keyboard layout is US.

## Using it

Ask Claude in plain words. It loads the skill when a task involves the phone:

- "Open Settings on my phone and tell me which iOS version it's on."
- "Install the dev build on my iPhone and go through the onboarding."
- "On the phone, add an item in my app and check the list updates."
- "Record the sheet opening on the device so we can look at the animation."

In the window modes, **leave the mouse alone** while Claude drives. Each action brings the
window to the front and hands focus back afterwards, and moving the mouse mid-gesture
breaks it. In device mode you can carry on working.

You can also run the CLI yourself. `iphone` with no arguments lists every command, and
[SKILL.md](SKILL.md) is the full reference Claude reads.

## What it can and can't do

| | Mirroring / Device Hub | Device mode |
|---|---|---|
| Tap, long press, double-tap, swipe, drag, scroll | yes | yes |
| Pinch, two fingers | no | yes |
| Edge back swipe | no (`back` taps the button) | yes |
| Type and press keys | yes | yes (US layout) |
| OCR, screenshots, coordinate grid | yes | yes |
| Record video | yes | no |
| Light/dark, text size, orientation, location (`appearance`, `orientation`, `location`) | yes, through `devicectl` | yes |

Pinch and the back swipe work from a real trackpad, but neither window will take them from
software; even an exact replay of a recorded real gesture does nothing. Device mode gets
them by skipping the window. See SKILL.md for the details.

**Privacy:** Claude is looking at your personal phone. The skill tells it to stay on task
and to stop if unrelated messages or notifications show up, but it can see whatever the
screen shows. Close anything you'd rather it didn't see first.

## Updating and removing

```sh
git -C ~/.claude/skills/iphone-mirror pull   # update; the CLI rebuilds itself
rm -rf ~/.claude/skills/iphone-mirror        # remove
```

## License

MIT
