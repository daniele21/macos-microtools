#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/.config/terminalclip"
RC="$HOME/.zshrc"
mkdir -p "$DIR"
chmod 700 "$DIR"
install -m 600 "$ROOT/terminalclip.zsh" "$DIR/terminalclip.zsh"
LINE='[[ -f "$HOME/.config/terminalclip/terminalclip.zsh" ]] && source "$HOME/.config/terminalclip/terminalclip.zsh"'
touch "$RC"
if ! grep -Fqx "$LINE" "$RC"; then
  printf '\n# TerminalClip: optional Zsh metadata (stores last command locally)\n%s\n' "$LINE" >> "$RC"
fi
echo "Zsh hook abilitato; apri un nuovo tab Terminal.app."
echo "Privacy: i comandi possono contenere password/token. Metadati salvati solo in locale."
