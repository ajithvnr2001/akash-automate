#!/bin/bash
# ==============================================================================
# Bootstrap: Runs on Ubuntu container start inside the Akash pod.
# Automatically installs:
#   - Python 3, pip, venv
#   - Google Cloud CLI (gcloud, gsutil, bq)
#   - AWS CLI v2 (aws)
#   - Azure CLI (az)
#   - Oracle Cloud Infrastructure CLI (oci)
#   - Node.js LTS (v22) & npm
#   - AI Agent Tools: OpenCode (opencode), Claude Code (claude), Aider (aider)
#   - Common system utilities & build essentials
# ==============================================================================

set -euo pipefail

LOG="/var/log/bootstrap.log"
STAMP="/home/akash/.bootstrap-complete"
CONFIG_LOG="/home/akash/bootstrap.log"

log() {
  local msg="[bootstrap $(date -u +%H:%M:%S)] $*"
  echo "$msg"
}

# Redirect all stdout and stderr to the log file while echoing
exec > >(tee -a "$LOG" 2>/dev/null || cat >> "$LOG") 2>&1

log "=== Akash Ubuntu Bootstrap Started ==="
log "User: $(whoami) (uid=$(id -u))"
log "OS: $(grep -s PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"' || uname -a)"
log "CPUs: $(nproc 2>/dev/null || echo '?')"
log "Memory: $(free -h 2>/dev/null | awk '/Mem:/ {print $2}' || echo '?')"

# Idempotency check
if [ -f "$STAMP" ]; then
  log "Bootstrap was already completed on a prior boot. Exiting."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ------------------------------------------------------------------------------
# 1. Base System Packages & Build Essentials
# ------------------------------------------------------------------------------
log "[1/7] Updating apt repositories and installing base packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  curl \
  wget \
  gnupg \
  lsb-release \
  software-properties-common \
  build-essential \
  git \
  jq \
  unzip \
  zip \
  tar \
  gzip \
  rsync \
  htop \
  tmux \
  nano \
  vim \
  net-tools \
  iputils-ping \
  dnsutils

# ------------------------------------------------------------------------------
# 2. Python 3, pip, venv
# ------------------------------------------------------------------------------
log "[2/7] Installing Python 3, pip, and venv..."
apt-get install -y --no-install-recommends \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev \
  python-is-python3

python3 -m pip install --upgrade --no-cache-dir pip setuptools wheel

# ------------------------------------------------------------------------------
# 3. Google Cloud CLI (gcloud, gsutil, bq)
# ------------------------------------------------------------------------------
log "[3/7] Installing Google Cloud CLI (gcloud)..."
if ! command -v gcloud >/dev/null 2>&1; then
  mkdir -p /opt
  curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o /tmp/gcloud.tar.gz
  tar -xzf /tmp/gcloud.tar.gz -C /opt
  rm -f /tmp/gcloud.tar.gz
  /opt/google-cloud-sdk/install.sh --quiet --path-update false --command-completion false
  ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud
  ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil
  ln -sf /opt/google-cloud-sdk/bin/bq /usr/local/bin/bq
  log "Google Cloud CLI installed: $(gcloud --version 2>&1 | head -n 1)"
else
  log "Google Cloud CLI already present."
fi

# ------------------------------------------------------------------------------
# 4. AWS CLI v2
# ------------------------------------------------------------------------------
log "[4/7] Installing AWS CLI v2..."
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  unzip -qo /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
  log "AWS CLI installed: $(aws --version 2>&1)"
else
  log "AWS CLI already present."
fi

# ------------------------------------------------------------------------------
# 5. Azure CLI (az)
# ------------------------------------------------------------------------------
log "[5/7] Installing Azure CLI (az)..."
if ! command -v az >/dev/null 2>&1; then
  curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
  log "Azure CLI installed: $(az --version 2>&1 | head -n 1)"
else
  log "Azure CLI already present."
fi

# ------------------------------------------------------------------------------
# 6. Oracle Cloud Infrastructure CLI (oci)
# ------------------------------------------------------------------------------
log "[6/7] Installing Oracle Cloud Infrastructure CLI (oci)..."
if ! command -v oci >/dev/null 2>&1; then
  # Try pip first (clean and reliable on Ubuntu)
  python3 -m pip install --no-cache-dir oci-cli || {
    log "pip oci-cli install failed, trying official installer script..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- \
      --accept-all-defaults --install-dir /opt/oracle-cli --exec-dir /usr/local/bin
  }
  log "Oracle CLI installed: $(oci --version 2>&1 || echo 'installed')"
else
  log "Oracle CLI already present."
fi

# ------------------------------------------------------------------------------
# 7. Node.js LTS (v22), npm, and AI Agent Tools
# ------------------------------------------------------------------------------
log "[7/7] Installing Node.js LTS and AI agent tools..."
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs
  log "Node.js installed: $(node -v 2>&1) / npm: $(npm -v 2>&1)"
fi

log "Installing AI agent CLI tools (OpenCode, Claude Code, Aider)..."
# OpenCode AI CLI
npm install -g opencode-ai || log "WARN: opencode-ai npm install had warnings"

# --- OpenCode Supabase Session Sync Tool ---
log "Installing Supabase OpenCode session synchronization utility..."
cat <<'SYNC_EOF' > /usr/local/bin/opencode-sync
#!/usr/bin/env python3
"""
opencode-sync: Transparent Supabase Database & Session Migration for OpenCode
Automatically persists and restores OpenCode SQLite sessions via Supabase PostgREST.
Supports high-efficiency gzip compression and automatic session metadata parsing.
"""

import os
import sys
import json
import time
import gzip
import base64
import sqlite3
import shutil
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ------------------------------------------------------------------------------
# Environment Resolution
# ------------------------------------------------------------------------------
def load_env_file(path):
    env = {}
    if not os.path.exists(path):
        return env
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip()
                    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                        v = v[1:-1]
                    env[k] = v
    except Exception:
        pass
    return env

def get_env_vars():
    # Priority: os.environ > /config/.agent-env > /root/.agent-env > /home/akash/.agent-env > /etc/opencode-supabase.env > .env
    merged = {}
    for p in [
        "/etc/opencode-supabase.env",
        "/home/akash/.agent-env",
        "/root/.agent-env",
        "/config/.agent-env",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"),
        os.path.join(os.getcwd(), ".env"),
    ]:
        merged.update(load_env_file(p))
    for k, v in os.environ.items():
        if v:
            merged[k] = v
    return merged

ENV = get_env_vars()
SUPABASE_URL = ENV.get("SUPABASE_URL", "").rstrip("/")
SUPABASE_KEY = ENV.get("SUPABASE_KEY") or ENV.get("SUPABASE_SERVICE_ROLE_KEY") or ENV.get("SUPABASE_ANON_KEY", "")
DEFAULT_SESSION_ID = ENV.get("OPENCODE_SESSION_ID", "default")

def get_db_paths():
    paths = []
    # 1. User XDG path
    xdg_data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    paths.append(os.path.join(xdg_data, "opencode", "opencode.db"))
    # 2. Standard system locations
    paths.append("/root/.local/share/opencode/opencode.db")
    paths.append("/home/akash/.local/share/opencode/opencode.db")
    # De-duplicate preserving order
    seen = set()
    result = []
    for p in paths:
        norm = os.path.normpath(p)
        if norm not in seen:
            seen.add(norm)
            result.append(norm)
    return result

def get_headers():
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates"
    }

# ------------------------------------------------------------------------------
# Core Actions: PUSH, PULL, STATUS, WATCH
# ------------------------------------------------------------------------------
OPENCODE_MIGRATIONS = [
    '20260127222353_familiar_lady_ursula',
    '20260211171708_add_project_commands',
    '20260213144116_wakeful_the_professor',
    '20260225215848_workspace',
    '20260227213759_add_session_workspace_id',
    '20260228203230_blue_harpoon',
    '20260303231226_add_workspace_fields',
    '20260309230000_move_org_to_state',
    '20260312043431_session_message_cursor',
    '20260323234822_events',
    '20260410174513_workspace-name',
    '20260413175956_chief_energizer',
    '20260423070820_add_icon_url_override',
    '20260427172553_slow_nightmare',
    '20260428004200_add_session_path',
    '20260501142318_next_venus',
    '20260504145000_add_sync_owner',
    '20260507164347_add_workspace_time',
    '20260510033149_session_usage',
    '20260511000411_data_migration_state',
    '20260511173437_session-metadata',
    '20260601010001_normalize_storage_paths',
    '20260601202201_amazing_prowler',
    '20260602002951_lowly_union_jack',
    '20260602182828_add_project_directories',
    '20260603001617_session_message_projection_indexes',
    '20260603040000_session_message_projection_order',
    '20260603141458_session_input_inbox',
    '20260603160727_jittery_ezekiel_stane',
    '20260604172448_event_sourced_session_input',
    '20260605003541_add_session_context_snapshot',
    '20260605042240_add_context_epoch_agent',
    '20260611035744_credential',
    '20260611192811_lush_chimera',
    '20260612174303_project_dir_strategy',
    '20260622142730_simplify_session_context_epoch',
    '20260622170816_reset_v2_session_state',
    '20260622202450_simplify_session_input'
]

def _ensure_migrations(db_path):
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL)")
        cur.execute("SELECT id FROM migration")
        existing = {r[0] for r in cur.fetchall()}
        now_ms = int(time.time() * 1000)
        for m in OPENCODE_MIGRATIONS:
            if m not in existing:
                cur.execute("INSERT OR REPLACE INTO migration (id, time_completed) VALUES (?, ?)", (m, now_ms))
        conn.commit()
        conn.close()
    except Exception:
        pass

def pull(session_id=None):
    session_id = session_id or DEFAULT_SESSION_ID
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("[opencode-sync] WARN: SUPABASE_URL or SUPABASE_KEY not configured. Skipping pull.")
        return 1

    url = f"{SUPABASE_URL}/rest/v1/opencode_sessions?id=eq.{session_id}&select=*"
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}"
    }
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
            if not rows:
                print(f"[opencode-sync] No existing session found in Supabase for id '{session_id}'. Ready for new session.")
                return 0
            row = rows[0]
            b64_data = row.get("db_backup_b64")
            if not b64_data:
                print(f"[opencode-sync] Remote session record '{session_id}' has no backup data.")
                return 0

            raw_bytes = base64.b64decode(b64_data)
            # Check for gzip compression header (0x1f, 0x8b)
            if raw_bytes.startswith(b"\x1f\x8b"):
                db_bytes = gzip.decompress(raw_bytes)
                print(f"[opencode-sync] Decompressed {len(raw_bytes):,d} compressed bytes -> {len(db_bytes):,d} DB bytes")
            else:
                db_bytes = raw_bytes

            updated_at = row.get("updated_at", "unknown")
            session_name = row.get("session_name", session_id)

            # Write to all applicable paths
            targets = get_db_paths()
            for t in targets:
                # If target is /home/akash and directory exists or /home/akash exists
                if "/home/akash" in t and not os.path.exists("/home/akash"):
                    continue
                os.makedirs(os.path.dirname(t), exist_ok=True)
                with open(t, "wb") as f:
                    f.write(db_bytes)
                _ensure_migrations(t)
                # Fix ownership if writing to /home/akash
                if "/home/akash" in t:
                    try:
                        shutil.chown(t, user="akash", group="akash")
                        shutil.chown(os.path.dirname(t), user="akash", group="akash")
                    except Exception:
                        pass
                print(f"[opencode-sync] Restored OpenCode DB ({len(db_bytes):,d} bytes) -> {t}")

            print(f"[opencode-sync] SUCCESS: Restored session '{session_id}' ('{session_name}'). Last updated: {updated_at}")
            return 0
    except urllib.error.HTTPError as e:
        print(f"[opencode-sync] ERROR: Supabase HTTP {e.code}: {e.read().decode('utf-8', errors='ignore')}")
        return 1
    except Exception as e:
        print(f"[opencode-sync] ERROR: Failed to pull from Supabase: {e}")
        return 1

def push(session_id=None, session_name=None):
    session_id = session_id or DEFAULT_SESSION_ID
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("[opencode-sync] WARN: SUPABASE_URL or SUPABASE_KEY not configured. Skipping push.")
        return 1

    # Find the newest local opencode.db
    source_db = None
    newest_mtime = 0
    for p in get_db_paths():
        if os.path.exists(p):
            mtime = os.path.getmtime(p)
            if mtime > newest_mtime:
                newest_mtime = mtime
                source_db = p

    if not source_db:
        print("[opencode-sync] No local OpenCode database found to push.")
        return 0

    with open(source_db, "rb") as f:
        db_bytes = f.read()

    # Compress with gzip for high performance
    compressed_bytes = gzip.compress(db_bytes, compresslevel=6)
    b64_data = base64.b64encode(compressed_bytes).decode("ascii")

    # Extract statistics and session list from SQLite
    stats = {
        "raw_size_bytes": len(db_bytes),
        "compressed_size_bytes": len(compressed_bytes),
        "source_path": source_db,
        "tables": [],
        "sessions": [],
        "session_count": 0,
        "message_count": 0
    }
    extracted_title = session_name
    try:
        conn = sqlite3.connect(source_db)
        cur = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [row[0] for row in cur.fetchall()]
        stats["tables"] = tables

        # Try to read session table
        for st in ["session", "sessions"]:
            if st in tables:
                cur.execute(f"SELECT COUNT(*) FROM {st}")
                stats["session_count"] = cur.fetchone()[0]
                try:
                    cur.execute(f"SELECT * FROM {st} ORDER BY 1 DESC LIMIT 10")
                    col_names = [d[0] for d in cur.description]
                    sess_rows = []
                    for row in cur.fetchall():
                        sess_dict = dict(zip(col_names, row))
                        sess_rows.append(sess_dict)
                        if not extracted_title and "title" in sess_dict and sess_dict["title"]:
                            extracted_title = sess_dict["title"]
                    stats["sessions"] = sess_rows
                except Exception:
                    pass
                break

        # Try to read messages count
        for mt in ["message", "messages"]:
            if mt in tables:
                cur.execute(f"SELECT COUNT(*) FROM {mt}")
                stats["message_count"] = cur.fetchone()[0]
                break

        conn.close()
    except Exception as e:
        stats["db_inspect_error"] = str(e)

    final_session_name = extracted_title or session_name or f"OpenCode Session ({session_id})"

    payload = {
        "id": session_id,
        "session_name": final_session_name,
        "data": stats,
        "db_backup_b64": b64_data,
        "updated_at": datetime.now(timezone.utc).isoformat()
    }

    url = f"{SUPABASE_URL}/rest/v1/opencode_sessions"
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=get_headers(),
        method="POST"
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"[opencode-sync] SUCCESS: Synced {len(db_bytes):,d} bytes (compressed: {len(compressed_bytes):,d} bytes) to Supabase session '{session_id}' (HTTP {resp.status})")
            print(f"[opencode-sync] Stats: {stats.get('session_count', 0)} session(s), {stats.get('message_count', 0)} message(s)")
            return 0
    except urllib.error.HTTPError as e:
        print(f"[opencode-sync] ERROR: Supabase HTTP {e.code}: {e.read().decode('utf-8', errors='ignore')}")
        return 1
    except Exception as e:
        print(f"[opencode-sync] ERROR: Failed to push to Supabase: {e}")
        return 1

def status():
    print("================== OPENCODE SYNC STATUS ==================")
    print(f"Supabase URL       : {SUPABASE_URL or '<not configured>'}")
    print(f"Supabase Key       : {'[configured]' if SUPABASE_KEY else '<missing>'}")
    print(f"Default Session ID : {DEFAULT_SESSION_ID}")
    print("-------------------- Local Databases ---------------------")
    found_any = False
    for p in get_db_paths():
        if os.path.exists(p):
            found_any = True
            sz = os.path.getsize(p)
            mtime = datetime.fromtimestamp(os.path.getmtime(p), tz=timezone.utc).isoformat()
            print(f"Path   : {p}")
            print(f"Size   : {sz:,d} bytes")
            print(f"MTime  : {mtime}")
            try:
                conn = sqlite3.connect(p)
                cur = conn.cursor()
                cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
                tables = [r[0] for r in cur.fetchall()]
                print(f"Tables : {', '.join(tables)}")
                for st in ["session", "sessions"]:
                    if st in tables:
                        cur.execute(f"SELECT COUNT(*) FROM {st}")
                        print(f"Sessions: {cur.fetchone()[0]}")
                for mt in ["message", "messages"]:
                    if mt in tables:
                        cur.execute(f"SELECT COUNT(*) FROM {mt}")
                        print(f"Messages: {cur.fetchone()[0]}")
                conn.close()
            except Exception as e:
                print(f"Read error: {e}")
    if not found_any:
        print("No local OpenCode databases found.")

    print("-------------------- Supabase Remote ---------------------")
    if SUPABASE_URL and SUPABASE_KEY:
        url = f"{SUPABASE_URL}/rest/v1/opencode_sessions?id=eq.{DEFAULT_SESSION_ID}&select=id,session_name,updated_at,data"
        headers = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}"}
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req) as resp:
                rows = json.loads(resp.read().decode("utf-8"))
                if rows:
                    r = rows[0]
                    print(f"Remote ID       : {r.get('id')}")
                    print(f"Session Name    : {r.get('session_name')}")
                    print(f"Last Remote Sync: {r.get('updated_at')}")
                    rdata = r.get("data") or {}
                    print(f"Remote Sessions : {rdata.get('session_count', 'unknown')}")
                    print(f"Remote Messages : {rdata.get('message_count', 'unknown')}")
                else:
                    print("No remote record exists yet for this session ID.")
        except Exception as e:
            print(f"Failed to fetch remote status: {e}")
    else:
        print("Remote check skipped (credentials missing).")
    print("==========================================================")
    return 0

def watch(session_id=None, interval=5):
    session_id = session_id or DEFAULT_SESSION_ID
    print(f"[opencode-sync] Watching local OpenCode DB for changes every {interval}s (Session: {session_id})...")
    last_mtime = 0
    while True:
        try:
            for p in get_db_paths():
                if os.path.exists(p):
                    m = os.path.getmtime(p)
                    if m > last_mtime:
                        if last_mtime != 0:
                            print(f"[opencode-sync] Detected change in {p}. Syncing to Supabase...")
                            time.sleep(1) # Let write finish
                            push(session_id=session_id)
                        last_mtime = m
                        break
            time.sleep(interval)
        except KeyboardInterrupt:
            print("\n[opencode-sync] Watcher stopped.")
            break
        except Exception as e:
            time.sleep(interval)

# ------------------------------------------------------------------------------
# CLI Entrypoint
# ------------------------------------------------------------------------------
def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    arg1 = sys.argv[2] if len(sys.argv) > 2 else None
    arg2 = sys.argv[3] if len(sys.argv) > 3 else None

    if cmd == "pull":
        sys.exit(pull(session_id=arg1))
    elif cmd == "push":
        sys.exit(push(session_id=arg1, session_name=arg2))
    elif cmd == "status":
        sys.exit(status())
    elif cmd == "watch":
        interval = int(arg2) if arg2 and arg2.isdigit() else 5
        sys.exit(watch(session_id=arg1, interval=interval))
    else:
        print("Usage: opencode-sync [pull|push|status|watch] [session_id] [session_name]")
        sys.exit(1)

if __name__ == "__main__":
    main()

SYNC_EOF
chmod +x /usr/local/bin/opencode-sync

# Transparent OpenCode wrapper with Supabase auto-restore and auto-persist
REAL_BIN=$(readlink -f /usr/lib/node_modules/opencode-ai/bin/opencode.exe 2>/dev/null || which opencode 2>/dev/null || true)
if [ ! -f "$REAL_BIN" ]; then
  REAL_BIN="/usr/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64/bin/opencode"
fi

if [ -f "$REAL_BIN" ]; then
  ln -sf "$REAL_BIN" /usr/local/bin/opencode-bin
  cat <<'WRAPPER_EOF' > /usr/local/bin/opencode
#!/bin/bash
# Transparent OpenCode wrapper with automated Supabase session sync

[ -f /config/.agent-env ] && . /config/.agent-env 2>/dev/null || true
[ -f /root/.agent-env ] && . /root/.agent-env 2>/dev/null || true
[ -f /home/akash/.agent-env ] && . /home/akash/.agent-env 2>/dev/null || true
[ -f /etc/opencode-supabase.env ] && . /etc/opencode-supabase.env 2>/dev/null || true

# 1. Pull latest session DB from Supabase before launch (silent for clean TUI)
if command -v opencode-sync >/dev/null 2>&1; then
  opencode-sync pull >/dev/null 2>&1 || true
fi

# 2. Start background sync watcher for ongoing chats
WATCHER_PID=""
if command -v opencode-sync >/dev/null 2>&1; then
  opencode-sync watch >/dev/null 2>&1 &
  WATCHER_PID=$!
fi

# 3. Execute real OpenCode with all arguments
/usr/local/bin/opencode-bin "$@"
EXIT_CODE=$?

# 4. Stop watcher and push final state to Supabase
if [ -n "$WATCHER_PID" ]; then
  kill "$WATCHER_PID" 2>/dev/null || true
fi
if command -v opencode-sync >/dev/null 2>&1; then
  opencode-sync push >/dev/null 2>&1 || true
fi

exit $EXIT_CODE
WRAPPER_EOF
  chmod +x /usr/local/bin/opencode
  log "Configured transparent Supabase wrapper for OpenCode."
fi


# Claude Code CLI
npm install -g @anthropic-ai/claude-code || log "WARN: claude-code npm install had warnings"

# Aider AI coding assistant
python3 -m pip install --no-cache-dir aider-chat || log "WARN: aider pip install had warnings"

# ------------------------------------------------------------------------------
# System environment & helper commands
# ------------------------------------------------------------------------------
log "Setting up system PATH and convenience utilities..."

cat <<'EOF' > /etc/profile.d/akash-env.sh
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/google-cloud-sdk/bin:$PATH"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
EOF
chmod +x /etc/profile.d/akash-env.sh

# vm-info utility
cat <<'EOF' > /usr/local/bin/vm-info
#!/bin/bash
echo "==================== VM INFO ===================="
echo "Host     : $(hostname)"
echo "OS       : $(grep -s PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"' || uname -a)"
echo "User     : $(id -un) (uid=$(id -u))"
echo "CPUs     : $(nproc 2>/dev/null || echo '?')"
echo "Memory   : $(free -h 2>/dev/null | awk '/Mem:/ {print $2}')"
echo "Disk     : $(df -h / | awk 'NR==2 {print $2 " total, " $4 " available"}')"
echo "================ Installed CLIs ================"
for cmd in gcloud aws az oci python3 pip node npm opencode opencode-sync claude aider; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ver=$("$cmd" --version 2>&1 | head -n 1)
    printf "  %-12s : %s\n" "$cmd" "$ver"
  else
    printf "  %-12s : not found\n" "$cmd"
  fi
done
echo "================================================"
EOF
chmod +x /usr/local/bin/vm-info

# agent-env utility to load API keys
cat <<'EOF' > /usr/local/bin/agent-env
#!/bin/bash
# Source environment files if they exist
[ -f /home/akash/.agent-env ] && . /home/akash/.agent-env
[ -f /root/.agent-env ] && . /root/.agent-env
echo "Agent environment loaded."
EOF
chmod +x /usr/local/bin/agent-env

# Ensure akash user owns their home directory and copy logs
if id -u akash >/dev/null 2>&1; then
  cp "$LOG" "$CONFIG_LOG" 2>/dev/null || true
  chown -R akash:akash /home/akash 2>/dev/null || true
fi


# Auto-restore OpenCode sessions from Supabase if credentials exist
if [ -f /etc/opencode-supabase.env ] || [ -f /config/.agent-env ] || [ -f /root/.agent-env ]; then
  log "Supabase credentials detected, restoring OpenCode sessions..."
  opencode-sync pull || log "Initial opencode-sync pull completed or no prior session"
fi

touch "$STAMP"
log "=== Akash Ubuntu Bootstrap Complete ==="
exit 0
