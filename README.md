# Notchy

A tiny utility panel that lives in your MacBook's **notch**. Hover the notch and it grows into a glass panel; move away and it shrinks back.

- **Clipboard history**: last 30 text and image clips. Click a clip to paste it straight into the field you were typing in (falls back to copy if Accessibility access is off), or drag it into any app. Pin clips to keep them at the top; pinned clips survive the 30-clip limit and Clear. Skips passwords.
- **Screenshots**: every new screenshot shows up automatically.
- **System stats**: CPU and memory, live network usage (tap the card to run a speed test), battery.
- **Keep awake**: keep the Mac awake for 30 min to 8 h, or until turned off.
- **Key sounds**: mechanical keyboard clicks (EG Oreo pack).

Runs in the background. It starts at login, and launchd restarts it if it crashes.

## Build

```sh
./build.sh
```

Needs macOS 26+ and the Xcode Command Line Tools. Allow Notchy in **Privacy & Security → Accessibility** for key sounds and click-to-paste.

Sound pack from [Mechvibes](https://github.com/hainguyents13/mechvibes) (MIT).
