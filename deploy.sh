#!/bin/bash

# ===============================================
# 🚀 HNG13 DevOps Stage 1 - Automated Deployment Script
# Author: Panason Shadrach Ngandiya
# Description: Automates setup, deployment, and configuration
# of a Dockerized app on a remote Linux server with NGINX reverse proxy.
# ===============================================

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i $LOG_FILE)
exec 2>&1

set -e  # Exit immediately if a command exits with a non-zero status

# ========= Function Definitions =========

log() {
    echo -e "\n[INFO] $1"
}

error_exit() {
    echo -e "\n[ERROR] $1"
    exit 1
}

# ========= Collect User Input =========
echo "🔧 Starting Deployment Setup..."

read -p "Enter Git Repository URL: " REPO_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote server username: " SERVER_USER
read -p "Enter remote server IP: " SERVER_IP
read -p "Enter SSH key path (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter application container port (e.g. 5000): " APP_PORT

# ========= Clone Repository =========
log "Cloning repository..."
if [ -d "./repo" ]; then
    cd repo
    git pull origin $BRANCH || error_exit "Failed to pull latest changes."
else
    git clone -b $BRANCH https://${PAT}@${REPO_URL#https://} repo || error_exit "Repository clone failed."
    cd repo
fi

# ========= Verify Dockerfile =========
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
    error_exit "No Dockerfile or docker-compose.yml found!"
fi
log "Repository verified successfully."

# ========= SSH Connection Test =========
log "Testing SSH connectivity..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SERVER_USER@$SERVER_IP "echo SSH Connection Successful" || error_exit "SSH connection failed."

# ========= Remote Server Setup =========
log "Preparing remote environment..."
ssh -i $SSH_KEY $SERVER_USER@$SERVER_IP <<EOF
    set -e
    sudo apt-get update -y
    sudo apt-get install -y docker.io docker-compose nginx
    sudo systemctl enable docker nginx
    sudo systemctl start docker nginx
    sudo usermod -aG docker $USER || true
EOF

log "Remote server ready."

# ========= Deploy Dockerized Application =========
log "Transferring project files..."
rsync -avz -e "ssh -i $SSH_KEY" ./ $SERVER_USER@$SERVER_IP:/home/$SERVER_USER/app

log "Deploying Docker containers..."
ssh -i $SSH_KEY $SERVER_USER@$SERVER_IP <<EOF
    cd /home/$SERVER_USER/app
    if [ -f "docker-compose.yml" ]; then
        sudo docker-compose down || true
        sudo docker-compose up -d --build
    else
        APP_NAME=\$(basename \$(pwd))
        sudo docker stop \$APP_NAME || true
        sudo docker rm \$APP_NAME || true
        sudo docker build -t \$APP_NAME .
        sudo docker run -d -p $APP_PORT:$APP_PORT --name \$APP_NAME \$APP_NAME
    fi
EOF

# ========= Configure NGINX Reverse Proxy =========
log "Configuring NGINX..."
NGINX_CONF="/etc/nginx/sites-available/app.conf"
ssh -i $SSH_KEY $SERVER_USER@$SERVER_IP <<EOF
    sudo bash -c 'cat > $NGINX_CONF' <<EOL
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
    sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/app.conf
    sudo nginx -t && sudo systemctl reload nginx
EOF

# ========= Validate Deployment =========
log "Validating deployment..."
ssh -i $SSH_KEY $SERVER_USER@$SERVER_IP "curl -I http://localhost || echo 'Local test failed.'"

echo "✅ Deployment complete!"
echo "Visit: http://$SERVER_IP"
