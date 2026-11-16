# akash-automate

> **1-Click Ephemeral Cloud Dev VM on Akash Network with Automated Real-Time Chat Session Persistence via Supabase.**

[![Akash Network](https://img.shields.io/badge/Compute-Akash%20Network-blue.svg)](https://akash.network/)
[![Ubuntu 22.04](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420.svg)](https://ubuntu.com/)
[![Supabase](https://img.shields.io/badge/Sync-Supabase%20PostgREST-3ECF8E.svg)](https://supabase.com/)
[![OpenCode AI](https://img.shields.io/badge/AI%20Agent-OpenCode%201.19-purple.svg)](https://opencode.ai/)

---

## What is akash-automate?

`akash-automate` allows anyone—from complete beginners to seasoned engineers—to spin up a high-performance **Ubuntu 22.04 LTS container VM** on the decentralized Akash cloud in a single command. 

More importantly, it solves the fundamental problem of ephemeral cloud containers: **data loss on destruction**. With the built-in **automated Supabase sync engine**, all your OpenCode chat sessions, agent workspace configurations, and history are synchronized in real-time. When you destroy a VM and spin up a new one hours or days later, **your exact chat sessions, tabs, and conversation state automatically restore on boot**.

---

## Specifications & Pre-Installed Stack

Each provisioned VM comes configured out of the box:

| Attribute | Specification |
|---|---|
| **Operating System** | **Ubuntu 22.04 LTS (Jammy Jellyfish)** — glibc base, full root/sudo |
| **Compute / Specs** | 4 Cores CPU, 16 GiB RAM, 500 GiB Disk (configurable) |
| **Authentication** | Ed25519 SSH Keypair + generated PuTTY `.ppk` + generated password |
| **Cloud CLIs** | `gcloud`, `aws` v2, `az`, `oci` (Oracle) pre-installed |
| **Runtimes** | Python 3.10 + pip + virtualenv, Node.js 22 LTS + npm |
| **AI Coding Agents** | **OpenCode AI**, **Claude Code**, **Aider** |
| **Persistence Engine** | **opencode-sync**: Real-time SQLite WAL checkpoint daemon + Supabase PostgREST |

---

## Beginner Quickstart (Zero-to-Hero in 3 Minutes)

Follow these simple steps to deploy your own cloud AI workstation:

### Step 1: Clone the Repository
Open PowerShell or your terminal:
```powershell
git clone https://github.com/ajithvnr2001/akash-automate.git
cd akash-automate
```

### Step 2: Configure Your Credentials
Copy the example environment file:
```powershell
Copy-Item .env.example .env
```
Open `.env` in any text editor (Notepad, VS Code, etc.) and fill in your keys:
1. **AKASH_API_KEY**: Get yours from [console.akash.network](https://console.akash.network) -> Settings -> API Keys.
2. **SUPABASE_URL & SUPABASE_KEY**: (Recommended for chat persistence) Get from [supabase.com](https://supabase.com) -> Project Settings -> Data API.
3. **AI Keys (Optional)**: Put in your `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY`.

### Step 3: Run the One-Click Deployment
In PowerShell, execute:
```powershell
.\deploy.ps1
```
That's it! The script will automatically:
- Render the Ubuntu Stack Definition (SDL)
- Submit the deployment to Akash Network
- Select the best provider bid and create the lease
- Generate an SSH Ed25519 keypair and a PuTTY `.ppk` key in `.\keys\`
- Wait for the SSH daemon to become ready
- Output your exact SSH connection command and PuTTY instructions!

### Step 4: Connect to Your VM
Once the script finishes, connect immediately:

**Using OpenSSH (Terminal / PowerShell):**
```powershell
ssh -i .\keys\akash_vm_ed25519 -p <PORT> root@<HOST>
```

**Using PuTTY:**
- **Host Name**: `<HOST>`
- **Port**: `<PORT>`
- **Connection -> SSH -> Auth -> Credentials**: Select `keys\<DSEQ>.ppk`
- Click **Open** and log in as `root` (or `akash`).

---

## Automated Session Persistence: How It Works

Traditional cloud VMs lose all data when deleted. `akash-automate` provides **zero-friction automatic persistence**:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Akash Cloud VM (VM 1)                           │
│                                                                        │
│   You chat in OpenCode: opencode                                       │
│   ├── Writes to SQLite: ~/.local/share/opencode/opencode.db            │
│   └── Real-time Daemon (opencode-sync watch) detects changes:          │
│       1. Checkpoints SQLite WAL (PRAGMA wal_checkpoint(TRUNCATE))      │
│       2. Takes an atomic database snapshot using SQLite backup API     │
│       3. Compresses database (gzip)                                    │
│       4. Uploads snapshot to Supabase PostgREST in seconds!            │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Real-Time HTTPS API
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        Supabase Cloud Database                         │
│                                                                        │
│   PostgreSQL Table: public.opencode_sessions                           │
│   • id: 'default' (or custom session ID)                               │
│   • session_name: 'Tamil crime story TTS / Multi-Cloud Agent'          │
│   • data: JSONB (Session counts, metadata, message count)              │
│   • db_backup_b64: Compressed binary SQLite database                   │
│   • updated_at: Automatic UTC timestamp                                │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
               Destroy VM 1: .\destroy.ps1
               Spin up VM 2: .\deploy.ps1
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        Fresh Akash VM (VM 2)                           │
│                                                                        │
│   On first boot (bootstrap.sh):                                        │
│   1. opencode-sync pull automatically detects Supabase credentials     │
│   2. Cleans up stale WAL/shm files and safely restores opencode.db     │
│   3. Auto-registers all 38 migration records                           │
│   4. Launches background sync daemon                                   │
│                                                                        │
│   YOU RUN: opencode session list                                       │
│   ==> ALL YOUR PREVIOUS CHATS, SESSIONS & TOOLS ARE LIVE!              │
└────────────────────────────────────────────────────────────────────────┘
```

### Zero Manual Commands Needed!
- **You do NOT need to run `opencode-sync push` manually.**
- The real-time daemon monitors `opencode.db` and `opencode.db-wal` every 2 seconds. The moment an LLM finishes streaming its response or you enter a prompt, the snapshot is committed and synced to Supabase automatically.
- Both `/root` and `/home/akash` environments are synchronized simultaneously.

---

## OpenCode CLI & In-VM Commands

Inside the VM, you can use OpenCode and its sync tools:

```bash
# Launch OpenCode AI interactive TUI:
opencode

# View all restored chat sessions:
opencode session list

# Switch to an existing session:
opencode -s <session_id>

# Check sync status with Supabase:
opencode-sync status

# Manually push / pull (optional):
opencode-sync push
opencode-sync pull
```

---

## Verifying Cross-VM Restoration (The Test Scenario)

To verify cross-VM persistence yourself:

1. **On VM 1**:
   - Open OpenCode: `opencode`
   - Chat with the agent, ask questions, or run tasks.
   - Run `opencode-sync status` to see your session and messages recorded.
2. **Destroy VM 1**:
   - In your local PowerShell:
     ```powershell
     .\destroy.ps1
     ```
   - The VM is destroyed and your escrow balance is refunded.
3. **Spin Up VM 2**:
   - Run:
     ```powershell
     .\deploy.ps1
     ```
   - SSH into the new VM and run:
     ```bash
     opencode session list
     ```
   - **Result**: All chat sessions and message histories from VM 1 appear instantly!

---

## Troubleshooting & Tips

### 1. "Failed to send prompt" / "Unexpected server error"
- **Cause**: OpenCode defaults to a free provider when no API key is set. Free tier endpoints can occasionally be throttled or unavailable.
- **Solution**: 
  - Add your preferred API key (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY`) to your `.env` file before running `.\deploy.ps1`, or
  - Inside OpenCode, press `ctrl+p` (or type `/models`) to switch to your configured provider, or
  - If the VM is already running, inject keys dynamically:
    ```powershell
    .\set-api-keys.ps1 -FromState -Dseq <DSEQ> -Vars @{ DEEPSEEK_API_KEY = "sk-..." }
    ```

### 2. Supabase Table Setup
The sync engine expects an `opencode_sessions` table. If you are using a brand new Supabase project, execute this in your Supabase SQL Editor once:
```sql
CREATE TABLE IF NOT EXISTS public.opencode_sessions (
    id TEXT PRIMARY KEY,
    session_name TEXT,
    data JSONB,
    db_backup_b64 TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 3. Monitoring VM Bootstrap
When you first connect, packages are installed in the background. To check status:
```bash
tail -f /var/log/bootstrap.log
```
When complete, `vm-info` will show all CLI versions.

---

## Cleaning Up

When you are done with your cloud session, always shut down your deployment to stop Akash hourly compute billing:
```powershell
.\destroy.ps1
```
This safely closes the deployment, reclaims remaining unspent AKT from escrow, and cleans up expired keys.

---

## License

MIT License. Designed for rapid cloud AI workflows.
