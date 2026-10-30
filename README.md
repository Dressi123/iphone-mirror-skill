# iphone-mirror-skill

A [Claude Code](https://claude.com/claude-code) skill that lets Claude see and drive your
**real iPhone** through macOS **iPhone Mirroring**. It reads the screen with OCR, taps by
label, long presses, swipes, scrolls, types, waits for animations to settle and records
video.

It drives the phone the way you would from the Mirroring window: the Mac's pointer and
keyboard. Nothing is installed on the phone, and nothing is added to the app you are
testing, so what Claude exercises is the build your users get.

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

## Using it

Ask Claude in plain words. It loads the skill when a task involves the phone:

- "Open Settings on my phone and tell me which iOS version it's on."
- "Install the dev build on my iPhone and go through the onboarding."
- "On the phone, add an item in my app and check the list updates."
- "Record the sheet opening on the device so we can look at the animation."

While Claude drives, **leave the mouse alone**. Each action brings iPhone Mirroring to the
front and hands focus back afterwards, and moving the mouse mid-gesture breaks it.

You can also run the CLI yourself. `iphone` with no arguments lists every command, and
[SKILL.md](SKILL.md) is the full reference Claude reads.

## What it can and can't do

| Works | Doesn't |
|---|---|
| Tap, long press, double-tap | Pinch, or zooming a map out |
| Swipe, drag, drag-to-reorder, scroll both ways | The two-finger / edge back swipe (`back` taps the button) |
| Type and press keys, Home, Spotlight | Multi-finger gestures |
| OCR, screenshots, coordinate grid, video | Reading text the screen doesn't show |

Pinch and the back swipe work from a real trackpad, but iPhone Mirroring won't take them
from software. Even an exact replay of a recorded real gesture does nothing. See
SKILL.md for the details.

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
