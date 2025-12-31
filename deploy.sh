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
    
    # Note: yay cannot run as root, so we skip AUR and use official repos
    # Try to find MongoDB server package in official repos
    log_info "Installing MongoDB from official repositories..."
    
    MONGODB_BIN=""
    MONGOSH_BIN=""
    
    # First check if mongod already exists
    if command -v mongod &>/dev/null; then
        MONGODB_BIN=$(command -v mongod)
        MONGOSH_BIN=$(command -v mongosh 2>/dev/null || echo "")
        log_info "MongoDB already installed at: ${MONGODB_BIN}"
    elif [[ -f /usr/bin/mongod ]]; then
        MONGODB_BIN="/usr/bin/mongod"
        MONGOSH_BIN="/usr/bin/mongosh"
        log_info "Found MongoDB at: ${MONGODB_BIN}"
    elif [[ -f /opt/mongodb/bin/mongod ]]; then
        MONGODB_BIN="/opt/mongodb/bin/mongod"
        MONGOSH_BIN="/opt/mongodb/bin/mongosh"
        log_info "Found MongoDB at: ${MONGODB_BIN}"
    else
        # Try to install from repos
        if pacman -Si mongodb &>/dev/null; then
            log_info "Installing mongodb package..."
            pacman -S --needed --noconfirm mongodb
            MONGODB_BIN="/usr/bin/mongod"
            MONGOSH_BIN="/usr/bin/mongosh"
        elif pacman -Si mongodb-bin &>/dev/null; then
            log_info "Installing mongodb-bin package..."
            pacman -S --needed --noconfirm mongodb-bin
            MONGODB_BIN="/usr/bin/mongod"
            MONGOSH_BIN="/usr/bin/mongosh"
        else
            # mongodb-tools-bin was already installed (tools only)
            log_warn "MongoDB server package not found in official repos"
            log_warn "Only mongodb-tools-bin is available (tools only, no server)"
            
            # Check if mongod exists after tools installation
            if command -v mongod &>/dev/null; then
                MONGODB_BIN=$(command -v mongod)
                MONGOSH_BIN=$(command -v mongosh 2>/dev/null || echo "")
            elif [[ -f /opt/mongodb/bin/mongod ]]; then
                MONGODB_BIN="/opt/mongodb/bin/mongod"
                MONGOSH_BIN="/opt/mongodb/bin/mongosh"
            else
                log_warn "MongoDB server (mongod) not found in repos."
                log_info "Installing MongoDB via yay (AUR)..."
                
                # Use yay to install MongoDB
                if try_yay_installation; then
                    # Check if mongod is now available
                    if command -v mongod &>/dev/null; then
                        MONGODB_BIN=$(command -v mongod)
                        MONGOSH_BIN=$(command -v mongosh 2>/dev/null || echo "")
                        log_info "MongoDB installed via yay at: ${MONGODB_BIN}"
                    elif [[ -f /usr/bin/mongod ]]; then
                        MONGODB_BIN="/usr/bin/mongod"
                        MONGOSH_BIN="/usr/bin/mongosh"
                        log_info "MongoDB installed via yay at: ${MONGODB_BIN}"
                    elif [[ -f /opt/mongodb/bin/mongod ]]; then
                        MONGODB_BIN="/opt/mongodb/bin/mongod"
                        MONGOSH_BIN="/opt/mongodb/bin/mongosh"
                        log_info "MongoDB installed via yay at: ${MONGODB_BIN}"
                    else
                        log_error "yay installation completed but mongod not found."
                        install_mongodb_manual
                        return 1
                    fi
                else
                    log_error "yay installation failed."
                    install_mongodb_manual
                    return 1
                fi
            fi
        fi
    fi
    
    # Create mongodb user if it doesn't exist
    if ! id mongodb &>/dev/null; then
        log_info "Creating mongodb user..."
        useradd -r -s /bin/false -d /var/lib/mongodb mongodb 2>/dev/null || true
    fi
    
    # Create MongoDB directories
    mkdir -p /var/lib/mongodb
    mkdir -p /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true
    
    # Also create /opt/mongodb for compatibility
    mkdir -p /opt/mongodb/{data,logs}
    chown -R mongodb:mongodb /opt/mongodb 2>/dev/null || true
    
    # Detect MongoDB binary path
    if [[ -z "$MONGODB_BIN" ]]; then
        if command -v mongod &>/dev/null; then
            MONGODB_BIN=$(command -v mongod)
            MONGOSH_BIN=$(command -v mongosh 2>/dev/null || echo "")
        elif [[ -f /usr/bin/mongod ]]; then
            MONGODB_BIN="/usr/bin/mongod"
            MONGOSH_BIN="/usr/bin/mongosh"
        elif [[ -f /opt/mongodb/bin/mongod ]]; then
            MONGODB_BIN="/opt/mongodb/bin/mongod"
            MONGOSH_BIN="/opt/mongodb/bin/mongosh"
        else
            log_warn "Cannot find mongod binary, attempting automatic installation..."
            if download_and_install_mongodb; then
                MONGODB_BIN="/opt/mongodb/bin/mongod"
                MONGOSH_BIN="/opt/mongodb/bin/mongosh"
                log_info "MongoDB installed successfully at: ${MONGODB_BIN}"
            else
                log_error "Automatic MongoDB installation failed."
                install_mongodb_manual
                return 1
            fi
        fi
    fi
    
    log_info "Using MongoDB binary: ${MONGODB_BIN}"
    
    # Create or update systemd service (update to fix path if needed)
    cat > /etc/systemd/system/mongodb.service <<EOF
[Unit]
Description=MongoDB Database Server
After=network.target

[Service]
Type=simple
User=mongodb
Group=mongodb
CPUAffinity=${P_CORES}
ExecStart=${MONGODB_BIN} --dbpath=/var/lib/mongodb --logpath=/var/log/mongodb/mongod.log --logappend
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    
    # Start MongoDB
    systemctl enable mongodb.service
    systemctl start mongodb.service
    
    # Wait a moment and check if it started
    sleep 2
    if systemctl is-active --quiet mongodb.service; then
        log_info "MongoDB installed and started successfully"
    else
        log_error "MongoDB failed to start. Check logs: journalctl -u mongodb.service -n 50"
        log_error "Common issues:"
        log_error "  - Missing mongodb user: useradd -r -s /bin/false mongodb"
        log_error "  - Permission issues: chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb"
        log_error "  - Missing directories: mkdir -p /var/lib/mongodb /var/log/mongodb"
        return 1
    fi
}

# Download and install MongoDB Community Edition automatically
download_and_install_mongodb() {
    log_step "Downloading MongoDB Community Edition..."
    
    # Use latest MongoDB version (7.0.11)
    MONGODB_VERSION="7.0.11"
    MONGODB_URL="https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-${MONGODB_VERSION}.tgz"
    ARCHIVE_FILE="mongodb-linux-x86_64-${MONGODB_VERSION}.tgz"
    TEMP_DIR="/tmp/mongodb-install"
    
    # Create temp directory
    mkdir -p "${TEMP_DIR}"
    cd "${TEMP_DIR}"
    
    # Check if wget or curl is available
    if command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    elif command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    else
        log_error "Neither wget nor curl is available. Please install one: pacman -S wget"
        return 1
    fi
    
    # Download MongoDB
    log_info "Downloading MongoDB ${MONGODB_VERSION} from ${MONGODB_URL}..."
    
    if [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        # Capture error output
        ERROR_OUTPUT=$(wget --timeout=30 --tries=3 -q --show-progress "${MONGODB_URL}" 2>&1)
        WGET_EXIT=$?
        if [[ $WGET_EXIT -ne 0 ]] || [[ ! -f "${ARCHIVE_FILE}" ]]; then
            log_error "Failed to download MongoDB ${MONGODB_VERSION}"
            log_error "Error: ${ERROR_OUTPUT}"
            log_error "This could be due to:"
            log_error "  - Network connectivity issues"
            log_error "  - MongoDB download servers being unavailable"
            log_error "  - Firewall blocking the connection"
            log_error "  - Invalid URL or version"
            cd /
            rm -rf "${TEMP_DIR}"
            return 1
        fi
    else
        # curl
        ERROR_OUTPUT=$(curl -L --connect-timeout 30 --max-time 300 -f -o "${ARCHIVE_FILE}" "${MONGODB_URL}" 2>&1)
        CURL_EXIT=$?
        if [[ $CURL_EXIT -ne 0 ]] || [[ ! -f "${ARCHIVE_FILE}" ]]; then
            log_error "Failed to download MongoDB ${MONGODB_VERSION}"
            log_error "Error: ${ERROR_OUTPUT}"
            log_error "This could be due to:"
            log_error "  - Network connectivity issues"
            log_error "  - MongoDB download servers being unavailable"
            log_error "  - Firewall blocking the connection"
            log_error "  - Invalid URL or version"
            cd /
            rm -rf "${TEMP_DIR}"
            return 1
        fi
    fi
    
    log_info "Successfully downloaded MongoDB ${MONGODB_VERSION}"
    
    # Verify archive integrity
    if [[ ! -f "${ARCHIVE_FILE}" ]] || [[ ! -s "${ARCHIVE_FILE}" ]]; then
        log_error "Downloaded archive is missing or empty"
        cd /
        rm -rf "${TEMP_DIR}"
        return 1
    fi
    
    # Extract
    log_info "Extracting MongoDB ${MONGODB_VERSION}..."
    if ! tar -xzf "${ARCHIVE_FILE}" 2>/dev/null; then
        log_error "Failed to extract MongoDB archive. Archive may be corrupted."
        log_error "Archive file: ${ARCHIVE_FILE}"
        log_error "File size: $(du -h "${ARCHIVE_FILE}" | cut -f1)"
        cd /
        rm -rf "${TEMP_DIR}"
        return 1
    fi
    
    # Verify extraction
    if [[ ! -d "mongodb-linux-x86_64-${MONGODB_VERSION}" ]]; then
        log_error "Extraction directory not found"
        cd /
        rm -rf "${TEMP_DIR}"
        return 1
    fi
    
    # Move to /opt/mongodb
    log_info "Installing MongoDB to /opt/mongodb..."
    if [[ -d "/opt/mongodb" ]] && [[ ! -d "/opt/mongodb/bin" ]]; then
        # Backup existing installation if it's not a valid MongoDB install
        mv /opt/mongodb /opt/mongodb.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    elif [[ -d "/opt/mongodb" ]] && [[ -f "/opt/mongodb/bin/mongod" ]]; then
        log_info "MongoDB already installed at /opt/mongodb, skipping installation"
        cd /
        rm -rf "${TEMP_DIR}"
        return 0
    fi
    
    if ! mv "mongodb-linux-x86_64-${MONGODB_VERSION}" /opt/mongodb; then
        log_error "Failed to move MongoDB to /opt/mongodb"
        cd /
        rm -rf "${TEMP_DIR}"
        return 1
    fi
    
    # Create symlinks for easier access
    if [[ ! -f /usr/local/bin/mongod ]]; then
        ln -sf /opt/mongodb/bin/mongod /usr/local/bin/mongod 2>/dev/null || true
    fi
    if [[ ! -f /usr/local/bin/mongosh ]] && [[ -f /opt/mongodb/bin/mongosh ]]; then
        ln -sf /opt/mongodb/bin/mongosh /usr/local/bin/mongosh 2>/dev/null || true
    fi
    
    # Cleanup
    cd /
    rm -rf "${TEMP_DIR}"
    
    # Verify installation
    if [[ -f /opt/mongodb/bin/mongod ]]; then
        log_info "MongoDB installed successfully to /opt/mongodb"
        return 0
    else
        log_error "MongoDB installation verification failed"
        return 1
    fi
}

# Try to install MongoDB using yay with a non-root user
try_yay_installation() {
    log_info "Attempting to install MongoDB via yay (AUR)..."
    
    # Check if yay is available
    if ! command -v yay &>/dev/null; then
        log_warn "yay is not available"
        return 1
    fi
    
    # Find a non-root user to run yay
    NON_ROOT_USER=""
    for user in $(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}'); do
        if [[ "$user" != "root" ]] && id "$user" &>/dev/null; then
            NON_ROOT_USER="$user"
            break
        fi
    done
    
    if [[ -z "$NON_ROOT_USER" ]]; then
        log_warn "No non-root user found to run yay"
        return 1
    fi
    
    log_info "Using user '${NON_ROOT_USER}' to install MongoDB via yay..."
    log_info "Running: yay -S mongodb-bin"
    log_warn "Note: This may require sudo password. If it fails, install manually: yay -S mongodb-bin"
    
    # Run yay -S mongodb-bin directly
    # Provide answers to interactive prompts: N for cleanBuild, N for diffs
    INSTALL_OUTPUT=$(printf "N\nN\n" | su - "${NON_ROOT_USER}" -c "yay -S --noconfirm mongodb-bin 2>&1")
    INSTALL_EXIT=$?
    
    if [[ $INSTALL_EXIT -eq 0 ]]; then
        log_info "MongoDB installed successfully via yay"
        return 0
    else
        log_warn "yay installation failed (may need sudo password)"
        log_warn "Install output: ${INSTALL_OUTPUT}"
        log_warn "To install manually, run as user '${NON_ROOT_USER}': yay -S mongodb-bin"
        return 1
    fi
}

# Manual MongoDB installation fallback
install_mongodb_manual() {
    log_error ""
    log_error "=========================================="
    log_error "MongoDB Server Installation Required"
    log_error "=========================================="
    log_error ""
    log_error "The MongoDB server (mongod) is not installed."
    log_error "Only mongodb-tools-bin is available in CachyOS repos (tools only)."
    log_error ""
    log_error "To install MongoDB server manually:"
    log_error ""
    log_error "Option 1: Download and install MongoDB Community Edition"
    log_error "  1. Visit: https://www.mongodb.com/try/download/community"
    log_error "  2. Select: Linux, x86_64, tgz"
    log_error "  3. Download and extract:"
    log_error "     cd /tmp"
    log_error "     wget https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-*.tgz"
    log_error "     tar -xzf mongodb-linux-x86_64-*.tgz"
    log_error "     sudo mv mongodb-linux-x86_64-* /opt/mongodb"
    log_error "  4. Create directories:"
    log_error "     sudo mkdir -p /var/lib/mongodb /var/log/mongodb"
    log_error "     sudo chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb"
    log_error "  5. Re-run: sudo ./deploy.sh init-server"
    log_error ""
    log_error "Option 2: Use a non-root user to install via yay (AUR)"
    log_error "  1. Create a regular user (if not exists): useradd -m -s /bin/bash builduser"
    log_error "  2. Install yay as that user: cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    log_error "  3. Install MongoDB: yay -S mongodb-bin"
    log_error "  4. Re-run: sudo ./deploy.sh init-server"
    log_error ""
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
        base-devel \
        wget
    
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
    
    if [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Configuration file not found: ${app_dir}/.deploy_config"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    # Verify required variables are set
    if [[ -z "$START_PORT" ]] || [[ -z "$END_PORT" ]] || [[ -z "$WORKER_COUNT" ]]; then
        log_error "Missing required configuration: START_PORT=${START_PORT}, END_PORT=${END_PORT}, WORKER_COUNT=${WORKER_COUNT}"
        return 1
    fi
    
    # Stop and disable any existing services for this app to prevent duplicates
    log_info "Cleaning up any existing services for ${app_name}..."
    
    # Stop and disable all services for this app (any port)
    for service in /etc/systemd/system/${app_name}@*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl stop "${service_name}" 2>/dev/null || true
            systemctl disable "${service_name}" 2>/dev/null || true
        fi
    done
    
    # Also stop any running instances
    local running_services=$(systemctl list-units --all --type=service --no-pager 2>/dev/null | grep "${app_name}@" | awk '{print $1}' || true)
    if [[ -n "$running_services" ]]; then
        echo "$running_services" | while read service; do
            if [[ -n "$service" ]]; then
                systemctl stop "${service}" 2>/dev/null || true
                systemctl disable "${service}" 2>/dev/null || true
            fi
        done
    fi
    
    # Stop and disable target and startup service
    systemctl stop "${app_name}.target" 2>/dev/null || true
    systemctl disable "${app_name}.target" 2>/dev/null || true
    systemctl stop "${app_name}-startup.service" 2>/dev/null || true
    systemctl disable "${app_name}-startup.service" 2>/dev/null || true
    
    # Remove any old service files (except the template)
    rm -f /etc/systemd/system/${app_name}@[0-9]*.service 2>/dev/null || true
    
    log_info "Creating service template and target files..."
    
    # Create service template
    log_info "Writing service template to /etc/systemd/system/${app_name}@.service..."
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
    
    if [[ $? -ne 0 ]] || [[ ! -f "/etc/systemd/system/${app_name}@.service" ]]; then
        log_error "Failed to create service template"
        return 1
    fi
    
    log_info "Service template created: ${app_name}@.service"
    
    # Create target for all workers
    log_info "Writing target to /etc/systemd/system/${app_name}.target..."
    cat > /etc/systemd/system/${app_name}.target <<EOF
[Unit]
Description=${app_name} Application Target
After=mongodb.service nginx.service
Wants=${app_name}@*.service

[Install]
WantedBy=multi-user.target
EOF
    
    if [[ $? -ne 0 ]] || [[ ! -f "/etc/systemd/system/${app_name}.target" ]]; then
        log_error "Failed to create target file"
        return 1
    fi
    
    log_info "Target created: ${app_name}.target"
    
    # Create startup service
    log_info "Writing startup service to /etc/systemd/system/${app_name}-startup.service..."
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
    
    if [[ $? -ne 0 ]] || [[ ! -f "/etc/systemd/system/${app_name}-startup.service" ]]; then
        log_error "Failed to create startup service"
        return 1
    fi
    
    log_info "Startup service created: ${app_name}-startup.service"
    log_info "All service files created successfully"
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to reload systemd daemon"
        return 1
    fi
    
    log_info "Service files created successfully"
    log_info "Starting ${WORKER_COUNT} worker services (ports ${START_PORT}-${END_PORT})..."
    
    # Start all workers
    local started=0
    for port in $(seq ${START_PORT} ${END_PORT}); do
        if systemctl enable "${app_name}@${port}.service" 2>/dev/null; then
            if systemctl start "${app_name}@${port}.service" 2>/dev/null; then
                ((started++))
            else
                log_warn "Failed to start ${app_name}@${port}.service"
            fi
        else
            log_warn "Failed to enable ${app_name}@${port}.service"
        fi
    done
    
    systemctl enable "${app_name}.target" 2>/dev/null || log_warn "Failed to enable ${app_name}.target"
    systemctl enable "${app_name}-startup.service" 2>/dev/null || log_warn "Failed to enable ${app_name}-startup.service"
    systemctl start "${app_name}.target" 2>/dev/null || log_warn "Failed to start ${app_name}.target"
    
    if [[ $started -gt 0 ]]; then
        log_info "Successfully started ${started}/${WORKER_COUNT} worker services (ports ${START_PORT}-${END_PORT})"
    else
        log_error "Failed to start any worker services"
        log_error "Check service status: systemctl status ${app_name}@${START_PORT}.service"
        log_error "Check service logs: journalctl -u ${app_name}@${START_PORT}.service"
        return 1
    fi
}

# Configure Nginx
configure_nginx() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    log_step "Configuring Nginx for ${app_name}..."
    
    if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    # Ensure nginx.conf includes conf.d directory
    if ! grep -qE "include.*conf\.d|include.*conf.d" /etc/nginx/nginx.conf; then
        log_info "Adding conf.d include to nginx.conf..."
        # Create backup
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
        
        # Try to find the http block and add include inside it
        # Look for the http { line and add include after the first line inside the block
        if grep -q "^[[:space:]]*http[[:space:]]*{" /etc/nginx/nginx.conf; then
            # Add include after http { on the next line
            sed -i '/^[[:space:]]*http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        elif grep -q "^http[[:space:]]*{" /etc/nginx/nginx.conf; then
            sed -i '/^http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        else
            # If http block not found at start of line, try to find it and add after
            # Find line with "http" and add include after it
            sed -i '/http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        fi
        log_info "Added conf.d include to nginx.conf"
    fi
    
    # Check if default server block in main nginx.conf needs to be disabled
    # The default server block tries to serve static files and interferes with our proxy
    if grep -qE "server[[:space:]]*{[^#]*listen[[:space:]]+80" /etc/nginx/nginx.conf && grep -A 5 "server[[:space:]]*{" /etc/nginx/nginx.conf | grep -q "root[[:space:]]+/usr/share/nginx/html"; then
        log_warn "Default server block found in nginx.conf that may interfere with application routing"
        log_warn "Please manually comment out the default server block in /etc/nginx/nginx.conf"
        log_warn "Or ensure the 'include /etc/nginx/conf.d/*.conf;' line comes BEFORE the default server block"
    fi
    
    # Create upstream configuration
    local upstream_block=""
    for port in $(seq ${START_PORT} ${END_PORT}); do
        upstream_block="${upstream_block}    server 127.0.0.1:${port};"$'\n'
    done
    
    # Check if domain is configured
    local has_domain=false
    if [[ -n "$DOMAIN" ]] && [[ "$DOMAIN" != "" ]]; then
        has_domain=true
    fi
    
    # Create Nginx config file
    if [[ "$has_domain" == "true" ]]; then
        # Domain is configured - use set_domain config structure
        log_info "Domain ${DOMAIN} is configured, using domain-specific config"
        # Call set_domain to regenerate with domain
        set_domain "$DOMAIN" "$app_name"
        return 0
    else
        # No domain - use localhost/IP config
        cat > /etc/nginx/conf.d/${app_name}.conf <<EOF
# Upstream backend for ${app_name}
upstream ${app_name}_backend {
    # Round-robin load balancing (default - distributes requests evenly)
${upstream_block}}

# HTTP server for localhost/IP access
server {
    listen 80 default_server;
    server_name _ localhost 127.0.0.1;
    
    # Use real client IP for ip_hash (important for load balancing)
    # This ensures ip_hash uses the actual client IP, not proxy IP
    set_real_ip_from 0.0.0.0/0;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;
    
    # Redirect root to /${app_name}/ for localhost access
    location = / {
        return 301 /${app_name}/;
    }
    
    # Handle /${app_name} without trailing slash - redirect to with slash
    location = /${app_name} {
        return 301 /${app_name}/;
    }
    
    # Serve application at /${app_name}/ subpath (must be before any default location /)
    location ^~ /${app_name}/ {
        # Use proxy_pass with trailing slash to automatically strip /${app_name}/ prefix
        proxy_pass http://${app_name}_backend/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Proxy application routes that don't have /${app_name}/ prefix
    # Language switching
    location ^~ /set-language/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # API endpoints
    location ^~ /api/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Terms page
    location = /terms {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Static files (movie images)
    location ^~ /static/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
    fi
    
    # Test and start/reload Nginx
    if nginx -t; then
        if systemctl is-active --quiet nginx.service; then
            systemctl reload nginx.service
        else
            systemctl start nginx.service
        fi
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
    
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
        upstream_block="${upstream_block}    server 127.0.0.1:${port};"$'\n'
    done
    
    # Update Nginx configuration
    cat > /etc/nginx/conf.d/${app_name}.conf <<EOF
# Upstream backend for ${app_name}
upstream ${app_name}_backend {
    # Round-robin load balancing (default - distributes requests evenly)
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
    server_name _ localhost 127.0.0.1;
    
    # Redirect root to /${app_name}/ for localhost access
    location = / {
        return 301 /${app_name}/;
    }
    
    # Handle /${app_name} without trailing slash - redirect to with slash
    location = /${app_name} {
        return 301 /${app_name}/;
    }
    
    # Serve application at /${app_name}/ subpath (must be before any default location /)
    location ^~ /${app_name}/ {
        # Explicitly rewrite to strip /${app_name}/ prefix before proxying
        rewrite ^/${app_name}/(.*) /\$1 break;
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Proxy application routes that don't have /${app_name}/ prefix
    # Language switching
    location ^~ /set-language/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # API endpoints
    location ^~ /api/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Terms page
    location = /terms {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Static files (movie images)
    location ^~ /static/ {
        proxy_pass http://${app_name}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
    
    # Use real client IP for ip_hash (important for load balancing)
    set_real_ip_from 0.0.0.0/0;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;
    
    # SSL configuration (placeholders - will be updated by install-ssl)
    # ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy all requests to backend (domain access uses root path)
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
    
    # Test and start/reload Nginx
    if nginx -t; then
        if systemctl is-active --quiet nginx.service; then
            systemctl reload nginx.service
        else
            systemctl start nginx.service
        fi
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
    
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
        
    # Test and start/reload Nginx
    if nginx -t; then
        if systemctl is-active --quiet nginx.service; then
            systemctl reload nginx.service
        else
            systemctl start nginx.service
        fi
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
        
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
    
    # Enable all application targets and their worker services
    for app_dir in /var/www/*/; do
        if [[ -d "$app_dir" ]] && [[ -f "${app_dir}/.deploy_config" ]]; then
            source "${app_dir}/.deploy_config"
            local target_name="${APP_NAME}"
            
            # Enable application target
            if [[ -f "/etc/systemd/system/${target_name}.target" ]]; then
                systemctl enable "${target_name}.target" 2>/dev/null || true
            fi
            
            # Enable startup service
            if [[ -f "/etc/systemd/system/${target_name}-startup.service" ]]; then
                systemctl enable "${target_name}-startup.service" 2>/dev/null || true
            fi
            
            # Enable all worker services for this app
            log_info "Enabling autostart for ${WORKER_COUNT} ${target_name} workers (ports ${START_PORT}-${END_PORT})..."
            for port in $(seq ${START_PORT} ${END_PORT}); do
                systemctl enable "${target_name}@${port}.service" 2>/dev/null || true
            done
        fi
    done
    
    # Also enable any worker services found in systemd (fallback)
    for service in /etc/systemd/system/${APP_NAME}@*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl enable "${service_name}" 2>/dev/null || true
        fi
    done
    
    # Enable master startup target
    if [[ -f /etc/systemd/system/cinestream.target ]]; then
        systemctl enable cinestream.target 2>/dev/null || true
    fi
    
    log_info "Autostart enabled for all services and workers"
    
    # Also start all services now
    log_step "Starting all services..."
    start_all
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
    
    # Test and start/reload Nginx
    if nginx -t; then
        if systemctl is-active --quiet nginx.service; then
            systemctl reload nginx.service
        else
            systemctl start nginx.service
        fi
    else
        log_error "Nginx configuration test failed"
        return 1
    fi 2>/dev/null || true
    
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
    local apps_found=0
    for app_dir in /var/www/*/; do
        if [[ -d "$app_dir" ]] && [[ -f "${app_dir}/.deploy_config" ]]; then
            apps_found=1
            source "${app_dir}/.deploy_config"
            local running=0
            for port in $(seq ${START_PORT} ${END_PORT}); do
                if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
                    ((running++))
                fi
            done
            echo -e "${APP_NAME}: ${running}/${WORKER_COUNT} workers running (ports ${START_PORT}-${END_PORT})"
            if [[ -n "$DOMAIN" ]] && [[ "$DOMAIN" != "" ]]; then
                echo "  Domain: ${DOMAIN}"
            fi
        fi
    done
    if [[ $apps_found -eq 0 ]]; then
        echo "No applications deployed yet"
    fi
    
    echo ""
    echo "=== CPU Affinity ==="
    systemctl is-active cinestream-cpu-affinity.timer >/dev/null && echo -e "CPU Affinity Timer: ${GREEN}active${NC}" || echo -e "CPU Affinity Timer: ${RED}inactive${NC}"
    
    echo ""
    echo "=== Firewall ==="
    firewall-cmd --list-services 2>/dev/null | grep -q ssh && echo -e "SSH: ${GREEN}allowed${NC}" || echo -e "SSH: ${RED}blocked${NC}"
    firewall-cmd --list-services 2>/dev/null | grep -q http && echo -e "HTTP: ${GREEN}allowed${NC}" || echo -e "HTTP: ${RED}blocked${NC}"
    firewall-cmd --list-services 2>/dev/null | grep -q https && echo -e "HTTPS: ${GREEN}allowed${NC}" || echo -e "HTTPS: ${RED}blocked${NC}"
}

# Check for duplicate systemd services
check_duplicates() {
    local app_name="${1:-${APP_NAME}}"
    
    log_step "Checking for duplicate systemd services for ${app_name}..."
    
    echo ""
    echo "=== Checking for Duplicate Services ==="
    
    # Get all services for this app
    local services=$(systemctl list-units --all --type=service --no-pager | grep "${app_name}@" | awk '{print $1}')
    
    if [[ -z "$services" ]]; then
        log_info "No ${app_name} services found"
        return 0
    fi
    
    echo "Found services:"
    echo "$services" | while read service; do
        if [[ -n "$service" ]]; then
            local port=$(echo "$service" | sed -n 's/.*@\([0-9]*\)\.service/\1/p')
            local status=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")
            local enabled=$(systemctl is-enabled "$service" 2>/dev/null || echo "disabled")
            echo "  ${service}: ${status} (${enabled}) - Port: ${port}"
        fi
    done
    
    echo ""
    echo "=== Checking for Port Conflicts ==="
    
    # Check for multiple services on the same port
    local duplicates_found=false
    local ports_seen=""
    
    echo "$services" | while read service; do
        if [[ -n "$service" ]]; then
            local port=$(echo "$service" | sed -n 's/.*@\([0-9]*\)\.service/\1/p')
            if [[ -n "$port" ]]; then
                # Count how many services use this port
                local count=$(echo "$services" | grep "@${port}\.service" | wc -l)
                if [[ $count -gt 1 ]]; then
                    duplicates_found=true
                    log_warn "Port ${port} has ${count} services:"
                    echo "$services" | grep "@${port}\.service" | while read dup_service; do
                        echo "  - ${dup_service}"
                    done
                fi
            fi
        fi
    done
    
    # Also check by listing all ports and finding duplicates
    local port_list=$(echo "$services" | sed -n 's/.*@\([0-9]*\)\.service/\1/p' | sort -n)
    local prev_port=""
    for port in $port_list; do
        if [[ "$port" == "$prev_port" ]]; then
            duplicates_found=true
            log_warn "Duplicate port detected: ${port}"
        fi
        prev_port="$port"
    done
    
    if [[ "$duplicates_found" == "false" ]]; then
        log_info "No duplicate services found"
    else
        echo ""
        log_warn "Duplicate services detected!"
        log_warn "To fix, run: sudo ./deploy.sh init-server"
        log_warn "This will clean up and recreate all services correctly"
    fi
    
    echo ""
    echo "=== Checking Service Files ==="
    local service_files=$(ls /etc/systemd/system/${app_name}@*.service 2>/dev/null)
    if [[ -n "$service_files" ]]; then
        echo "Service files found:"
        for file in $service_files; do
            echo "  $(basename $file)"
        done
    else
        echo "No service files found in /etc/systemd/system/${app_name}@*.service"
    fi
    
    # Check for template service
    if [[ -f "/etc/systemd/system/${app_name}@.service" ]]; then
        echo ""
        log_info "Template service found: ${app_name}@.service"
    else
        log_warn "Template service NOT found: ${app_name}@.service"
    fi
}

# Test load balancing distribution
test_load_balancing() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    log_step "Testing load balancing for ${app_name}..."
    
    echo ""
    echo "=== Load Balancing Configuration ==="
    if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
        local lb_method=$(grep -A 2 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep -E "ip_hash|least_conn|fair" | head -1 | awk '{print $1}' || echo "round-robin (default)")
        echo "Load balancing method: ${lb_method}"
        
        if echo "$lb_method" | grep -q "ip_hash"; then
            echo ""
            log_info "Using ip_hash (sticky sessions)"
            log_info "Each client IP is assigned to the same backend worker"
            log_info "This ensures session persistence but limits load distribution per IP"
            echo ""
            log_warn "Note: Requests from the same IP (e.g., localhost) will always hit the same worker"
            log_warn "To test load distribution, make requests from different IPs or check access logs"
        fi
        
        local server_count=$(grep -A 25 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep "server" | wc -l)
        echo "Backend servers configured: ${server_count}"
    fi
    
    echo ""
    echo "=== Making Test Requests ==="
    echo "Making 20 requests to see load distribution..."
    echo ""
    
    local successful=0
    local total_requests=20
    
    for i in $(seq 1 $total_requests); do
        local response=$(curl -s -w "\n%{http_code}" "http://localhost/${app_name}/" 2>/dev/null)
        local http_code=$(echo "$response" | tail -1)
        
        if [[ "$http_code" == "200" ]]; then
            ((successful++))
        fi
        sleep 0.1
    done
    
    echo ""
    echo "=== Load Distribution Analysis ==="
    log_info "Made ${total_requests} requests, ${successful} successful"
    echo ""
    echo "To see which workers handled requests, check:"
    echo ""
    echo "  # Nginx access logs (shows which upstream server handled each request)"
    echo "  sudo tail -50 /var/log/nginx/access.log | grep '/${app_name}/'"
    echo ""
    echo "  # Individual worker logs (check which workers received requests)"
    echo "  for port in \$(seq ${START_PORT} ${END_PORT}); do"
    echo "    echo \"Port \$port:\";"
    echo "    sudo journalctl -u ${app_name}@\${port}.service -n 3 --no-pager | grep -i 'GET' | tail -1;"
    echo "  done"
    echo ""
    echo "=== Current Load Balancing Behavior ==="
    if echo "$lb_method" | grep -q "ip_hash"; then
        echo "With ip_hash (sticky sessions):"
        echo "  ✓ All requests from localhost (127.0.0.1) go to the same worker"
        echo "  ✓ Requests from different IPs are distributed across workers"
        echo "  ✓ This ensures session persistence (same user = same worker)"
        echo ""
        echo "To test true load distribution:"
        echo "  1. Make requests from different IPs (different clients)"
        echo "  2. Check access logs: sudo tail -f /var/log/nginx/access.log"
        echo "  3. Or change to round-robin by removing 'ip_hash;' from Nginx config"
    else
        echo "Using round-robin: Requests are distributed evenly across all workers"
    fi
}

# Check actual load distribution from Nginx logs
check_load_distribution() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    log_step "Checking load distribution for ${app_name}..."
    
    echo ""
    echo "=== Worker Activity (Last 10 minutes) ==="
    local total_requests=0
    declare -A port_counts
    
    for port in $(seq ${START_PORT} ${END_PORT}); do
        # Check worker logs for HTTP requests (GET/POST)
        local log_entries=$(sudo journalctl -u ${app_name}@${port}.service --since "10 minutes ago" --no-pager 2>/dev/null | grep -cE "GET|POST" 2>/dev/null || echo "0")
        # Strip whitespace and ensure it's a number
        log_entries=$(echo "$log_entries" | tr -d '[:space:]')
        # Default to 0 if empty or not a number
        if [[ -z "$log_entries" ]] || ! [[ "$log_entries" =~ ^[0-9]+$ ]]; then
            log_entries=0
        fi
        if [[ "$log_entries" -gt 0 ]]; then
            port_counts[$port]=$log_entries
            total_requests=$((total_requests + log_entries))
        fi
    done
    
    if [[ $total_requests -eq 0 ]]; then
        log_warn "No recent activity found in worker logs (last 10 minutes)"
        log_info "Make some requests to the application, then run this command again"
        echo ""
        echo "You can make test requests with:"
        echo "  for i in {1..20}; do curl -s http://localhost/${app_name}/ > /dev/null; done"
    else
        echo "Requests per worker:"
        # Sort ports by request count (descending)
        for port in $(seq ${START_PORT} ${END_PORT}); do
            local count=${port_counts[$port]:-0}
            if [[ $count -gt 0 ]]; then
                local percentage=$((count * 100 / total_requests))
                printf "  Port %4d: %3d requests (%2d%%)\n" "$port" "$count" "$percentage"
            fi
        done
        echo ""
        echo "Total requests across all workers: ${total_requests}"
        
        # Calculate distribution stats
        local active_workers=0
        for port in $(seq ${START_PORT} ${END_PORT}); do
            if [[ ${port_counts[$port]:-0} -gt 0 ]]; then
                ((active_workers++))
            fi
        done
        
        echo "Active workers: ${active_workers} out of ${WORKER_COUNT}"
        
        if [[ $active_workers -eq 1 ]] && echo "$lb_method" | grep -q "ip_hash"; then
            echo ""
            log_info "Only 1 worker is active (expected with ip_hash from single IP)"
            log_info "This is normal - ip_hash ensures same IP always hits same worker"
        elif [[ $active_workers -lt $WORKER_COUNT ]]; then
            echo ""
            log_warn "Only ${active_workers} workers received requests"
            log_info "With ip_hash, each unique client IP gets assigned to one worker"
        fi
    fi
    
    echo ""
    echo "=== Load Balancing Method ==="
    if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
        local lb_method=$(grep -A 2 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep -E "ip_hash|least_conn|fair" | head -1 | awk '{print $1}' || echo "round-robin (default)")
        echo "Method: ${lb_method}"
        
        if echo "$lb_method" | grep -q "ip_hash"; then
            echo ""
            log_info "Using ip_hash (sticky sessions)"
            log_info "Each client IP is assigned to the same backend worker"
            log_info "To see true load distribution, make requests from different IPs"
        fi
    fi
    
    echo ""
    echo "=== Real-time Monitoring ==="
    echo "To watch requests in real-time:"
    echo "  sudo journalctl -u ${app_name}@*.service -f | grep -E 'GET|POST'"
    echo ""
    echo "To check a specific worker:"
    echo "  sudo journalctl -u ${app_name}@8001.service -f"
    echo ""
    echo "To see Nginx access logs:"
    echo "  sudo tail -f /var/log/nginx/access.log | grep '/${app_name}/'"
}

# Verify all workers are running and accessible
verify_workers() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    log_step "Verifying workers for ${app_name}..."
    
    echo ""
    echo "=== Worker Status ==="
    local running_count=0
    local failed_count=0
    
    for port in $(seq ${START_PORT} ${END_PORT}); do
        local service_name="${app_name}@${port}.service"
        local status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
        
        if [[ "$status" == "active" ]]; then
            # Test if the worker actually responds
            local response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
            if [[ "$response" == "200" ]]; then
                echo "  Port ${port}: ✓ Running and responding (HTTP ${response})"
                ((running_count++))
            else
                echo "  Port ${port}: ⚠ Running but not responding (HTTP ${response})"
                ((failed_count++))
            fi
        else
            echo "  Port ${port}: ✗ Not running (${status})"
            ((failed_count++))
        fi
    done
    
    echo ""
    echo "Summary: ${running_count} workers running and responding, ${failed_count} workers failed or not running"
    
    if [[ $failed_count -gt 0 ]]; then
        echo ""
        log_warn "Some workers are not running or not responding!"
        log_info "To restart all workers: sudo systemctl restart ${app_name}.target"
    fi
    
    echo ""
    echo "=== Nginx Upstream Configuration ==="
    if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
        local upstream_servers=$(grep -A 25 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep "server" | wc -l)
        echo "Upstream servers configured: ${upstream_servers}"
        
        local lb_method=$(grep -A 2 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep -E "ip_hash|least_conn|fair" | head -1 | awk '{print $1}' || echo "round-robin (default)")
        echo "Load balancing method: ${lb_method}"
        
        if [[ "$upstream_servers" != "${WORKER_COUNT}" ]]; then
            log_warn "Mismatch: ${upstream_servers} upstream servers configured but ${WORKER_COUNT} workers expected"
            log_info "Regenerate Nginx config: sudo bash ./deploy.sh reconfigure-nginx"
        fi
    else
        log_error "Nginx config not found: /etc/nginx/conf.d/${app_name}.conf"
        log_info "Generate config: sudo bash ./deploy.sh reconfigure-nginx"
    fi
    
    echo ""
    echo "=== Testing Load Distribution ==="
    log_info "Making 20 test requests to see distribution..."
    
    for i in {1..20}; do
        curl -s -o /dev/null "http://localhost/${app_name}/" 2>/dev/null
        sleep 0.1
    done
    
    echo ""
    echo "Checking which workers handled requests (last 30 seconds):"
    local total_reqs=0
    for port in $(seq ${START_PORT} ${END_PORT}); do
        local req_count=$(sudo journalctl -u ${app_name}@${port}.service --since "30 seconds ago" --no-pager 2>/dev/null | grep -cE "GET|POST" || echo "0")
        # Strip whitespace and validate
        req_count=$(echo "$req_count" | tr -d '[:space:]')
        if [[ -z "$req_count" ]] || ! [[ "$req_count" =~ ^[0-9]+$ ]]; then
            req_count=0
        fi
        if [[ "$req_count" -gt 0 ]]; then
            echo "  Port ${port}: ${req_count} requests"
            total_reqs=$((total_reqs + req_count))
        fi
    done
    
    if [[ $total_reqs -eq 0 ]]; then
        log_warn "No requests found in worker logs"
        log_info "Make sure you're accessing the application and check again"
    else
        echo ""
        echo "Total requests: ${total_reqs}"
        if [[ $total_reqs -lt 10 ]]; then
            log_warn "Only ${total_reqs} requests found - make more requests to see distribution"
        fi
    fi
}

# Test backend connectivity
test_backend() {
    local app_name="${1:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        return 1
    fi
    
    source "${app_dir}/.deploy_config"
    
    log_step "Testing backend for ${app_name}..."
    
    echo ""
    echo "=== Backend Workers ==="
    local running=0
    local total=0
    for port in $(seq ${START_PORT} ${END_PORT}); do
        ((total++))
        if systemctl is-active --quiet "${app_name}@${port}.service" 2>/dev/null; then
            ((running++))
            echo -e "Port ${port}: ${GREEN}running${NC}"
            
            # Test HTTP connection
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
            if echo "$HTTP_CODE" | grep -qE "200|301|302"; then
                echo "  → HTTP test: ${GREEN}OK${NC} (${HTTP_CODE})"
            else
                echo "  → HTTP test: ${RED}FAILED${NC} (${HTTP_CODE})"
            fi
        else
            echo -e "Port ${port}: ${RED}stopped${NC}"
        fi
    done
    
    echo ""
    echo "Summary: ${running}/${total} workers running"
    
    if [[ $running -eq 0 ]]; then
        log_error "No workers are running! Start them with: sudo ./deploy.sh start-all"
        return 1
    fi
    
    echo ""
    echo "=== Nginx Configuration ==="
    if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
        echo -e "Config file: ${GREEN}exists${NC}"
        
        # Check if upstream is configured
        if grep -q "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf"; then
            echo -e "Upstream backend: ${GREEN}configured${NC}"
        else
            echo -e "Upstream backend: ${RED}missing${NC}"
        fi
        
        # Check if location block exists
        if grep -q "location /${app_name}/" "/etc/nginx/conf.d/${app_name}.conf"; then
            echo -e "Location block: ${GREEN}configured${NC}"
        else
            echo -e "Location block: ${RED}missing${NC}"
        fi
    else
        echo -e "Config file: ${RED}missing${NC}"
        log_error "Nginx config not found! Reconfigure with: sudo ./deploy.sh reconfigure-nginx"
        return 1
    fi
    
    echo ""
    echo "=== Nginx Config Details ==="
    if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
        echo "Location blocks in config:"
        grep -n "location" "/etc/nginx/conf.d/${app_name}.conf" || echo "  No location blocks found"
        echo ""
        echo "Upstream servers:"
        grep -A 20 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep "server" || echo "  No upstream servers found"
    fi
    
    echo ""
    echo "=== Test Requests ==="
    echo "Testing direct backend:"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${START_PORT}/" 2>/dev/null || echo "000")
    HTTP_BODY=$(curl -s --connect-timeout 2 "http://127.0.0.1:${START_PORT}/" 2>/dev/null | head -c 100)
    if [[ "$HTTP_CODE" =~ ^[23] ]]; then
        echo -e "  http://localhost:${START_PORT}/ → ${GREEN}${HTTP_CODE}${NC}"
        echo "  Response preview: ${HTTP_BODY:0:50}..."
    else
        echo -e "  http://localhost:${START_PORT}/ → ${RED}${HTTP_CODE}${NC}"
        if [[ "$HTTP_CODE" == "000" ]]; then
            echo "  ${RED}Connection failed - worker may not be running${NC}"
        else
            echo "  Response preview: ${HTTP_BODY:0:50}..."
        fi
    fi
    
    echo "Testing via Nginx:"
    NGINX_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost/${app_name}/" 2>/dev/null || echo "000")
    NGINX_BODY=$(curl -s --connect-timeout 2 "http://localhost/${app_name}/" 2>/dev/null | head -c 100)
    if [[ "$NGINX_CODE" =~ ^[23] ]]; then
        echo -e "  http://localhost/${app_name}/ → ${GREEN}${NGINX_CODE}${NC}"
    else
        echo -e "  http://localhost/${app_name}/ → ${RED}${NGINX_CODE}${NC}"
        echo "  Response preview: ${NGINX_BODY:0:50}..."
        echo ""
        log_warn "Nginx is returning ${NGINX_CODE}. Possible issues:"
        if [[ "$NGINX_CODE" == "404" ]]; then
            log_warn "  404 means Nginx found the location but backend returned 404"
            log_warn "  - This could mean the path stripping isn't working correctly"
            log_warn "  - Check if workers are running: sudo systemctl status ${app_name}@${START_PORT}.service"
            log_warn "  - Test backend directly: curl http://localhost:${START_PORT}/"
            log_warn "  - Check upstream configuration:"
            echo "    Upstream servers in config:"
            grep -A 25 "upstream ${app_name}_backend" "/etc/nginx/conf.d/${app_name}.conf" | grep "server" || echo "    None found"
            log_warn "  - Check Nginx error log: sudo journalctl -u nginx.service -n 50 | grep -i error"
        elif [[ "$NGINX_CODE" == "502" ]] || [[ "$NGINX_CODE" == "503" ]]; then
            log_warn "  ${NGINX_CODE} means Nginx can't connect to backend"
            log_warn "  - Workers may not be running"
            log_warn "  - Check upstream connectivity"
        else
            log_warn "  1. Nginx config not reloaded - run: sudo systemctl reload nginx"
            log_warn "  2. Config needs regeneration - run: sudo ./deploy.sh reconfigure-nginx"
        fi
        log_warn "  3. Check Nginx error logs: sudo journalctl -u nginx.service -n 50"
    fi
}

# Start all services
start_all() {
    log_step "Starting all services..."
    systemctl start mongodb.service
    systemctl start nginx.service
    
    # Check if services exist, if not, create them
    local services_created=false
    for app_dir in /var/www/*/; do
        if [[ -d "$app_dir" ]] && [[ -f "${app_dir}/.deploy_config" ]]; then
            source "${app_dir}/.deploy_config"
            local app_name="${APP_NAME}"
            
            # Check if service template exists
            if [[ ! -f "/etc/systemd/system/${app_name}@.service" ]]; then
                log_warn "Services for ${app_name} don't exist. Creating them..."
                create_worker_services "${app_name}"
                services_created=true
            else
                # Services exist, try to start them
                for target in /etc/systemd/system/${app_name}.target; do
                    if [[ -f "$target" ]] && grep -q "Application Target" "$target" 2>/dev/null; then
                        local target_name=$(basename "$target" .target)
                        systemctl start "${target_name}.target" 2>/dev/null || true
                    fi
                done
            fi
        fi
    done
    
    if [[ "$services_created" == "true" ]]; then
        log_info "Services created and started"
    else
        log_info "All services started"
    fi
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
        reconfigure-nginx)
            check_root
            local app_name="${2:-${APP_NAME}}"
            local app_dir="/var/www/${app_name}"
            
            if [[ ! -d "$app_dir" ]] || [[ ! -f "${app_dir}/.deploy_config" ]]; then
                log_error "Application ${app_name} not found at ${app_dir}"
                exit 1
            fi
            
            source "${app_dir}/.deploy_config"
            log_info "Current config: APP_NAME=${APP_NAME}, DOMAIN=${DOMAIN:-not set}, START_PORT=${START_PORT}, END_PORT=${END_PORT}"
            
            # Force regenerate config
            configure_nginx "${app_name}"
            
            # Verify the config was created correctly
            if [[ -f "/etc/nginx/conf.d/${app_name}.conf" ]]; then
                if grep -q "location /${app_name}/" "/etc/nginx/conf.d/${app_name}.conf"; then
                    log_info "Nginx config regenerated successfully with /${app_name}/ location block"
                else
                    log_error "Config file exists but location block is missing!"
                    log_error "Config file content:"
                    cat "/etc/nginx/conf.d/${app_name}.conf"
                fi
            else
                log_error "Config file was not created!"
            fi
            
            # Check what Nginx actually sees
            echo ""
            log_step "Verifying Nginx can see the config..."
            if nginx -T 2>/dev/null | grep -q "location /${app_name}/"; then
                log_info "✓ Nginx can see the location block"
            else
                log_warn "✗ Nginx cannot see the location block"
                log_warn "Checking for conflicts..."
                echo ""
                echo "All server blocks listening on port 80:"
                nginx -T 2>/dev/null | grep -B 3 "listen 80" | head -30
                echo ""
                echo "Checking main nginx.conf for includes:"
                grep -E "include|conf.d" /etc/nginx/nginx.conf | head -10
            fi
            ;;
        test-backend)
            test_backend "${2:-${APP_NAME}}"
            ;;
        check-duplicates)
            check_duplicates "${2:-${APP_NAME}}"
            ;;
        test-load-balancing)
            test_load_balancing "${2:-${APP_NAME}}"
            ;;
        check-load-distribution)
            check_load_distribution "${2:-${APP_NAME}}"
            ;;
        verify-workers)
            verify_workers "${2:-${APP_NAME}}"
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
            echo "  reconfigure-nginx       Reconfigure Nginx for application"
            echo "  test-backend            Test backend workers and Nginx config"
            echo "  check-duplicates        Check for duplicate systemd services"
            echo "  test-load-balancing     Test load balancing distribution"
            echo "  check-load-distribution Check actual load distribution from logs"
            echo "  verify-workers         Verify all workers are running and accessible"
            echo ""
            exit 1
            ;;
    esac
}

main "$@"

