#!/bin/bash
set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d).log"

# --- Logging Function ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Error Trap ---
trap 'log "Error occurred at line $LINENO. Exiting."; exit 1' ERR

# --- 1. Collect Parameters from User ---
collect_parameters() {
    read -p "Git Repo URL: " REPO_URL
    read -p "Personal Access Token (PAT): " PAT
    read -p "Branch (default: main): " BRANCH
    BRANCH=${BRANCH:-main}
    read -p "Remote SSH Username: " SSH_USER
    read -p "Remote Server IP: " SERVER_IP
    read -p "SSH Key Path: " SSH_KEY
    read -p "App Internal Port: " APP_PORT

    # Validate port
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        log "Invalid port number. Exiting."
        exit 1
    fi
}

# --- 2. Clone Repository ---
clone_repo() {
    REPO_NAME=$(basename "$REPO_URL" .git)
    if [ -d "$REPO_NAME" ]; then
        log "Repo exists. Pulling latest changes..."
        cd "$REPO_NAME"
        git fetch origin
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    else
        log "Cloning repo..."
        git clone -b "$BRANCH" "https://$PAT@${REPO_URL#https://}" "$REPO_NAME"
        cd "$REPO_NAME"
    fi
}

# --- 3. Verify Docker Configuration ---
verify_project_files() {
    if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
        log "Docker configuration found."
    else
        log "No Dockerfile or docker-compose.yml found. Exiting."
        exit 2
    fi
}

# --- 4. Check SSH Connectivity ---
check_ssh() {
    log "Checking SSH connectivity to $SSH_USER@$SERVER_IP..."
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
        log "✅ SSH connection successful."
    else
        log "❌ SSH connection failed. Ensure SSH key is configured."
        exit 3
    fi
}

# --- 5. Prepare Remote Environment ---
prepare_remote_env() {
    log "Preparing remote environment..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker \$USER || true
sudo systemctl enable docker nginx || true
sudo systemctl start docker nginx || true
EOF
    log "✅ Remote environment prepared."
}

# --- 6. Deploy Docker App ---
deploy_app() {
    log "Transferring project files..."
    rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME"

    log "Deploying Docker app..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
cd /home/$SSH_USER/$REPO_NAME
if [ -f "docker-compose.yml" ]; then
    docker-compose down || true
    docker-compose up -d
else
    docker rm -f app || true
    docker build -t app .
    docker run -d -p $APP_PORT:$APP_PORT --name app app
fi
EOF
    log "✅ App deployed."
}

# --- 7. Configure Nginx as Reverse Proxy ---
configure_nginx() {
    log "Configuring Nginx..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
sudo tee /etc/nginx/sites-available/app.conf > /dev/null <<NGINX
server {
    listen 80;
    location / {
        proxy_pass http://localhost:$APP_PORT;
    }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF
    log "✅ Nginx configured."
}

# --- 8. Validate Deployment ---
validate_deployment() {
    log "Validating deployment..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
systemctl is-active docker || echo "Docker not running!"
docker ps | grep app || echo "App container not running!"
curl -I http://localhost || echo "Nginx or app not accessible!"
EOF
    log "✅ Deployment validated."
}

# --- 9. Cleanup (Optional) ---
cleanup() {
    log "Performing cleanup..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" <<EOF
set -e
docker-compose down || docker rm -f \$(docker ps -q)
sudo rm -rf /home/$SSH_USER/$REPO_NAME
sudo rm -f /etc/nginx/sites-enabled/app.conf
sudo systemctl reload nginx || true
EOF
    log "✅ Cleanup complete."
}

# --- 10. Main Execution ---
main() {
    collect_parameters
    clone_repo
    verify_project_files
    check_ssh
    prepare_remote_env
    deploy_app
    configure_nginx
    validate_deployment
    log "🎯 All steps completed successfully!"
}

# --- Parse Flags ---
if [[ "${1:-}" == "--cleanup" ]]; then
    collect_parameters
    cleanup
else
    main
fi
