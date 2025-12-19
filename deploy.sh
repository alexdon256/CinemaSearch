#!/bin/bash

# CineStream Master Deployment Script v21.0
# Clear Linux OS Edition
# Manages multi-site deployment with Nginx, MongoDB, and Systemd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_DIR="/etc/nginx/conf.d"
SYSTEMD_DIR="/etc/systemd/system"
WWW_ROOT="/var/www"
MONGO_DATA_DIR="/opt/mongodb/data"
MONGO_LOG_DIR="/opt/mongodb/logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if running on Clear Linux
check_clear_linux() {
    if [[ ! -f /usr/lib/os-release ]] || ! grep -q "ID=clear-linux-os" /usr/lib/os-release; then
        log_warning "This script is designed for Clear Linux OS. Proceeding anyway..."
    fi
}

# Initialize server: OS updates, packages, MongoDB
init_server() {
    log_info "Initializing Clear Linux server..."
    
    # Update Clear Linux
    log_info "Updating Clear Linux OS..."
    swupd update -y || log_warning "swupd update failed, continuing..."
    
    # Install required bundles
    log_info "Installing required bundles..."
    swupd bundle-add python3-basic nginx git openssh-server dev-utils sysadmin-basic nodejs-basic -y
    
    # Install MongoDB manually (not in swupd)
    log_info "Installing MongoDB..."
    install_mongodb
    
    # Install Claude CLI globally
    log_info "Installing Claude CLI..."
    npm install -g @anthropic-ai/claude-code || log_warning "Failed to install Claude CLI, continuing..."
    
    # Create web root directory
    mkdir -p "$WWW_ROOT"
    chmod 755 "$WWW_ROOT"
    
    # Ensure Nginx directories exist
    mkdir -p "$NGINX_CONF_DIR"
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    # Start and enable MongoDB
    systemctl daemon-reload
    systemctl enable mongodb.service
    systemctl start mongodb.service
    
    # Start and enable Nginx
    systemctl enable nginx.service
    systemctl start nginx.service
    
    # Create CineStream master target for coordinated startup
    create_master_target
    
    log_success "Server initialization complete!"
    log_info "MongoDB is running on 127.0.0.1:27017"
    log_info "Nginx is configured and running"
    log_info "All services configured to auto-start on boot"
}

# Create master systemd target for coordinated startup
create_master_target() {
    log_info "Creating CineStream master startup target..."
    
    # Create a target that groups all CineStream services
    cat > "$SYSTEMD_DIR/cinestream.target" <<EOF
[Unit]
Description=CineStream Application Stack
After=network.target mongodb.service nginx.service
Wants=mongodb.service nginx.service

[Install]
WantedBy=multi-user.target
EOF

    # Create a startup service that ensures everything is running
    cat > "$SYSTEMD_DIR/cinestream-startup.service" <<EOF
[Unit]
Description=CineStream Startup Service
After=network-online.target mongodb.service nginx.service
Wants=network-online.target mongodb.service nginx.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 5 && for conf in /var/www/*/.deploy_config; do [ -f "\$conf" ] && source "\$conf" && for i in \$(seq 0 \$((PROCESS_COUNT-1))); do systemctl start "\${APP_NAME}@\$((START_PORT+i)).service" 2>/dev/null || true; done; done'
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cinestream.target
    systemctl enable cinestream-startup.service
    
    log_success "Master startup target created and enabled"
}

# Install MongoDB manually
install_mongodb() {
    local MONGO_VERSION="7.0.0"
    local MONGO_DIR="/opt/mongodb"
    local MONGO_TARBALL="mongodb-linux-x86_64-${MONGO_VERSION}.tgz"
    local MONGO_URL="https://fastdl.mongodb.org/linux/${MONGO_TARBALL}"
    
    if [[ -d "$MONGO_DIR/bin" ]]; then
        log_info "MongoDB already installed at $MONGO_DIR"
        return
    fi
    
    log_info "Downloading MongoDB ${MONGO_VERSION}..."
    cd /tmp
    wget "$MONGO_URL" || {
        log_error "Failed to download MongoDB. Please check your internet connection."
        exit 1
    }
    
    log_info "Extracting MongoDB..."
    tar -xzf "$MONGO_TARBALL"
    mv "mongodb-linux-x86_64-${MONGO_VERSION}" "$MONGO_DIR"
    rm "$MONGO_TARBALL"
    
    # Create data and log directories
    mkdir -p "$MONGO_DATA_DIR"
    mkdir -p "$MONGO_LOG_DIR"
    chown -R mongodb:mongodb "$MONGO_DATA_DIR" "$MONGO_LOG_DIR" 2>/dev/null || true
    
    # Create MongoDB user if it doesn't exist
    if ! id "mongodb" &>/dev/null; then
        useradd -r -s /bin/false mongodb || true
    fi
    
    # Create systemd service file
    cat > "$SYSTEMD_DIR/mongodb.service" <<EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.com/manual
After=network.target

[Service]
User=mongodb
Group=mongodb
Type=forking
ExecStart=$MONGO_DIR/bin/mongod --dbpath=$MONGO_DATA_DIR --logpath=$MONGO_LOG_DIR/mongod.log --logappend --fork
ExecStop=$MONGO_DIR/bin/mongod --shutdown --dbpath=$MONGO_DATA_DIR
PIDFile=$MONGO_DATA_DIR/mongod.lock
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Add MongoDB to PATH
    if ! grep -q "$MONGO_DIR/bin" /etc/profile; then
        echo "export PATH=\$PATH:$MONGO_DIR/bin" >> /etc/profile
    fi
    
    log_success "MongoDB installed successfully"
}

# Add a new site
add_site() {
    local REPO_URL="$1"
    local DOMAIN_NAME="$2"
    local APP_NAME="$3"
    local START_PORT="${4:-8001}"
    local PROCESS_COUNT="${5:-24}"
    
    log_info "Adding site: $APP_NAME for domain: $DOMAIN_NAME"
    
    # Validate inputs
    if [[ -z "$REPO_URL" || -z "$DOMAIN_NAME" || -z "$APP_NAME" ]]; then
        log_error "Usage: $0 add-site <repo_url> <domain_name> <app_name> [start_port] [process_count]"
        exit 1
    fi
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    
    # Check if app already exists
    if [[ -d "$APP_DIR" ]]; then
        log_error "Application $APP_NAME already exists at $APP_DIR"
        exit 1
    fi
    
    # Create app directory
    mkdir -p "$APP_DIR"
    cd "$APP_DIR"
    
    # Clone repository
    log_info "Cloning repository..."
    git clone "$REPO_URL" src || {
        log_error "Failed to clone repository"
        exit 1
    }
    
    # Create virtual environment
    log_info "Creating Python virtual environment..."
    python3 -m venv venv
    source venv/bin/activate
    
    # Install dependencies (check multiple locations)
    if [[ -f "src/requirements.txt" ]]; then
        log_info "Installing Python dependencies from src/requirements.txt..."
        pip install --upgrade pip
        pip install -r src/requirements.txt
    elif [[ -f "src/src/requirements.txt" ]]; then
        log_info "Installing Python dependencies from src/src/requirements.txt..."
        pip install --upgrade pip
        pip install -r src/src/requirements.txt
    else
        log_warning "No requirements.txt found, installing basic dependencies..."
        pip install --upgrade pip
        pip install flask python-dotenv pymongo anthropic gunicorn
    fi
    
    # Prompt for environment variables
    log_info "Configuring environment variables..."
    echo ""
    read -p "Enter MONGO_URI (e.g., mongodb://user:pass@127.0.0.1:27017/movie_db?authSource=admin): " MONGO_URI
    read -p "Enter ANTHROPIC_API_KEY: " ANTHROPIC_API_KEY
    read -sp "Enter SECRET_KEY (for Flask sessions): " SECRET_KEY
    echo ""
    
    # Create .env file
    cat > "$APP_DIR/.env" <<EOF
MONGO_URI=$MONGO_URI
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
SECRET_KEY=$SECRET_KEY

# Claude model selection (optional)
# Options: haiku (default, cheapest), sonnet (more capable)
CLAUDE_MODEL=haiku
EOF
    chmod 600 "$APP_DIR/.env"
    
    # Initialize database schema (check multiple locations)
    log_info "Initializing database schema..."
    if [[ -f "src/scripts/init_db.py" ]]; then
        cd src && python scripts/init_db.py || log_warning "Database initialization script failed"
        cd "$APP_DIR"
    elif [[ -f "src/src/scripts/init_db.py" ]]; then
        cd src/src && python scripts/init_db.py || log_warning "Database initialization script failed"
        cd "$APP_DIR"
    fi
    
    # Create deployment config
    cat > "$APP_DIR/.deploy_config" <<EOF
DOMAIN_NAME=$DOMAIN_NAME
APP_NAME=$APP_NAME
START_PORT=$START_PORT
PROCESS_COUNT=$PROCESS_COUNT
REPO_URL=$REPO_URL
DEPLOYED_AT=$(date -Iseconds)
EOF
    
    # Generate systemd service files
    log_info "Creating systemd services..."
    generate_systemd_services "$APP_NAME" "$START_PORT" "$PROCESS_COUNT" "$APP_DIR"
    
    # Generate Nginx configuration with SSL
    log_info "Generating Nginx configuration..."
    generate_nginx_config "$DOMAIN_NAME" "$APP_NAME" "$START_PORT" "$PROCESS_COUNT"
    
    # Setup SSL with Let's Encrypt
    log_info "Setting up SSL certificate..."
    setup_ssl "$DOMAIN_NAME"
    
    # Reload systemd and Nginx
    systemctl daemon-reload
    systemctl reload nginx || systemctl restart nginx
    
    # Start all processes
    log_info "Starting application processes..."
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        systemctl enable "${APP_NAME}@${port}.service"
        systemctl start "${APP_NAME}@${port}.service"
    done
    
    # Setup daily cron job
    setup_daily_cron "$APP_NAME" "$APP_DIR"
    
    # Ensure master startup target exists
    if [[ ! -f "$SYSTEMD_DIR/cinestream.target" ]]; then
        create_master_target
    fi
    
    log_success "Site $APP_NAME deployed successfully!"
    log_info "Domain: $DOMAIN_NAME"
    log_info "Processes: $PROCESS_COUNT (ports $START_PORT-$((START_PORT + PROCESS_COUNT - 1)))"
    log_info "App directory: $APP_DIR"
    log_info "Auto-start: ENABLED (services will start on system boot)"
}

# Generate systemd service files for each process
generate_systemd_services() {
    local APP_NAME="$1"
    local START_PORT="$2"
    local PROCESS_COUNT="$3"
    local APP_DIR="$4"
    
    # Determine the actual source directory
    local SRC_DIR="$APP_DIR/src"
    if [[ -f "$APP_DIR/src/src/main.py" ]]; then
        SRC_DIR="$APP_DIR/src/src"
    fi
    
    # Create service template
    cat > "$SYSTEMD_DIR/${APP_NAME}@.service" <<EOF
[Unit]
Description=$APP_NAME Web Worker (Port %i)
After=network.target mongodb.service

[Service]
Type=simple
User=www-data
WorkingDirectory=$SRC_DIR
Environment="PATH=$APP_DIR/venv/bin"
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/python $SRC_DIR/main.py --port %i
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Create daily refresh timer
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.service" <<EOF
[Unit]
Description=$APP_NAME Daily Data Refresh
After=network.target mongodb.service

[Service]
Type=oneshot
User=www-data
WorkingDirectory=$SRC_DIR
Environment="PATH=$APP_DIR/venv/bin"
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/python $SRC_DIR/scripts/daily_refresh.py

[Install]
WantedBy=multi-user.target
EOF
    
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.timer" <<EOF
[Unit]
Description=Daily refresh timer for $APP_NAME
Requires=${APP_NAME}-refresh.service

[Timer]
OnCalendar=daily
OnCalendar=06:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Generate Nginx configuration with sticky sessions
generate_nginx_config() {
    local DOMAIN_NAME="$1"
    local APP_NAME="$2"
    local START_PORT="$3"
    local PROCESS_COUNT="$4"
    
    local CONFIG_FILE="$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    cat > "$CONFIG_FILE" <<EOF
# Upstream backend for $APP_NAME
upstream ${APP_NAME}_backend {
    ip_hash;  # Sticky sessions
EOF
    
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        echo "    server 127.0.0.1:$port;" >> "$CONFIG_FILE"
    done
    
    cat >> "$CONFIG_FILE" <<EOF
}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    
    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Static files
    location /static/ {
        alias $WWW_ROOT/$APP_NAME/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Proxy to backend
    location / {
        proxy_pass http://${APP_NAME}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
    
    log_success "Nginx configuration created: $CONFIG_FILE"
}

# Setup SSL certificate with Let's Encrypt
setup_ssl() {
    local DOMAIN_NAME="$1"
    
    # Install certbot if not present
    if ! command -v certbot &> /dev/null; then
        log_info "Installing certbot..."
        swupd bundle-add certbot -y || {
            # Fallback: install via pip
            pip3 install certbot certbot-nginx || {
                log_error "Failed to install certbot. Please install manually."
                return 1
            }
        }
    fi
    
    # Check if certificate already exists
    if [[ -d "/etc/letsencrypt/live/$DOMAIN_NAME" ]]; then
        log_info "SSL certificate already exists for $DOMAIN_NAME"
        return 0
    fi
    
    # Obtain certificate
    log_info "Obtaining SSL certificate for $DOMAIN_NAME..."
    log_warning "Ensure DNS A record for $DOMAIN_NAME points to this server's IP"
    log_warning "Waiting 10 seconds for DNS propagation check..."
    sleep 10
    
    certbot certonly --nginx -d "$DOMAIN_NAME" -d "www.$DOMAIN_NAME" --non-interactive --agree-tos --email "admin@$DOMAIN_NAME" || {
        log_error "Failed to obtain SSL certificate. Please check DNS configuration."
        log_info "You can retry SSL setup later with: certbot certonly --nginx -d $DOMAIN_NAME"
        return 1
    }
    
    log_success "SSL certificate obtained successfully"
}

# Setup daily cron job
setup_daily_cron() {
    local APP_NAME="$1"
    local APP_DIR="$2"
    
    systemctl enable "${APP_NAME}-refresh.timer"
    systemctl start "${APP_NAME}-refresh.timer"
    
    log_success "Daily refresh timer enabled (runs at 06:00 AM)"
}

# Edit an existing site
edit_site() {
    local APP_NAME="$1"
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    
    if [[ ! -d "$APP_DIR" ]]; then
        log_error "Application $APP_NAME not found"
        exit 1
    fi
    
    # Load current config
    source "$APP_DIR/.deploy_config"
    
    log_info "Editing site: $APP_NAME"
    echo "Current configuration:"
    echo "  Domain: $DOMAIN_NAME"
    echo "  Start Port: $START_PORT"
    echo "  Process Count: $PROCESS_COUNT"
    echo ""
    
    read -p "New domain name (press Enter to keep current): " NEW_DOMAIN
    read -p "New start port (press Enter to keep current): " NEW_START_PORT
    read -p "New process count (press Enter to keep current): " NEW_PROCESS_COUNT
    
    NEW_DOMAIN="${NEW_DOMAIN:-$DOMAIN_NAME}"
    NEW_START_PORT="${NEW_START_PORT:-$START_PORT}"
    NEW_PROCESS_COUNT="${NEW_PROCESS_COUNT:-$PROCESS_COUNT}"
    
    # Stop all current processes
    log_info "Stopping current processes..."
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        systemctl stop "${APP_NAME}@${port}.service" || true
        systemctl disable "${APP_NAME}@${port}.service" || true
    done
    
    # Update config
    sed -i "s/DOMAIN_NAME=.*/DOMAIN_NAME=$NEW_DOMAIN/" "$APP_DIR/.deploy_config"
    sed -i "s/START_PORT=.*/START_PORT=$NEW_START_PORT/" "$APP_DIR/.deploy_config"
    sed -i "s/PROCESS_COUNT=.*/PROCESS_COUNT=$NEW_PROCESS_COUNT/" "$APP_DIR/.deploy_config"
    
    # Regenerate systemd services
    generate_systemd_services "$APP_NAME" "$NEW_START_PORT" "$NEW_PROCESS_COUNT" "$APP_DIR"
    
    # Regenerate Nginx config
    generate_nginx_config "$NEW_DOMAIN" "$APP_NAME" "$NEW_START_PORT" "$NEW_PROCESS_COUNT"
    
    # Setup SSL if domain changed
    if [[ "$NEW_DOMAIN" != "$DOMAIN_NAME" ]]; then
        setup_ssl "$NEW_DOMAIN"
    fi
    
    # Reload systemd and Nginx
    systemctl daemon-reload
    systemctl reload nginx
    
    # Start new processes
    log_info "Starting new processes..."
    for ((i=0; i<NEW_PROCESS_COUNT; i++)); do
        local port=$((NEW_START_PORT + i))
        systemctl enable "${APP_NAME}@${port}.service"
        systemctl start "${APP_NAME}@${port}.service"
    done
    
    log_success "Site $APP_NAME updated successfully!"
}

# Remove a site
remove_site() {
    local APP_NAME="$1"
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    
    if [[ ! -d "$APP_DIR" ]]; then
        log_error "Application $APP_NAME not found"
        exit 1
    fi
    
    # Load config
    source "$APP_DIR/.deploy_config"
    
    log_warning "This will permanently delete $APP_NAME and all its data!"
    read -p "Are you sure? Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Cancelled."
        exit 0
    fi
    
    # Stop all processes
    log_info "Stopping all processes..."
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        systemctl stop "${APP_NAME}@${port}.service" || true
        systemctl disable "${APP_NAME}@${port}.service" || true
    done
    
    # Stop and remove timer
    systemctl stop "${APP_NAME}-refresh.timer" || true
    systemctl disable "${APP_NAME}-refresh.timer" || true
    
    # Remove systemd files
    rm -f "$SYSTEMD_DIR/${APP_NAME}@.service"
    rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.service"
    rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.timer"
    
    # Remove Nginx config
    rm -f "$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    # Remove app directory
    log_info "Removing application files..."
    rm -rf "$APP_DIR"
    
    # Reload systemd and Nginx
    systemctl daemon-reload
    systemctl reload nginx
    
    log_success "Site $APP_NAME removed successfully!"
}

# Stop all services
stop_all() {
    log_info "Stopping all services..."
    
    # Stop all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            APP_NAME=$(basename "$app_dir")
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl stop "${APP_NAME}@${port}.service" || true
            done
            systemctl stop "${APP_NAME}-refresh.timer" || true
        fi
    done
    
    # Stop Nginx and MongoDB
    systemctl stop nginx.service || true
    systemctl stop mongodb.service || true
    
    log_success "All services stopped"
}

# Start all services
start_all() {
    log_info "Starting all services..."
    
    # Start MongoDB first
    systemctl start mongodb.service
    sleep 2
    
    # Start Nginx
    systemctl start nginx.service
    
    # Start all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            APP_NAME=$(basename "$app_dir")
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl start "${APP_NAME}@${port}.service" || true
            done
            systemctl start "${APP_NAME}-refresh.timer" || true
        fi
    done
    
    log_success "All services started"
}

# Main command dispatcher
main() {
    check_root
    check_clear_linux
    
    case "${1:-}" in
        init-server)
            init_server
            ;;
        add-site)
            if [[ $# -lt 4 ]]; then
                log_error "Usage: $0 add-site <repo_url> <domain_name> <app_name> [start_port] [process_count]"
                exit 1
            fi
            add_site "$2" "$3" "$4" "${5:-8001}" "${6:-24}"
            ;;
        edit-site)
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 edit-site <app_name>"
                exit 1
            fi
            edit_site "$2"
            ;;
        remove-site)
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 remove-site <app_name>"
                exit 1
            fi
            remove_site "$2"
            ;;
        stop-all)
            stop_all
            ;;
        start-all)
            start_all
            ;;
        enable-autostart)
            enable_autostart
            ;;
        status)
            show_status
            ;;
        *)
            echo "CineStream Master Deployment Script v21.0"
            echo ""
            echo "Usage: $0 <command> [arguments]"
            echo ""
            echo "Commands:"
            echo "  init-server                    Initialize Clear Linux server"
            echo "  add-site <repo> <domain> <app> [port] [count]  Add a new site"
            echo "  edit-site <app>                Edit an existing site"
            echo "  remove-site <app>              Remove a site"
            echo "  start-all                      Start all services"
            echo "  stop-all                       Stop all services"
            echo "  enable-autostart               Enable all services to start on boot"
            echo "  status                         Show status of all services"
            exit 1
            ;;
    esac
}

# Enable all services to auto-start on boot
enable_autostart() {
    log_info "Enabling all services for auto-start on boot..."
    
    # Enable core services
    systemctl enable mongodb.service 2>/dev/null || true
    systemctl enable nginx.service 2>/dev/null || true
    
    # Create master target if it doesn't exist
    if [[ ! -f "$SYSTEMD_DIR/cinestream.target" ]]; then
        create_master_target
    fi
    
    # Enable all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            APP_NAME=$(basename "$app_dir")
            
            log_info "Enabling $APP_NAME services..."
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl enable "${APP_NAME}@${port}.service" 2>/dev/null || true
            done
            
            # Enable daily refresh timer
            systemctl enable "${APP_NAME}-refresh.timer" 2>/dev/null || true
        fi
    done
    
    # Enable master target
    systemctl enable cinestream.target 2>/dev/null || true
    systemctl enable cinestream-startup.service 2>/dev/null || true
    
    systemctl daemon-reload
    
    log_success "All services enabled for auto-start on boot!"
    log_info "Run 'sudo systemctl status cinestream.target' to verify"
}

# Show status of all services
show_status() {
    echo "=== CineStream System Status ==="
    echo ""
    
    echo "--- Core Services ---"
    echo -n "MongoDB:     "
    systemctl is-active mongodb.service 2>/dev/null || echo "not installed"
    echo -n "Nginx:       "
    systemctl is-active nginx.service 2>/dev/null || echo "not installed"
    echo ""
    
    echo "--- Auto-Start Status ---"
    echo -n "MongoDB enabled:     "
    systemctl is-enabled mongodb.service 2>/dev/null || echo "no"
    echo -n "Nginx enabled:       "
    systemctl is-enabled nginx.service 2>/dev/null || echo "no"
    echo -n "CineStream target:   "
    systemctl is-enabled cinestream.target 2>/dev/null || echo "no"
    echo ""
    
    echo "--- Application Services ---"
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            APP_NAME=$(basename "$app_dir")
            
            echo "[$APP_NAME] Domain: $DOMAIN_NAME"
            
            local running=0
            local total=$PROCESS_COUNT
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
                    ((running++))
                fi
            done
            
            echo "  Processes: $running/$total running (ports $START_PORT-$((START_PORT + PROCESS_COUNT - 1)))"
            echo -n "  Auto-start: "
            systemctl is-enabled "${APP_NAME}@${START_PORT}.service" 2>/dev/null || echo "no"
            echo -n "  Daily refresh: "
            systemctl is-active "${APP_NAME}-refresh.timer" 2>/dev/null || echo "inactive"
            echo ""
        fi
    done
    
    if [[ ! -d "$WWW_ROOT" ]] || [[ -z "$(ls -A $WWW_ROOT 2>/dev/null)" ]]; then
        echo "  No applications deployed yet."
        echo ""
    fi
}

main "$@"

