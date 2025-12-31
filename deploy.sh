#!/bin/bash
# CineStream Deployment Script
# Complete server setup, deployment, and management for CineStream application

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="${APP_NAME:-cinestream}"
APP_DIR="/var/www/${APP_NAME}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_COUNT=20
START_PORT=8001
P_CORES="0-5"      # P-cores for MongoDB and Nginx
E_CORES="6-13"     # E-cores for Python apps

# Logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install yay (AUR helper)
install_yay() {
    log_step "Installing yay (AUR helper)..."
    
    if command -v yay &> /dev/null; then
        log_info "yay is already installed"
        return 0
    fi
    
    # Check if yay directory exists
    if [[ -d /opt/yay ]]; then
        log_info "yay directory exists, skipping installation"
        return 0
    fi
    
    # Install dependencies for building yay
    pacman -S --needed --noconfirm base-devel git
    
    # Clone and build yay
    cd /tmp
    if [[ -d yay ]]; then
        rm -rf yay
    fi
    
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    
    log_info "yay installed successfully"
}

# Install MongoDB via yay
install_mongodb() {
    log_step "Installing MongoDB..."
    
    if systemctl is-active --quiet mongodb.service 2>/dev/null; then
        log_info "MongoDB is already installed and running"
        return 0
    fi
    
    # Try to install via yay (AUR)
    if command -v yay &> /dev/null; then
        log_info "Installing MongoDB via yay (mongodb-bin)..."
        yay -S --noconfirm mongodb-bin || {
            log_warn "yay installation failed, trying official repositories..."
            pacman -S --needed --noconfirm mongodb-tools || {
                log_warn "Official repo installation failed, trying manual download..."
                install_mongodb_manual
                return 0
            }
        }
    else
        log_warn "yay not available, trying official repositories..."
        pacman -S --needed --noconfirm mongodb-tools || {
            log_warn "Official repo installation failed, trying manual download..."
            install_mongodb_manual
            return 0
        }
    }
    
    # Create MongoDB directories
    mkdir -p /opt/mongodb/{data,logs}
    chown -R mongodb:mongodb /opt/mongodb 2>/dev/null || true
    
    # Create systemd service if it doesn't exist
    if [[ ! -f /etc/systemd/system/mongodb.service ]]; then
        cat > /etc/systemd/system/mongodb.service <<EOF
[Unit]
Description=MongoDB Database Server
After=network.target

[Service]
Type=forking
User=mongodb
Group=mongodb
CPUAffinity=${P_CORES}
ExecStart=/opt/mongodb/bin/mongod --dbpath=/opt/mongodb/data --logpath=/opt/mongodb/logs/mongod.log --logappend --fork
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    
    # Start MongoDB
    systemctl enable mongodb.service
    systemctl start mongodb.service
    
    log_info "MongoDB installed and started"
}

# Manual MongoDB installation fallback
install_mongodb_manual() {
    log_warn "Attempting manual MongoDB installation..."
    
    # This is a fallback - user should install MongoDB manually
    log_error "MongoDB installation failed. Please install MongoDB manually:"
    log_error "  1. Download from https://www.mongodb.com/try/download/community"
    log_error "  2. Extract to /opt/mongodb"
    log_error "  3. Create /opt/mongodb/data and /opt/mongodb/logs directories"
    log_error "  4. Run: sudo systemctl start mongodb.service"
    exit 1
}

# Install system packages
install_system_packages() {
    log_step "Installing system packages..."
    
    # Update system
    pacman -Syu --noconfirm
    
    # Install required packages
    pacman -S --needed --noconfirm \
        python python-pip python-virtualenv \
        nginx \
        git \
        nodejs npm \
        go \
        certbot certbot-nginx \
        firewalld \
        openssh \
        base-devel
    
    log_info "System packages installed"
}

# Setup firewall
setup_firewall() {
    log_step "Configuring firewall..."
    
    # Enable and start firewalld
    systemctl enable firewalld.service
    systemctl start firewalld.service
    
    # Allow SSH (critical - don't remove!)
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    
    log_info "Firewall configured (SSH, HTTP, HTTPS allowed)"
}

# Setup SSH
setup_ssh() {
    log_step "Configuring SSH..."
    
    # Enable SSH service
    systemctl enable sshd.service
    systemctl start sshd.service
    
    # Harden SSH configuration
    if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        echo "" >> /etc/ssh/sshd_config
        echo "# CineStream SSH Hardening" >> /etc/ssh/sshd_config
        echo "PermitRootLogin no" >> /etc/ssh/sshd_config
        echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo "X11Forwarding no" >> /etc/ssh/sshd_config
        systemctl restart sshd.service
        log_info "SSH hardened (root login disabled, pubkey auth enabled)"
    else
        log_info "SSH already configured"
    fi
}

# Install CPU affinity script
install_cpu_affinity_script() {
    log_step "Installing CPU affinity management script..."
    
    mkdir -p /usr/local/bin
    cp "${PROJECT_DIR}/scripts/set_cpu_affinity.sh" /usr/local/bin/cinestream-set-cpu-affinity.sh
    chmod +x /usr/local/bin/cinestream-set-cpu-affinity.sh
    
    log_info "CPU affinity script installed"
}

# Create CPU affinity systemd services
create_cpu_affinity_services() {
    log_step "Creating CPU affinity systemd services..."
    
    # Startup service
    cat > /etc/systemd/system/cinestream-cpu-affinity.service <<EOF
[Unit]
Description=CineStream CPU Affinity Manager
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cinestream-set-cpu-affinity.sh all
ExecStartPost=/bin/bash -c 'sleep 10 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'

[Install]
WantedBy=cinestream.target
EOF
    
    # Timer service (runs every 5 minutes)
    cat > /etc/systemd/system/cinestream-cpu-affinity.timer <<EOF
[Unit]
Description=CineStream CPU Affinity Timer
Requires=cinestream-cpu-affinity.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=cinestream-cpu-affinity.service

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable cinestream-cpu-affinity.timer
    systemctl start cinestream-cpu-affinity.timer
    
    log_info "CPU affinity services created and enabled"
}

# Deploy application
deploy_app() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    log_step "Deploying application: ${app_name}..."
    
    # Create application directory
    mkdir -p "${app_dir}"
    
    # Copy application files
    log_info "Copying application files..."
    cp -r "${PROJECT_DIR}/src" "${app_dir}/"
    cp -r "${PROJECT_DIR}/requirements.txt" "${app_dir}/"
    
    # Create static directory
    mkdir -p "${app_dir}/static/movie_images"
    
    # Create Python virtual environment
    log_info "Creating Python virtual environment..."
    cd "${app_dir}"
    python -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
    deactivate
    
    # Create .env file if it doesn't exist
    if [[ ! -f "${app_dir}/.env" ]]; then
        log_info "Creating .env file..."
        cat > "${app_dir}/.env" <<EOF
# MongoDB Configuration
MONGO_URI=mongodb://localhost:27017/movie_db

# Flask Configuration
SECRET_KEY=$(openssl rand -hex 32)

# Anthropic API Configuration
ANTHROPIC_API_KEY=your-api-key-here
CLAUDE_MODEL=haiku
EOF
        chmod 600 "${app_dir}/.env"
        log_warn "Created .env file. Please update ANTHROPIC_API_KEY before using the application."
    fi
    
    # Create .deploy_config file
    local start_port=$START_PORT
    local end_port=$((START_PORT + WORKER_COUNT - 1))
    
    # Find next available port range
    if [[ -f "${app_dir}/.deploy_config" ]]; then
        source "${app_dir}/.deploy_config"
        start_port=$START_PORT
        end_port=$END_PORT
    else
        # Find next available port range
        for existing_app in /var/www/*/; do
            if [[ -f "${existing_app}/.deploy_config" ]]; then
                source "${existing_app}/.deploy_config"
                if [[ $END_PORT -ge $start_port ]]; then
                    start_port=$((END_PORT + 1))
                    end_port=$((start_port + WORKER_COUNT - 1))
                fi
            fi
        done
    fi
    
    cat > "${app_dir}/.deploy_config" <<EOF
APP_NAME=${app_name}
START_PORT=${start_port}
END_PORT=${end_port}
WORKER_COUNT=${WORKER_COUNT}
DOMAIN=
EOF
    
    log_info "Application deployed to ${app_dir}"
    log_info "Port range: ${start_port}-${end_port}"
}

# Create systemd services for workers
create_worker_services() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    log_step "Creating systemd services for ${app_name} workers..."
    
    source "${app_dir}/.deploy_config"
    
    # Create service template
    cat > /etc/systemd/system/${app_name}@.service <<EOF
[Unit]
Description=${app_name} Web Worker (Port %i)
After=network.target mongodb.service
PartOf=${app_name}.target

[Service]
Type=simple
CPUAffinity=${E_CORES}
WorkingDirectory=${app_dir}
Environment="PATH=${app_dir}/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${app_dir}/venv/bin/python ${app_dir}/src/main.py --port %i
Restart=always
RestartSec=10
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh python || true'

[Install]
WantedBy=${app_name}.target
EOF
    
    # Create target for all workers
    cat > /etc/systemd/system/${app_name}.target <<EOF
[Unit]
Description=${app_name} Application Target
After=mongodb.service nginx.service
Wants=${app_name}@*.service

[Install]
WantedBy=multi-user.target
EOF
    
    # Create startup service
    cat > /etc/systemd/system/${app_name}-startup.service <<EOF
[Unit]
Description=${app_name} Startup Service
After=mongodb.service nginx.service
Before=${app_name}.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for port in \$(seq ${START_PORT} ${END_PORT}); do systemctl start ${app_name}@\${port}.service; done'

[Install]
WantedBy=${app_name}.target
EOF
    
    systemctl daemon-reload
    
    # Start all workers
    for port in $(seq ${START_PORT} ${END_PORT}); do
        systemctl enable "${app_name}@${port}.service"
        systemctl start "${app_name}@${port}.service"
    done
    
    systemctl enable "${app_name}.target"
    systemctl enable "${app_name}-startup.service"
    systemctl start "${app_name}.target"
    
    log_info "Created and started ${WORKER_COUNT} worker services (ports ${START_PORT}-${END_PORT})"
}

# Configure Nginx
configure_nginx() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    log_step "Configuring Nginx for ${app_name}..."
    
    source "${app_dir}/.deploy_config"
    
    # Create upstream configuration
    local upstream_block=""
    for port in $(seq ${START_PORT} ${END_PORT}); do
        upstream_block="${upstream_block}    server 127.0.0.1:${port};\n"
    done
    
    # Create Nginx config file
    cat > /etc/nginx/conf.d/${app_name}.conf <<EOF
# Upstream backend for ${app_name}
upstream ${app_name}_backend {
    ip_hash;  # Sticky sessions
${upstream_block}}

# HTTP server (redirects to HTTPS if domain is configured)
server {
    listen 80;
    server_name _;
    
    # Redirect root to /${app_name}/ for localhost access
    location = / {
        return 301 /${app_name}/;
    }
    
    # Serve application at /${app_name}/ subpath
    location /${app_name}/ {
        proxy_pass http://${app_name}_backend/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Remove /${app_name} prefix from request
        rewrite ^/${app_name}(.*) \$1 break;
    }
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx.service
    
    log_info "Nginx configured for ${app_name}"
}

# Set domain
set_domain() {
    local domain="${1:-}"
    local app_name="${2:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ -z "$domain" ]]; then
        log_error "Domain name is required"
        echo "Usage: $0 set-domain <domain> [app-name]"
        exit 1
    fi
    
    log_step "Setting domain ${domain} for ${app_name}..."
    
    if [[ ! -d "${app_dir}" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        exit 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    # Update .deploy_config
    sed -i "s/^DOMAIN=.*/DOMAIN=${domain}/" "${app_dir}/.deploy_config"
    
    # Create upstream block
    local upstream_block=""
    for port in $(seq ${START_PORT} ${END_PORT}); do
        upstream_block="${upstream_block}    server 127.0.0.1:${port};\n"
    done
    
    # Update Nginx configuration
    cat > /etc/nginx/conf.d/${app_name}.conf <<EOF
# Upstream backend for ${app_name}
upstream ${app_name}_backend {
    ip_hash;  # Sticky sessions
${upstream_block}}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    server_name ${domain};
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect all other requests to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTP server - catch-all for IP and other hostnames
server {
    listen 80 default_server;
    server_name _;
    
    # Redirect root to /${app_name}/ for localhost access
    location = / {
        return 301 /${app_name}/;
    }
    
    # Serve application at /${app_name}/ subpath
    location /${app_name}/ {
        proxy_pass http://${app_name}_backend/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Remove /${app_name} prefix from request
        rewrite ^/${app_name}(.*) \$1 break;
    }
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}

# HTTPS server (SSL will be configured by install-ssl)
server {
    listen 443 ssl http2;
    server_name ${domain};
    
    # SSL configuration (placeholders - will be updated by install-ssl)
    # ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy to backend
    location / {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support (if needed)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx.service
    
    log_info "Domain ${domain} configured for ${app_name}"
    log_warn "SSL certificate not yet installed. Run: $0 install-ssl ${domain} ${app_name}"
}

# Install SSL certificate
install_ssl() {
    local domain="${1:-}"
    local app_name="${2:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ -z "$domain" ]]; then
        log_error "Domain name is required"
        echo "Usage: $0 install-ssl <domain> [app-name]"
        exit 1
    fi
    
    log_step "Installing SSL certificate for ${domain}..."
    
    if [[ ! -d "${app_dir}" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        exit 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    # Verify DNS
    log_info "Verifying DNS resolution..."
    local resolved_ip=$(dig +short ${domain} A | head -n1)
    if [[ -z "$resolved_ip" ]]; then
        log_error "DNS not resolving for ${domain}. Please configure DNS first."
        exit 1
    fi
    log_info "DNS resolves to: ${resolved_ip}"
    
    # Install certbot if not installed
    if ! command -v certbot &> /dev/null; then
        pacman -S --needed --noconfirm certbot certbot-nginx
    fi
    
    # Obtain certificate
    log_info "Requesting SSL certificate from Let's Encrypt..."
    certbot certonly --nginx -d ${domain} --non-interactive --agree-tos --email admin@${domain} || {
        log_error "SSL certificate installation failed"
        exit 1
    }
    
    # Update Nginx configuration with SSL paths
    local ssl_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/${domain}/privkey.pem"
    
    if [[ -f "$ssl_cert" && -f "$ssl_key" ]]; then
        # Update Nginx config with SSL paths
        sed -i "s|# ssl_certificate|ssl_certificate|g" /etc/nginx/conf.d/${app_name}.conf
        sed -i "s|/etc/letsencrypt/live/\${domain}/|/etc/letsencrypt/live/${domain}/|g" /etc/nginx/conf.d/${app_name}.conf
        
        # Test and reload Nginx
        nginx -t && systemctl reload nginx.service
        
        log_info "SSL certificate installed and configured"
        log_info "HTTPS is now available at https://${domain}"
    else
        log_error "SSL certificate files not found"
        exit 1
    fi
}

# Enable autostart
enable_autostart() {
    log_step "Enabling autostart for all services..."
    
    # Enable CPU affinity services
    systemctl enable cinestream-cpu-affinity.service
    systemctl enable cinestream-cpu-affinity.timer
    
    # Enable MongoDB and Nginx
    systemctl enable mongodb.service
    systemctl enable nginx.service
    
    # Enable all application targets
    for target in /etc/systemd/system/*.target; do
        if [[ -f "$target" ]] && grep -q "Description.*Application Target" "$target" 2>/dev/null; then
            local target_name=$(basename "$target" .target)
            systemctl enable "${target_name}.target"
        fi
    done
    
    # Enable master startup target
    if [[ -f /etc/systemd/system/cinestream.target ]]; then
        systemctl enable cinestream.target
    fi
    
    log_info "Autostart enabled for all services"
}

# Initialize server
init_server() {
    log_step "Initializing CineStream server..."
    
    check_root
    
    # Install system packages
    install_system_packages
    
    # Install yay
    install_yay
    
    # Install MongoDB
    install_mongodb
    
    # Setup firewall
    setup_firewall
    
    # Setup SSH
    setup_ssh
    
    # Install CPU affinity script
    install_cpu_affinity_script
    
    # Create CPU affinity services
    create_cpu_affinity_services
    
    # Create master target
    cat > /etc/systemd/system/cinestream.target <<EOF
[Unit]
Description=CineStream Master Target
After=mongodb.service nginx.service
Wants=cinestream-cpu-affinity.service

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cinestream.target
    
    # Deploy default application
    deploy_app "${APP_NAME}"
    
    # Create worker services
    create_worker_services "${APP_NAME}"
    
    # Configure Nginx
    configure_nginx "${APP_NAME}"
    
    # Initialize database (if API key is set)
    local app_dir="/var/www/${APP_NAME}"
    if grep -q "ANTHROPIC_API_KEY=.*[^=]$" "${app_dir}/.env" 2>/dev/null && ! grep -q "ANTHROPIC_API_KEY=your-api-key-here" "${app_dir}/.env" 2>/dev/null; then
        log_info "Initializing database..."
        cd "${app_dir}"
        "${app_dir}/venv/bin/python" "${app_dir}/src/scripts/init_db.py" || log_warn "Database initialization failed (API key may be invalid)"
    else
        log_warn "Database not initialized. Update ANTHROPIC_API_KEY in ${app_dir}/.env and run: ${app_dir}/venv/bin/python ${app_dir}/src/scripts/init_db.py"
    fi
    
    # Enable autostart
    enable_autostart
    
    log_info "Server initialization complete!"
    log_info "Application is accessible at: http://localhost/${APP_NAME}/"
    log_warn "Don't forget to:"
    log_warn "  1. Update ANTHROPIC_API_KEY in ${app_dir}/.env"
    log_warn "  2. Initialize database: cd ${app_dir} && ./venv/bin/python src/scripts/init_db.py"
    log_warn "  3. Configure domain: $0 set-domain <domain>"
    log_warn "  4. Install SSL: $0 install-ssl <domain>"
}

# Uninitialize server
uninit_server() {
    local remove_all="${1:-no}"
    
    log_step "Uninitializing CineStream server..."
    
    check_root
    
    log_warn "This will remove all CineStream components"
    if [[ "$remove_all" != "yes" ]]; then
        log_warn "MongoDB and Nginx will be preserved"
        log_warn "To remove everything, run: $0 uninit-server yes"
    fi
    
    # Stop all application services
    for service in /etc/systemd/system/${APP_NAME}@*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl stop "${service_name}" 2>/dev/null || true
            systemctl disable "${service_name}" 2>/dev/null || true
        fi
    done
    
    # Remove application targets and services
    for target in /etc/systemd/system/*.target; do
        if [[ -f "$target" ]] && (grep -q "Application Target" "$target" 2>/dev/null || grep -q "CineStream" "$target" 2>/dev/null); then
            local target_name=$(basename "$target" .target)
            systemctl stop "${target_name}.target" 2>/dev/null || true
            systemctl disable "${target_name}.target" 2>/dev/null || true
            rm -f "$target"
        fi
    done
    
    # Remove CPU affinity services
    systemctl stop cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl stop cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.service 2>/dev/null || true
    rm -f /etc/systemd/system/cinestream-cpu-affinity.service
    rm -f /etc/systemd/system/cinestream-cpu-affinity.timer
    
    # Remove Nginx configurations
    rm -f /etc/nginx/conf.d/${APP_NAME}.conf
    rm -f /etc/nginx/conf.d/*.conf  # Remove all app configs
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx.service 2>/dev/null || true
    
    # Remove application directories
    rm -rf /var/www/${APP_NAME}
    rm -rf /var/www/*/  # Remove all app directories
    
    # Remove CPU affinity script
    rm -f /usr/local/bin/cinestream-set-cpu-affinity.sh
    
    # Remove systemd service files
    rm -f /etc/systemd/system/${APP_NAME}@.service
    rm -f /etc/systemd/system/${APP_NAME}-startup.service
    rm -f /etc/systemd/system/cinestream.target
    
    systemctl daemon-reload
    
    # Remove MongoDB and Nginx if requested
    if [[ "$remove_all" == "yes" ]]; then
        read -p "Remove MongoDB? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            systemctl stop mongodb.service 2>/dev/null || true
            systemctl disable mongodb.service 2>/dev/null || true
            rm -f /etc/systemd/system/mongodb.service
            rm -rf /opt/mongodb
            log_info "MongoDB removed"
        fi
        
        read -p "Remove Nginx? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            systemctl stop nginx.service 2>/dev/null || true
            systemctl disable nginx.service 2>/dev/null || true
            pacman -Rns nginx --noconfirm 2>/dev/null || true
            log_info "Nginx removed"
        fi
    fi
    
    log_info "Server uninitialized (SSH preserved)"
}

# Status check
show_status() {
    log_step "CineStream Server Status"
    
    echo ""
    echo "=== Services ==="
    systemctl is-active mongodb.service >/dev/null && echo -e "MongoDB: ${GREEN}running${NC}" || echo -e "MongoDB: ${RED}stopped${NC}"
    systemctl is-active nginx.service >/dev/null && echo -e "Nginx: ${GREEN}running${NC}" || echo -e "Nginx: ${RED}stopped${NC}"
    
    echo ""
    echo "=== Application Workers ==="
    for app_dir in /var/www/*/; do
        if [[ -f "${app_dir}/.deploy_config" ]]; then
            source "${app_dir}/.deploy_config"
            local running=0
            for port in $(seq ${START_PORT} ${END_PORT}); do
                if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
                    ((running++))
                fi
            done
            echo -e "${APP_NAME}: ${running}/${WORKER_COUNT} workers running (ports ${START_PORT}-${END_PORT})"
            if [[ -n "$DOMAIN" ]]; then
                echo "  Domain: ${DOMAIN}"
            fi
        fi
    done
    
    echo ""
    echo "=== CPU Affinity ==="
    systemctl is-active cinestream-cpu-affinity.timer >/dev/null && echo -e "CPU Affinity Timer: ${GREEN}active${NC}" || echo -e "CPU Affinity Timer: ${RED}inactive${NC}"
    
    echo ""
    echo "=== Firewall ==="
    firewall-cmd --list-services 2>/dev/null | grep -q ssh && echo -e "SSH: ${GREEN}allowed${NC}" || echo -e "SSH: ${RED}blocked${NC}"
    firewall-cmd --list-services 2>/dev/null | grep -q http && echo -e "HTTP: ${GREEN}allowed${NC}" || echo -e "HTTP: ${RED}blocked${NC}"
    firewall-cmd --list-services 2>/dev/null | grep -q https && echo -e "HTTPS: ${GREEN}allowed${NC}" || echo -e "HTTPS: ${RED}blocked${NC}"
}

# Start all services
start_all() {
    log_step "Starting all services..."
    systemctl start mongodb.service
    systemctl start nginx.service
    for target in /etc/systemd/system/*.target; do
        if [[ -f "$target" ]] && grep -q "Application Target" "$target" 2>/dev/null; then
            local target_name=$(basename "$target" .target)
            systemctl start "${target_name}.target" 2>/dev/null || true
        fi
    done
    log_info "All services started"
}

# Stop all services
stop_all() {
    log_step "Stopping all services..."
    for target in /etc/systemd/system/*.target; do
        if [[ -f "$target" ]] && grep -q "Application Target" "$target" 2>/dev/null; then
            local target_name=$(basename "$target" .target)
            systemctl stop "${target_name}.target" 2>/dev/null || true
        fi
    done
    systemctl stop nginx.service
    systemctl stop mongodb.service
    log_info "All services stopped"
}

# Main command dispatcher
main() {
    case "${1:-}" in
        init-server)
            init_server
            ;;
        uninit-server)
            uninit_server "${2:-no}"
            ;;
        set-domain)
            check_root
            set_domain "${2:-}" "${3:-${APP_NAME}}"
            ;;
        install-ssl)
            check_root
            install_ssl "${2:-}" "${3:-${APP_NAME}}"
            ;;
        status)
            show_status
            ;;
        start-all)
            check_root
            start_all
            ;;
        stop-all)
            check_root
            stop_all
            ;;
        enable-autostart)
            check_root
            enable_autostart
            ;;
        *)
            echo "CineStream Deployment Script"
            echo ""
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  init-server              Initialize server and deploy application"
            echo "  uninit-server [yes]     Remove all components (preserves MongoDB/Nginx unless 'yes')"
            echo "  set-domain <domain>      Configure domain name for application"
            echo "  install-ssl <domain>    Install SSL certificate for domain"
            echo "  status                  Show server status"
            echo "  start-all               Start all services"
            echo "  stop-all                Stop all services"
            echo "  enable-autostart        Enable autostart for all services"
            echo ""
            exit 1
            ;;
    esac
}

main "$@"

