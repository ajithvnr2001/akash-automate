#!/bin/bash
# Transparent OpenCode wrapper with automated Supabase session sync

[ -f /config/.agent-env ] && . /config/.agent-env 2>/dev/null || true
[ -f /root/.agent-env ] && . /root/.agent-env 2>/dev/null || true
[ -f /home/akash/.agent-env ] && . /home/akash/.agent-env 2>/dev/null || true
[ -f /etc/opencode-supabase.env ] && . /etc/opencode-supabase.env 2>/dev/null || true

# 1. Pull from Supabase ONLY if no local DB exists yet (first boot safety)
if command -v opencode-sync >/dev/null 2>&1; then
  if [ ! -f /root/.local/share/opencode/opencode.db ] && [ ! -f /home/akash/.local/share/opencode/opencode.db ]; then
    opencode-sync pull >/dev/null 2>&1 || true
  fi
fi

# 2. Start background sync watcher if not already running
if command -v opencode-sync >/dev/null 2>&1; then
  if ! pgrep -f "opencode-sync watch" >/dev/null 2>&1; then
    nohup opencode-sync watch > /tmp/opencode-sync.log 2>&1 &
  fi
fi

# 3. Execute real OpenCode with all arguments
/usr/local/bin/opencode-bin "$@"
EXIT_CODE=$?

# 4. Checkpoint WAL and push final state to Supabase on exit
if command -v opencode-sync >/dev/null 2>&1; then
  opencode-sync push >/dev/null 2>&1 || true
fi

exit $EXIT_CODE
