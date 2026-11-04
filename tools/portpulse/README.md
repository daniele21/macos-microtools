# PortPulse

Small native, **menu-bar-only** TCP listening-port monitor for macOS 13+.
No Dock icon, cloud connection, root helper, third-party packages or telemetry.
Lives alongside MenuMeter, RunnerPulse and DisplayPulse.

## Quick start

~~~sh
make test-portpulse
make install-portpulse
open "$HOME/.local/opt/PortPulse.app"
make enable-portpulse-login
~~~

The opt-in login command installs a per-user LaunchAgent to open the app at login.
Check with **make status-portpulse-login** or disable with **make disable-portpulse-login**.
Rebuild/restart with **make refresh-portpulse**. Uninstall with **make uninstall-portpulse**.

## Popover UX (v0.2–v0.3)

The native macOS appearance follows light/dark mode and uses a compact three-part
summary (**Totali**, **Locali**, **Rete**), a segmented scope filter, and a subtle
process/port/PID search. Results use cards with monospaced port numbers, secondary
bind/PID details, visible status labels and an expandable information/actions area.
The scroll position and selected row are preserved across unchanged five-second
scans. The count is based on unique port numbers, not lsof listener rows:
a port with local *and* network bindings is counted once in **Rete**.

The network indicator is **non-loopback**, not evidence of Internet exposure.
## v0.3 — Origine del servizio, senza rumore

La lista mantiene solo porta, servizio e stato. Aprendo una riga, PortPulse
recupera **su richiesta** (mai nel polling di 5 secondi) il titolo del
processo con \`ps\` e la cartella di lavoro con \`lsof -d cwd\`.
Se trova una directory \`.git\` risale al progetto Git; per le cartelle
di sviluppo sotto \`~/Projects\`, \`~/Personal\`, \`~/Code\` o \`~/Developer\`
può mostrare il nome della cartella senza inventare un repository Git.

Una riga espansa mostra soltanto **nome progetto**, **PID**, **tempo
di attività**, **indirizzo** e al massimo due azioni:
\`Apri progetto\` (Finder) e \`Termina…\` (SIGTERM previa conferma).
Niente UID, librerie, comando completo, pulsante copia o apri HTTP.
Se macOS non consente di leggere la cartella o il comando, il valore
mancante resta semplicemente nascosto. I dettagli vivono solo in memoria,
con cache di 60 secondi, e vengono cancellati al riavvio.

## v0.4 — Gruppi di porte per servizio

La vista è **raggruppata per servizio** per impostazione predefinita.
Disattiva **Raggruppa per servizio** per tornare alla lista individuale.
Il raggruppamento avviene sul nome reale del processo rilevato da lsof,
senza lookup pesanti nel refresh. Le applicazioni runtime generiche come
\`node\`, \`python\`, \`java\` non vengono unite fra PID diversi: possono
appartenere a progetti differenti. Le porte IPv4/IPv6 duplicate vengono
contate una volta sola. I gruppi con una sola porta continuano ad avere
l'interfaccia individuale.

Espandendo un gruppo, ad esempio **llama-server · 5 porte · 5 processi**,
vedi i PID delle singole porte e il pulsante **Termina gruppo…**.
L'azione è disponibile solo se TUTTI i processi appartengono all'utente
corrente, non sono PortPulse né servizi macOS protetti. Richiede una
conferma esplicita che riporta porte e numero di processi; **Annulla**
è l'azione predefinita.

Prima di inviare alcun segnale, PortPulse ripete la scansione e controlla
che TUTTI i listener selezionati siano ancora presenti, senza cambiamenti
di PID, proprietario, porta, indirizzo o membri del gruppo. Se cambia
qualcosa, **non interrompe nessuno**. In caso di verifica riuscita invia
un solo **SIGTERM per PID distinto**: non usa mai sudo o SIGKILL e non
interpreta l'invio come prova dell'effettiva chiusura. Un processo può
esporre anche altre porte oltre quelle visualizzate e i processi
supervisionati possono riavviarsi.

## Menu bar

The **network symbol + listener count** is visible while the app is running.
Open the popover for TCP listeners with port, command, PID, bind address and UID,
plus instant search and localhost/network filters. Select a row to inspect its process origin
or request a controlled shutdown. Scans run on a background queue every five seconds.

An orange icon means at least one **non-loopback listener**. This is **not** proof
of exposure to the Internet: firewall, NAT, routing and authentication determine
actual reachability. The first scan establishes a baseline; newly observed
non-local listeners are highlighted in the popover. No OS notification permission
is requested.

The monitor calls **/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcun**.
This deliberately covers TCP listeners, not UDP or a firewall rules manager.
Process visibility may be incomplete without privileges; an empty list does not
prove the system has no listeners.

## Safe stop behavior

Select an entry and click **Arresta…**. Only entries with a verified UID matching
the current user and a PID other than 1 or PortPulse itself are eligible.
A confirmation alert names the exact process and address.
Before acting, PortPulse rescans and checks the same PID, command, UID, address,
and port are still present, then sends **SIGTERM** directly via kill(2).
No shell, sudo or automatic SIGKILL is involved. A very small PID-recycling
race can still exist between final verification and kill(2).
Processes supervised by launchd may restart automatically.

## Testing

~~~sh
make test-portpulse
plutil -lint bin/PortPulse.app/Contents/Info.plist
~~~

The GitHub Actions workflow compiles on macOS and runs the parser, exposure
classification, safe-stop eligibility and new-listener detection tests.

## Troubleshooting

If lsof fails, the menu bar shows **!** rather than a misleading zero.
Compare with: **lsof -nP -iTCP -sTCP:LISTEN** from Terminal.
