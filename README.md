# akash-automate

End-to-end automation for provisioning an **Ubuntu Linux container VM** on Akash Network with full root/sudo access and cloud CLIs + AI agent tooling pre-installed.

---

## What it produces

An **Ubuntu 22.04 LTS** container on an Akash provider node:

| Attribute | Specification |
|---|---|
| **OS** | **Ubuntu 22.04 LTS (Jammy Jellyfish)** — glibc base |
| **CPU** | 4 cores (cgroup-limited, configurable) |
| **RAM** | 16 GiB (configurable) |
| **Disk** | 500 GiB (provider-enforced, configurable) |
| **Users** | `akash` (with passwordless `sudo`) and `root` |
| **Auth** | SSH Key (Ed25519) + generated 32-character password |
| **Tooling** | **gcloud, aws, az, oci, python3, pip, node, npm, opencode, opencode-sync, claude, aider** |
| **Persistence** | **Automated OpenCode DB & session sync via Supabase PostgREST** |

> [!NOTE]
> Unlike minimal Alpine setups, this environment runs full **Ubuntu Linux** with root/sudo enabled. You have `apt-get`, standard Python, glibc, and all official cloud provider CLI suites pre-installed and ready to use. OpenCode sessions are automatically synced with Supabase, restoring your chat history seamlessly across ephemeral VM lifecycles.

---

## Pre-Installed Tooling & CLIs

Every provisioned Ubuntu container automatically bootstraps the following tools into system `PATH`:

| Category | Tool | Command | Description |
|---|---|---|---|
| **Cloud CLI** | Google Cloud SDK | `gcloud`, `gsutil`, `bq` | Official Google Cloud CLI suite |
| **Cloud CLI** | AWS CLI v2 | `aws` | Official Amazon Web Services CLI v2 |
| **Cloud CLI** | Azure CLI | `az` | Official Microsoft Azure CLI |
| **Cloud CLI** | Oracle OCI CLI | `oci` | Official Oracle Cloud Infrastructure CLI |
| **Runtime** | Python 3 & Pip | `python3`, `pip` | Python 3.10 + pip + virtualenv + dev tools |
| **Runtime** | Node.js & npm | `node`, `npm` | Node.js 22 LTS (glibc native) |
| **AI Agents** | OpenCode AI | `opencode` | Autonomous open-source coding agent |
| **AI Agents** | Claude Code | `claude` | Anthropic's Claude Code CLI |
| **AI Agents** | Aider | `aider` | AI pair programming agent in your terminal |
| **Utilities** | Dev Essentials | `git`, `curl`, `jq`, `unzip`, `build-essential`, `tmux`, `htop` | Standard Linux developer utilities |
| **Sync Engine** | OpenCode Sync | `opencode-sync` | Transparent Supabase session database sync engine |

---

## Automated OpenCode Session Persistence via Supabase

Akash containers are ephemeral by nature: when a deployment is destroyed, local disks are wiped. To provide seamless session continuity, `akash-automate` features an **automated OpenCode DB migration and sync engine powered by Supabase**.

### Architecture Overview

```
 ┌────────────────────────────────────────────────────────┐
 │                   Akash Container                      │
 │                                                        │
 │   User / Agent chats in OpenCode                       │
 │      │                                                 │
 │      ▼                                                 │
 │   Local SQLite DB: ~/.local/share/opencode/opencode.db │
 │      │                                                 │
 │      ▼                                                 │
 │   opencode-sync Engine (High-speed gzip + Base64)      │
 └──────────────────────┬─────────────────────────────────┘
                        │
                        │ Automated PostgREST HTTPS API
                        ▼
 ┌────────────────────────────────────────────────────────┐
 │                   Supabase Cloud                       │
 │                                                        │
 │   PostgreSQL Table: public.opencode_sessions           │
 │   • id: 'default' (or custom session ID)               │
 │   • session_name: 'Autonomous Multi-Cloud Agent...'    │
 │   • data: JSONB (Session counts, metadata, tables)     │
 │   • db_backup_b64: Compressed binary SQLite database   │
 │   • updated_at: Automatic UTC timestamp                │
 └──────────────────────┬─────────────────────────────────┘
                        │
                        │ When a new VM is spun up
                        ▼
 ┌────────────────────────────────────────────────────────┐
 │                 Fresh Akash VM (VM 2)                  │
 │                                                        │
 │   Bootstrap runs: opencode-sync pull                   │
 │      │                                                 │
 │      ▼                                                 │
 │   OpenCode DB restored automatically                   │
 │   Full chat history, tools, and sessions available!    │
 └────────────────────────────────────────────────────────┘
```

### Key Capabilities

1. **Zero-Configuration Automatic Restore on Boot**:
   When any new Akash VM is spun up via `.\deploy.ps1`, the bootstrap process detects the Supabase configuration and runs `opencode-sync pull` automatically. The previous chat sessions and SQLite databases are restored before you even open your first terminal.

2. **Transparent OpenCode CLI Wrapper**:
   Running `opencode` automatically triggers `opencode-sync pull` prior to starting the session, runs a background sync watcher while active, and pushes the updated database back to Supabase upon exit.

3. **High-Performance Compression**:
   The database payload is compressed via `gzip` (level 6) before transmission to Supabase, reducing transmission size and latency by over 95%.

4. **Multi-User Consistency**:
   Both `root` (`/root/.local/share/opencode/opencode.db`) and `akash` (`/home/akash/.local/share/opencode/opencode.db`) have their databases kept in full synchronization with proper file permissions.

### OpenCode Sync Commands

Inside any provisioned VM, you can inspect or trigger synchronization using `opencode-sync`:

```bash
# Check local database stats vs remote Supabase status:
opencode-sync status

# Pull the latest database snapshot from Supabase:
opencode-sync pull [session_id]

# Push the current local database to Supabase:
opencode-sync push [session_id] [session_name]

# Run a daemon watcher that syncs on every database write:
opencode-sync watch [session_id]
```

### Supabase Table Schema

The sync engine uses the `opencode_sessions` table in Supabase:

```sql
CREATE TABLE IF NOT EXISTS public.opencode_sessions (
    id TEXT PRIMARY KEY,
    session_name TEXT,
    data JSONB,
    db_backup_b64 TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## Quick Start

```powershell
# 1. Set your Akash Console API key (saved to state\api-key.txt for persistence)
$env:AKASH_API_KEY = "ac.sk.production...."
Set-Content -Path .\state\api-key.txt -Value $env:AKASH_API_KEY -NoNewline

# 2. Provision Ubuntu container
.\deploy.ps1

# 3. Connect via SSH as root (full root / sudo access):
ssh -i .\keys\akash_vm_ed25519 -p <port> root@<host>

# User 'akash' is also configured if non-root login is desired:
ssh -i .\keys\akash_vm_ed25519 -p <port> akash@<host>

# 4. Check system specs and installed CLI versions inside the container:
vm-info

# 5. Tear down when finished
.\destroy.ps1
```

---

## Repository Files

| File | Purpose |
|---|---|
| `deploy.ps1` | Deploys the Ubuntu container, accepts the cheapest provider bid, waits for SSH readiness, generates PuTTY `.ppk`, and outputs connection details |
| `destroy.ps1` | Closes active deployments, verifies balance escrow is returned, and cleans up old deployment keys |
| `status.ps1` | Shows current deployments, endpoints, escrow, balance, and pricing |
| `render-sdl.ps1` | Generates the Akash Stack Definition Language (SDL) YAML pinned to `ubuntu:22.04` with SSH setup and bootstrap script injected |
| `bootstrap.sh` | Ubuntu bootstrap script: installs `gcloud`, `aws`, `az`, `oci`, `python3`, `node`, `opencode`, `claude`, `aider` |
| `set-api-keys.ps1` | Pushes application API keys (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) into the container's environment |
| `new-ppk.ps1` | Writes a PuTTY v2 `.ppk` from the OpenSSH key |
| `test-ppk.ps1` | Verifies the PPK MAC and key formatting |
| `keys\` | Directory holding active SSH private keys (`akash_vm_ed25519`, `.ppk`, `.openssh`) |
| `state\` | Contains `api-key.txt`, deployment JSONs, and SSH configs (gitignored) |
| `logs\` | Deployment logs |

---

## Key Management & Cleanup

The `keys\` directory holds SSH credentials:

```
keys\
├── akash_vm_ed25519          # OpenSSH private key for active deployment
├── akash_vm_ed25519.pub      # OpenSSH public key injected into container
├── <dseq>.ppk                # PuTTY private key for active deployment
└── <dseq>.openssh            # OpenSSH private key named by deployment sequence
```

### Key Retention Policy
- **Live Deployment Key**: The active deployment's keys are kept while the container is running.
- **Old / Stale Keys**: When a deployment is closed or destroyed via `.\destroy.ps1`, closed deployment keys (`<dseq>.ppk`, `<dseq>.openssh`) are automatically cleaned up to prevent accumulation of dead keys.
- **Fresh Deployment**: If no key exists in `keys\`, `.\deploy.ps1` generates a fresh Ed25519 keypair automatically.

---

## Inside the Container: Using Cloud CLIs & AI Agents

Once connected via SSH:

### 1. Verification Utility (`vm-info`)
Run `vm-info` to display the machine specs and verify all installed CLI versions:
```bash
vm-info
```
Sample output:
```
==================== VM INFO ====================
Host     : akash-agent-box
OS       : Ubuntu 22.04.5 LTS
User     : akash (uid=1000)
CPUs     : 4
Memory   : 16Gi
Disk     : 500G total
================ Installed CLIs ================
  gcloud       : Google Cloud SDK 510.0.0
  aws          : aws-cli/2.24.0 Python/3.12.6 Linux/x86_64
  az           : 2.69.0
  oci          : 3.51.0
  python3      : Python 3.10.12
  pip          : pip 24.3.1
  node         : v22.14.0
  npm          : 10.9.2
  opencode     : 1.19.5
  claude       : 0.2.29
  aider        : 0.74.2
================================================
```

### 2. Google Cloud CLI (`gcloud`)
```bash
gcloud init
gcloud auth login
gcloud projects list
```

### 3. AWS CLI (`aws`)
```bash
aws configure
# Enter AWS Access Key ID, Secret Access Key, Region (e.g. us-east-1)
aws sts get-caller-identity
```

### 4. Azure CLI (`az`)
```bash
az login --use-device-code
az account show
```

### 5. Oracle Cloud CLI (`oci`)
```bash
oci setup config
# Follow the interactive prompts to set tenancy, user OCID, fingerprint, and region
```

### 6. AI Agent Tools
Run any of the pre-installed autonomous coding agents:

- **OpenCode**:
  ```bash
  opencode
  ```
- **Claude Code**:
  ```bash
  claude
  ```
- **Aider**:
  ```bash
  aider
  ```

---

## One-Click Deployment With Different APIs

You can deploy in **a single command or click** while using different Akash accounts AND injecting different AI / Cloud provider APIs:

### 1. Using Different Akash API Keys / Accounts
```powershell
# One-click deploy with a specific Akash Console API key:
.\deploy.ps1 -AkashApiKey "ac.sk.production...."

# One-click deploy with a named account profile (looks for state\api-key-<account>.txt):
.\deploy.ps1 -Account "team-project"
```

### 2. Auto-Injecting Different AI & Cloud APIs into the Box
You don't need to configure keys after connecting. `deploy.ps1` automatically injects them during provisioning:

#### Option A: Auto-load from `.env` (Recommended)
1. Copy the template:
   ```powershell
   Copy-Item .env.example .env
   ```
2. Put any combination of API keys into `.env` (OpenAI, Anthropic Claude, DeepSeek, Gemini, OpenRouter, AWS, Cloudflare R2, Azure, OCI).
3. Run one command:
   ```powershell
   .\deploy.ps1
   ```
   All keys are immediately available in `/root/.agent-env` and `/home/akash/.agent-env` upon login!

#### Option B: Pass API Keys Directly to `deploy.ps1`
```powershell
.\deploy.ps1 -ApiKeys @{
    ANTHROPIC_API_KEY = "sk-ant-api03-..."
    OPENAI_API_KEY    = "sk-proj-..."
    DEEPSEEK_API_KEY  = "sk-..."
    GEMINI_API_KEY    = "AIzaSy..."
    OPENROUTER_API_KEY = "sk-or-..."
}
```

#### Option C: Specify a Custom Env File
```powershell
.\deploy.ps1 -EnvFile "D:\keys\my-agent.env"
```

### 3. One-Click Deployment from GitHub Actions
1. Go to your GitHub repository: [ajithvnr2001/akash-automate](https://github.com/ajithvnr2001/akash-automate)
2. Click **Actions** → **Akash Management Workflow** → **Run workflow**.
3. Choose `deploy`, optionally paste any custom Akash key or application API keys (`KEY=VALUE`), and click **Run workflow**.

---

## Setting Environment Variables & API Keys (After Deployment)

If the box is already running and you want to push additional API keys without restarting:

```powershell
.\set-api-keys.ps1 -FromState -Dseq <DSEQ> -Vars @{
    ANTHROPIC_API_KEY = "sk-ant-api03-..."
    OPENAI_API_KEY    = "sk-proj-..."
    DEEPSEEK_API_KEY  = "sk-..."
}
```

Inside the container, run `agent-env` or start a new shell to load them.

---

## Monitoring Bootstrap Progress

On container creation, the SSH service starts immediately (~10-15 seconds) so you can connect right away. Tool installation runs via `bootstrap.sh` in the background.

To watch installation progress inside the box:
```bash
tail -f /var/log/bootstrap.log
```
When complete, `/home/akash/.bootstrap-complete` is created.

---

## End-to-End Test & Verification Report

The automated Supabase session migration has been tested and verified **end-to-end** across multiple distinct Akash provider deployments:

### Verification Runbook

1. **Step 1: VM 1 Provisioning**
   - Deployed Akash container `dseq: 1794820420069` on provider `digitalfrontier.so:30468`.
   - Injected Supabase credentials from `.env`.
   - Verified automated installation of cloud CLIs and OpenCode AI tooling.

2. **Step 2: Session & Chat Creation on VM 1**
   - Created OpenCode chat session: `Autonomous Multi-Cloud Agent Pipeline`.
   - Inserted multi-turn conversational exchange between `user` and `assistant`.
   - Pushed database via `opencode-sync push` (20,480 DB bytes compressed to 883 bytes in Supabase).
   - Verified row in Supabase PostgREST table `opencode_sessions`.

3. **Step 3: Complete Destruction of VM 1**
   - Executed `.\destroy.ps1`.
   - Lease terminated, deployment closed, and ephemeral container disk completely destroyed.
   - Escrowed balance returned.

4. **Step 4: VM 2 Spin-Up & Automated Session Restoration**
   - Spun up completely fresh Akash container `dseq: 1794820870825` on port `31172`.
   - During container bootstrap, `opencode-sync pull` automatically detected Supabase credentials and fetched the session database.
   - Decompressed and restored `/root/.local/share/opencode/opencode.db` and `/home/akash/.local/share/opencode/opencode.db`.

5. **Step 5: Verification of Restored Chats on VM 2**
   - Inspected SQLite database on VM 2 via SSH:
     ```
     --- Restored Sessions ---
       Session ID : sess-vm1-migrated-1794820782
       Title      : Autonomous Multi-Cloud Agent Pipeline
       Created At : 2026-11-16 09:19:42 UTC
       Updated At : 2026-11-16 09:19:52 UTC

     --- Restored Chat Messages ---
     [sess-vm1-migrated-1794820782] USER: Configure multi-cloud agents for Akash and Supabase.
     [sess-vm1-migrated-1794820782] ASSISTANT: Multi-cloud agent configured. Persisting database directly to Supabase PostgREST.
     [sess-vm1-migrated-1794820782] USER: Does this session persist if VM 1 is destroyed?
     [sess-vm1-migrated-1794820782] ASSISTANT: Yes, upon spinning up VM 2, opencode-sync automatically restores this entire chat history from Supabase.
     ```
   - Confirmed **100% data fidelity and seamless restoration**.

---

## Tear Down

When finished, close the deployment to reclaim escrowed balance and clean up old keys:
```powershell
.\destroy.ps1
```
