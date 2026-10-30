# TerminalClip (optional): metadata for last completed foreground Zsh command.
# Privacy: commands might include secrets. Never enabled by default.
if [[ -o interactive && -n "$TTY" && -z "$_TERMINALCLIP_HOOKS_LOADED" ]]; then
  typeset -g _TERMINALCLIP_HOOKS_LOADED=1
  zmodload zsh/datetime 2>/dev/null
  autoload -Uz add-zsh-hook

  _terminalclip_preexec() {
    typeset -g _TERMINALCLIP_COMMAND="$1"
    typeset -g _TERMINALCLIP_DIRECTORY="$PWD"
    typeset -g _TERMINALCLIP_START="$EPOCHREALTIME"
  }

  _terminalclip_precmd() {
    local status=$?
    [[ -n "$_TERMINALCLIP_COMMAND" ]] || return 0
    local ttyname="$TTY:t"
    if [[ ! "$ttyname" =~ '^[A-Za-z0-9_-]+$' ]]; then
      unset _TERMINALCLIP_COMMAND
      return 0
    fi
    local elapsed=0
    if [[ -n "$_TERMINALCLIP_START" && -n "$EPOCHREALTIME" ]]; then
      elapsed=$(( EPOCHREALTIME - _TERMINALCLIP_START ))
    fi
    local dir="$HOME/Library/Application Support/TerminalClip/state"
    local target="$dir/$ttyname.dat"
    local temp="$dir/.$ttyname.$$.tmp"
    (
      umask 077
      command mkdir -p -m 700 "$dir" || exit 0
      builtin printf '%s\0' "$TTY" "$_TERMINALCLIP_DIRECTORY" "$_TERMINALCLIP_COMMAND" \
        "$status" "$elapsed" "$EPOCHSECONDS" > "$temp" &&
        command mv -f "$temp" "$target"
    ) 2>/dev/null
    unset _TERMINALCLIP_COMMAND _TERMINALCLIP_DIRECTORY _TERMINALCLIP_START
    return 0
  }

  if [[ "$TTY:t" =~ '^[A-Za-z0-9_-]+$' ]]; then
    command rm -f "$HOME/Library/Application Support/TerminalClip/state/$TTY:t.dat" 2>/dev/null
  fi
  _terminalclip_zshexit() {
    if [[ "$TTY:t" =~ '^[A-Za-z0-9_-]+$' ]]; then
      command rm -f "$HOME/Library/Application Support/TerminalClip/state/$TTY:t.dat" 2>/dev/null
    fi
  }

  add-zsh-hook preexec _terminalclip_preexec
  add-zsh-hook precmd _terminalclip_precmd
  add-zsh-hook zshexit _terminalclip_zshexit
fi
