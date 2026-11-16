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
  less \
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
opencode-sync: Transparent Supabase Database and Session Migration for OpenCode
Supports WAL checkpointing, SQLite atomic backup, and live real-time sync.
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
    xdg_data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    paths.append(os.path.join(xdg_data, "opencode", "opencode.db"))
    paths.append("/root/.local/share/opencode/opencode.db")
    paths.append("/home/akash/.local/share/opencode/opencode.db")
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
        "Prefer": "return=representation,resolution=merge-duplicates"
    }

def _ensure_migrations(db_path):
    all_migrations = [
        "1_initial", "2_subtask", "3_session_summary", "4_session_share",
        "5_session_share_url", "6_session_context", "7_session_permission",
        "8_agent_directory", "9_project_directory", "10_session_view",
        "11_session_view_mode", "12_model_variant", "13_agent_mode",
        "14_session_index", "15_project_icon", "16_part_time", "17_session_cost",
        "18_session_tokens", "19_session_parent", "20_event_seq", "21_message_time",
        "22_permission_type", "23_session_starred", "24_session_pinned",
        "25_session_title_index", "26_message_summary", "27_agent_color",
        "28_account", "29_agent_default", "30_session_input", "31_part_index",
        "32_message_index", "33_todo", "34_permission_index", "35_credential",
        "36_project_archived", "37_agent_prompt", "38_session_tags"
    ]
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        cur = conn.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS migration (id TEXT PRIMARY KEY, time_created INTEGER)")
        cur.execute("SELECT id FROM migration")
        existing = {r[0] for r in cur.fetchall()}
        now_ms = int(time.time() * 1000)
        for m in all_migrations:
            if m not in existing:
                cur.execute("INSERT OR IGNORE INTO migration (id, time_created) VALUES (?, ?)", (m, now_ms))
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"[opencode-sync] Migration seed note: {e}")

def snapshot_db(source_db):
    snap_path = f"{source_db}.snap_{os.getpid()}_{int(time.time()*1000)}"
    try:
        conn = sqlite3.connect(source_db, timeout=15)
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except Exception:
            try:
                conn.execute("PRAGMA wal_checkpoint(FULL)")
            except Exception:
                pass
        bck = sqlite3.connect(snap_path)
        conn.backup(bck)
        bck.close()
        conn.close()
        with open(snap_path, "rb") as f:
            data = f.read()
        return data
    finally:
        if os.path.exists(snap_path):
            try:
                os.remove(snap_path)
            except Exception:
                pass

def pull(session_id=None):
    session_id = session_id or DEFAULT_SESSION_ID
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("[opencode-sync] WARN: SUPABASE_URL or SUPABASE_KEY not configured. Skipping pull.")
        return 1

    url = f"{SUPABASE_URL}/rest/v1/opencode_sessions?id=eq.{session_id}&select=*"
    req = urllib.request.Request(url, headers={"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}"}, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if not data:
                print(f"[opencode-sync] No remote session found for '{session_id}'.")
                return 0
            row = data[0]
            b64_data = row.get("data", {}).get("db_base64", "")
            if not b64_data:
                print(f"[opencode-sync] Remote session '{session_id}' has no database payload.")
                return 0

            raw_bytes = base64.b64decode(b64_data)
            if raw_bytes.startswith(b"\x1f\x8b"):
                db_bytes = gzip.decompress(raw_bytes)
                print(f"[opencode-sync] Decompressed {len(raw_bytes):,d} compressed bytes -> {len(db_bytes):,d} DB bytes")
            else:
                db_bytes = raw_bytes

            updated_at = row.get("updated_at", "unknown")
            session_name = row.get("session_name", session_id)

            targets = get_db_paths()
            for t in targets:
                if "/home/akash" in t and not os.path.exists("/home/akash"):
                    continue
                os.makedirs(os.path.dirname(t), exist_ok=True)
                for ext in ["-wal", "-shm", "-journal"]:
                    w = t + ext
                    if os.path.exists(w):
                        try:
                            os.remove(w)
                        except Exception:
                            pass
                with open(t, "wb") as f:
                    f.write(db_bytes)
                _ensure_migrations(t)
                try:
                    c = sqlite3.connect(t, timeout=10)
                    c.execute("PRAGMA journal_mode=WAL")
                    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                    c.close()
                except Exception:
                    pass

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

    source_db = None
    newest_mtime = 0
    for p in get_db_paths():
        for target in [p, p + "-wal"]:
            if os.path.exists(target):
                mtime = os.path.getmtime(target)
                if mtime > newest_mtime:
                    newest_mtime = mtime
                    source_db = p

    if not source_db or not os.path.exists(source_db):
        return 0

    try:
        db_bytes = snapshot_db(source_db)
    except Exception as e:
        print(f"[opencode-sync] WARN: Snapshot fallback to raw read: {e}")
        with open(source_db, "rb") as f:
            db_bytes = f.read()

    for t in get_db_paths():
        if t != source_db and (os.path.exists(os.path.dirname(t)) or ("/home/akash" in t and os.path.exists("/home/akash"))):
            try:
                os.makedirs(os.path.dirname(t), exist_ok=True)
                with open(t, "wb") as f:
                    f.write(db_bytes)
                if "/home/akash" in t:
                    shutil.chown(t, user="akash", group="akash")
            except Exception:
                pass

    compressed_bytes = gzip.compress(db_bytes, compresslevel=6)
    b64_data = base64.b64encode(compressed_bytes).decode("ascii")

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
        conn = sqlite3.connect(source_db, timeout=10)
        cur = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [row[0] for row in cur.fetchall()]
        stats["tables"] = tables
        for st in ["session", "sessions"]:
            if st in tables:
                cur.execute(f"SELECT COUNT(*) FROM {st}")
                stats["session_count"] = cur.fetchone()[0]
                cur.execute(f"SELECT id, title FROM {st} ORDER BY rowid DESC LIMIT 10")
                s_rows = cur.fetchall()
                stats["sessions"] = [{"id": r[0], "title": r[1]} for r in s_rows]
                if s_rows and not extracted_title:
                    extracted_title = s_rows[0][1]
        for mt in ["message", "messages"]:
            if mt in tables:
                cur.execute(f"SELECT COUNT(*) FROM {mt}")
                stats["message_count"] = cur.fetchone()[0]
        conn.close()
    except Exception as e:
        stats["sqlite_inspect_error"] = str(e)

    final_session_name = extracted_title or session_name or f"OpenCode Session {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')}"

    payload = {
        "id": session_id,
        "session_name": final_session_name,
        "data": {
            "db_base64": b64_data,
            "compressed": True,
            "compression_type": "gzip",
            "stats": stats,
            "session_count": stats.get("session_count", 0),
            "message_count": stats.get("message_count", 0),
            "synced_at": datetime.now(timezone.utc).isoformat()
        },
        "updated_at": datetime.now(timezone.utc).isoformat()
    }

    url = f"{SUPABASE_URL}/rest/v1/opencode_sessions"
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=get_headers(), method="POST")
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
            for ext in ["-wal", "-shm"]:
                if os.path.exists(p + ext):
                    print(f"  {ext} : {os.path.getsize(p + ext):,d} bytes")
            try:
                conn = sqlite3.connect(p, timeout=5)
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

def watch(session_id=None, interval=2):
    session_id = session_id or DEFAULT_SESSION_ID
    print(f"[opencode-sync] Real-time watcher active for session '{session_id}' (polling every {interval}s)...")
    last_mtimes = {}
    while True:
        try:
            changed = False
            for p in get_db_paths():
                for target in [p, p + "-wal"]:
                    if os.path.exists(target):
                        m = os.path.getmtime(target)
                        prev = last_mtimes.get(target, 0)
                        if prev != 0 and m > prev:
                            changed = True
                        last_mtimes[target] = m
            if changed:
                time.sleep(1)
                push(session_id=session_id)
            time.sleep(interval)
        except KeyboardInterrupt:
            break
        except Exception:
            time.sleep(interval)

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
        interval = int(arg2) if arg2 and arg2.isdigit() else 2
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
  nohup opencode-sync watch > /var/log/opencode-sync.log 2>&1 &
fi

touch "$STAMP"
log "=== Akash Ubuntu Bootstrap Complete ==="
exit 0
