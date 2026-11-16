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
