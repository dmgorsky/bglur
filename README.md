# bglur

A lightweight macOS menu-bar app (macOS 13+) that blurs and dims everything behind the active window so your focused window stands out.

## Behavior

- **Active-window cutout:** Uses a click-through overlay window per screen (`level = normal + 1`) with `CAShapeLayer`-masked `NSVisualEffectView` backdrop layers to blur all background windows and the desktop wallpaper outside the active window's bounds.
- **Bidirectional gradual transitions:** When switching windows, the newly focused window starts blurred and smoothly clears while the previously focused window smoothly blurs, keeping the rest of the screen continuously blurred without flashes.
- **Zero-blink switching:** Predicts clicks on `leftMouseDown` and keeps the incoming unblur layer pre-warmed behind an empty mask so the newly active window never flashes clear before animating.
- **Full-screen aware:** Space-bound overlays stay on Desktop Spaces and detect native macOS Fullscreen Spaces without Screen Recording permission, so switching to a full-screen app goes straight to unblurred with no blurred start, blink, or off-screen redraw.

## Menu Bar Controls

Settings persist in `UserDefaults`:

- **Enable Blur (`⌘B`):** Toggle background blur on/off (default: on).
- **Blur Radius:** `0–60 px` (default: `24 px`).
- **Transition Speed:** `50–600 ms` (default: `180 ms`).
- **Dimming:** `0%–40%` (default: `5%`).
- **Reset Defaults** / **Quit bglur (`⌘Q`)**

## Build & Run

```bash
# Build release app bundle (bglur.app)
./bundle.sh

# Launch menu-bar app
open bglur.app

# Debug build & self-test
swift build
.build/debug/bglur --self-test
```
