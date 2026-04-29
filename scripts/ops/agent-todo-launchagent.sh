#!/usr/bin/env bash
set -euo pipefail

LABEL="com.r3dbars.transcripted.agent-todo-runner"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/ops/agent-todo-runner.rb"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/TranscriptedAgentTodoRunner"
OUT_LOG="$LOG_DIR/stdout.log"
ERR_LOG="$LOG_DIR/stderr.log"
DOMAIN="gui/$(id -u)"

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

write_plist() {
  local escaped_repo_root escaped_runner escaped_home
  escaped_repo_root="$(printf '%s' "$REPO_ROOT" | xml_escape)"
  escaped_runner="$(printf '%s' "$RUNNER" | xml_escape)"
  escaped_home="$(printf '%s' "$HOME" | xml_escape)"

  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string>
    <string>$escaped_runner</string>
    <string>--watch</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$escaped_repo_root</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$OUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$ERR_LOG</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$escaped_home</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST
}

install_agent() {
  ruby "$RUNNER" --labels-only
  write_plist
  launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "Installed and started $LABEL"
  echo "Logs: $LOG_DIR"
}

uninstall_agent() {
  launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "Uninstalled $LABEL"
}

status_agent() {
  launchctl print "$DOMAIN/$LABEL"
}

logs_agent() {
  echo "== stdout =="
  tail -n 80 "$OUT_LOG" 2>/dev/null || true
  echo "== stderr =="
  tail -n 80 "$ERR_LOG" 2>/dev/null || true
}

case "${1:-install}" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  restart)
    uninstall_agent
    install_agent
    ;;
  status)
    status_agent
    ;;
  logs)
    logs_agent
    ;;
  *)
    echo "Usage: $0 [install|uninstall|restart|status|logs]" >&2
    exit 64
    ;;
esac
