# iphone-mirror-skill

A [Claude Code](https://claude.com/claude-code) skill that lets Claude see and drive a real
iPhone through macOS **iPhone Mirroring** — OCR of what's on screen, tap by label, long
press, swipe, scroll, type, wait for the screen to settle, record video.

Every input is a real touch as far as the phone is concerned. Nothing is installed on the
phone or added to the app you're testing.

## Install

```sh
git clone https://github.com/Dressi123/iphone-mirror-skill ~/.claude/skills/iphone-mirror
```

Requirements: macOS 15+ with iPhone Mirroring set up, Xcode command-line tools (the CLI
compiles itself on first run), and **Screen Recording** + **Accessibility** permission
for your terminal.

Then ask Claude to "check this on my iPhone". See [SKILL.md](SKILL.md) for the commands
and the gotchas found driving iOS through Mirroring.

## License

MIT
