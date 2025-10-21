#!/bin/bash
set -e  # Exit immediately on error

# === Utility functions ===
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

# === Variables ===
TMP_CLONE_DIR="/tmp/hng_deploy_repo"

# === Functions ===
cleanup_local() {
  if [ -d "$TMP_CLONE_DIR" ]; then
    log "Cleaning up existing clone directory..."
    rm -rf "$TMP_CLONE_DIR" || error_exit "Failed to remove old directory"
  fi
}

prepare_clone_dir() {
  log "Preparing local clone dir: $TMP_CLONE_DIR"
  cleanup_local
  mkdir -p "$TMP_CLONE_DIR" || error_exit "Failed to create clone directory"
  log "✅ Local clone directory ready"
}

clone_or_update_repo() {
  read -p "Enter GitHub repository URL: " GIT_REPO_URL
  read -p "Enter Personal Access Token (PAT): " GIT_PAT
  read -p "Enter branch name (default: main): " BRANCH
  read -p "Enter remote server IP address: " SERVER_IP
  read -p "Enter remote username: " SERVER_USER
  read -p "Enter SSH private key path (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH

  BRANCH=${BRANCH:-main}

  prepare_clone_dir
  cd "$TMP_CLONE_DIR" || error_exit "Failed to enter clone directory"

  REPO_NAME=$(basename -s .git "$GIT_REPO_URL")

  log "Cloning repository..."
  if git clone -b "$BRANCH" "https://${GIT_PAT}@${GIT_REPO_URL#https://}" "$REPO_NAME"; then
    log "✅ Repository cloned successfully."
  else
    error_exit "❌ Failed to clone repository. Check URL or token."
  fi

  cd "$REPO_NAME" || error_exit "Failed to enter repo directory"

  if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "Dockerfile" ]; then
    log "✅ Repository contains Docker configuration."
  else
    error_exit "❌ No Dockerfile or docker-compose.yml found!"
  fi

  # Save variables globally for later
  export SERVER_IP SERVER_USER REPO_NAME SSH_KEY_PATH
}

# === New: Ping connectivity check ===
check_ping() {
  log "Pinging ${SERVER_IP}..."
  if ping -c 2 "$SERVER_IP" >/dev/null 2>&1; then
    log "✅ Ping successful — server is reachable."
    return 0
  else
    error_exit "❌ Ping failed. Server might be down or unreachable."
  fi
}

# === Remote environment setup ===
prepare_remote_env() {
  log "Preparing remote environment on ${SERVER_IP}..."
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SERVER_USER}@${SERVER_IP}" <<'EOF'
set -e
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker $USER || true
sudo systemctl enable docker nginx || true
sudo systemctl start docker nginx || true
echo "✅ Remote environment prepared successfully."
EOF
  log "✅ Remote environment setup complete."
}

# === Main Execution ===
clone_or_update_repo
check_ping && prepare_remote_env

log "🎯 All steps completed successfully!"
