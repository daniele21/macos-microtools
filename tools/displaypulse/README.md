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

### App icon: monitor + sole

The Finder app icon uses the selected monitor-and-sun artwork (dark blue rounded square,
silver display, golden rising sun). A small WebP derivative is committed to the repo;
the native build generates a standard Retina `DisplayPulse.icns` with
`sips` + `iconutil` and embeds it under `Contents/Resources`.

For the exact full-resolution artwork, download `DisplayPulse.icns` from the
conversation and supply it once when installing:

~~~bash
DISPLAYPULSE_ICON_SOURCE="$HOME/Downloads/DisplayPulse.icns" make refresh-displaypulse
~~~

Or supply the original 1024px PNG instead. Without this override, the bundled
derivative is used automatically. The macOS **menu-bar icon stays a monochrome
SF Symbol**, so it adapts to light/dark appearance. No network fetch or
login-settings change is involved.

## Avvio automatico al login (opzionale)

Attiva **una sola volta**, dal tuo Mac con la sessione utente grafica aperta:

~~~bash
make enable-displaypulse-login
~~~

La procedura installa l'app in `~/.local/opt/DisplayPulse.app` e crea **solo** il LaunchAgent utente
`~/Library/LaunchAgents/com.daniele.displaypulse.plist`. Quando esegui il login a macOS,
`launchd` lancia `/usr/bin/open -g -a ~/.local/opt/DisplayPulse.app`.
Non serve lasciare aperto il Terminale; non serve `sudo`. Il LaunchAgent esegue solo
l'apertura dell'app, **non** un servizio che rimane attivo.

~~~bash
make status-displaypulse-login    # Stato del LaunchAgent
make disable-displaypulse-login   # Disabilita l'avvio automatico senza chiudere l'app
make refresh-displaypulse         # Ricompila e riapre la versione corrente
~~~

`make install-displaypulse` installa l'app ma **non** abilita automaticamente il login item.
`make uninstall-displaypulse` disabilita anche l'avvio automatico. Durante il login
l'app parte senza modificare la luminosità: l'eventuale oscuramento software non è
ripristinato in automatico e non vengono inviati comandi DDC/CI.

Se macOS blocca il LaunchAgent, controlla **Impostazioni di Sistema → Generali → Elementi login ed estensioni**.
Per test automatizzati, `make test-displaypulse` esegue solo una verifica non invasiva
della configurazione XML: non installa e non attiva agenti di login.

## Check if DDC/CI works

~~~bash
brew install m1ddc
m1ddc display list detailed
# Select the correct Atlantis number, e.g. 1:
m1ddc display 1 get luminance
m1ddc display 1 max luminance
# Or use DisplayPulse's read-only CLI probe after building:
"$HOME/.local/opt/DisplayPulse.app/Contents/MacOS/DisplayPulse" --probe 1
~~~

A numeric **current value alone is not proof of DDC support**: the upstream m1ddc parser may interpret empty I2C response bytes as 0. First check **both** `get luminance` and `max luminance`. If the maximum is 0, missing, or incoherent, do not enable hardware mode. The app now rejects this case instead of inventing a default maximum.

If you get a current value and a **positive, coherent maximum**, choose that display number in the app and click **Verifica DDC/CI**. Only after the successful probe will the hardware slider become enabled. Move it slightly and confirm visually; some monitors acknowledge DDC commands but do not apply them. If hardware is unsupported, select **Software**, the correct macOS screen, and adjust the slider.

Do not use sudo, and do not guess an index when multiple monitors are connected. If USB-C is supplying both video and power, the Atlantis manual says brightness can reset to a low default on every USB-C reconnection.

### Limitations

- m1ddc is an **optional runtime dependency** for hardware mode; software mode is native and self-contained.
- Hardware writes are delayed by 350 ms during slider drags to avoid excessive DDC traffic.
- The app shows a command acknowledgment, not verified hardware brightness. Confirm real visual change before assuming support.
- The software dimming overlay is removed when you quit the app.
- Menu-bar UX is intentionally limited: optional login-only LaunchAgent, no global key hooks, no network access, no privileges.

~~~bash
make test-displaypulse
make refresh-displaypulse
make uninstall-displaypulse
~~~
