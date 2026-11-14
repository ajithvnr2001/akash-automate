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
| **Tooling** | **gcloud, aws, az, oci, python3, pip, node, npm, opencode, claude, aider** |

> [!NOTE]
> Unlike minimal Alpine setups, this environment runs full **Ubuntu Linux** with root/sudo enabled. You have `apt-get`, standard Python, glibc, and all official cloud provider CLI suites pre-installed and ready to use.

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

## Setting Environment Variables & API Keys

To pass API keys (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) from your local machine into the running box without logging in interactively:

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

## Tear Down

When finished, close the deployment to reclaim escrowed balance and clean up old keys:
```powershell
.\destroy.ps1
```
