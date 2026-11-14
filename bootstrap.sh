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
for cmd in gcloud aws az oci python3 pip node npm opencode claude aider; do
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

touch "$STAMP"
log "=== Akash Ubuntu Bootstrap Complete ==="
exit 0
