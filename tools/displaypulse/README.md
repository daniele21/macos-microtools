# DisplayPulse

Minimal macOS menu-bar brightness utility for an external display, initially tested against the **Atlantis A05-P156WP** connected directly by USB-C to an Apple Silicon Mac.

## Important: hardware versus software

- **Hardware (DDC/CI):** optional [m1ddc](https://github.com/waydabber/m1ddc) controls the monitor's actual backlight *if the monitor supports the DDC/CI luminance VCP command*. USB-C alone does not prove that.
- **Software (overlay):** zero extra dependencies. A mouse-transparent black AppKit window dims the picture only on the selected screen. It does **not** reduce monitor backlight power, does not necessarily affect screenshots, and might not cover all full-screen apps.
- On launch DisplayPulse does not set hardware brightness or dim the screen.
- Hardware mode stays disabled until a **successful read-only** DDC probe.
- The screen selection for software overlay is independent of the m1ddc display identifier. Always verify both if multiple monitors are attached.

## Build and launch

From the repo root:

~~~bash
make install-displaypulse
open "$HOME/.local/opt/DisplayPulse.app"
~~~

DisplayPulse appears only in the menu bar. It has an explicit **Esci** button.

## Check if DDC/CI works

~~~bash
brew install m1ddc
m1ddc display list detailed
# Select the correct Atlantis number, e.g. 1:
m1ddc display 1 get luminance
# Or use DisplayPulse's read-only CLI probe after building:
"$HOME/.local/opt/DisplayPulse.app/Contents/MacOS/DisplayPulse" --probe 1
~~~

If you get a readable value, choose that display number in the app and click **Verifica DDC/CI**. Only after the successful probe will the hardware slider become enabled. Move it slightly and confirm visually; some monitors acknowledge DDC commands but do not apply them. If hardware is unsupported, select **Software**, the correct macOS screen, and adjust the slider.

Do not use sudo, and do not guess an index when multiple monitors are connected. If USB-C is supplying both video and power, the Atlantis manual says brightness can reset to a low default on every USB-C reconnection.

### Limitations

- m1ddc is an **optional runtime dependency** for hardware mode; software mode is native and self-contained.
- Hardware writes are delayed by 350 ms during slider drags to avoid excessive DDC traffic.
- The app shows a command acknowledgment, not verified hardware brightness. Confirm real visual change before assuming support.
- The software dimming overlay is removed when you quit the app.
- Menu-bar UX is intentionally limited: no launch agents, global key hooks, network access, or privileges.

~~~bash
make test-displaypulse
make refresh-displaypulse
make uninstall-displaypulse
~~~
