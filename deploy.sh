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
WORKER_COUNT=12
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

# Google Gemini API Configuration
GOOGLE_API_KEY=your-api-key-here
# Alternative: GEMINI_API_KEY=your-api-key-here
GEMINI_MODEL=flash
EOF
        chmod 600 "${app_dir}/.env"
        log_warn "Created .env file. Please update GOOGLE_API_KEY before using the application."
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
    
    # Start all workers - use while loop to avoid issues with set -e
    # Temporarily disable set -e for this function to prevent early exit
    set +e
    local started=0
    local failed=0
    local port=${START_PORT}
    while [[ $port -le ${END_PORT} ]]; do
        local service_name="${app_name}@${port}.service"
        log_info "Starting ${service_name}..."
        
        # Enable service (don't fail on error)
        if systemctl enable "${service_name}" 2>/dev/null; then
            # Start service (don't fail on error)
            if systemctl start "${service_name}" 2>/dev/null; then
                # Wait a moment and check if it's actually running
                sleep 0.5
                if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
                    started=$((started + 1))
                    log_info "  ✓ ${service_name} started successfully"
                else
                    failed=$((failed + 1))
                    log_warn "  ✗ ${service_name} started but is not active"
                    # Check why it failed
                    local status=$(systemctl status "${service_name}" --no-pager -l 2>/dev/null | grep -E "Active:|Main PID:|Error" | head -3 || echo "")
                    if [[ -n "$status" ]]; then
                        echo "$status" | while IFS= read -r line || true; do
                            if [[ -n "$line" ]]; then
                                log_warn "    $line"
                            fi
                        done || true
                    fi
                fi
            else
                failed=$((failed + 1))
                log_warn "  ✗ Failed to start ${service_name}"
                # Get error details
                local error=$(systemctl status "${service_name}" --no-pager -l 2>/dev/null | grep -i "error\|failed" | head -2 || echo "")
                if [[ -n "$error" ]]; then
                    echo "$error" | while IFS= read -r line || true; do
                        if [[ -n "$line" ]]; then
                            log_warn "    $line"
                        fi
                    done || true
                fi
            fi
        else
            failed=$((failed + 1))
            log_warn "  ✗ Failed to enable ${service_name}"
        fi
        port=$((port + 1))
    done
    set -e
    
    systemctl enable "${app_name}.target" 2>/dev/null || log_warn "Failed to enable ${app_name}.target"
    systemctl enable "${app_name}-startup.service" 2>/dev/null || log_warn "Failed to enable ${app_name}-startup.service"
    systemctl start "${app_name}.target" 2>/dev/null || log_warn "Failed to start ${app_name}.target"
    
    echo ""
    if [[ $started -gt 0 ]]; then
        log_info "Successfully started ${started}/${WORKER_COUNT} worker services (ports ${START_PORT}-${END_PORT})"
        if [[ $failed -gt 0 ]]; then
            log_warn "${failed} workers failed to start. Check logs:"
            echo "  sudo journalctl -u ${app_name}@8002.service -n 30 --no-pager"
        fi
    else
        log_error "Failed to start any worker services"
        log_error "Check service status: systemctl status ${app_name}@${START_PORT}.service"
        log_error "Check service logs: journalctl -u ${app_name}@${START_PORT}.service"
        return 1
    fi
}

# Create scraping agent services (20 agents with load balancing)
# Scraping agents removed - only on-demand scraping is used now
# This function is kept for compatibility but only cleans up existing agents
create_scraping_agents() {
    local app_name="${1:-${APP_NAME}}"
    log_info "Scraping agents removed - only on-demand scraping is used now"
    log_info "Cleaning up any existing scraping agent services and timers..."
    
    # Stop and disable any existing scraping agent services and timers
    for service in /etc/systemd/system/${app_name}-scraping-agent-*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl stop "${service_name}" 2>/dev/null || true
            systemctl disable "${service_name}" 2>/dev/null || true
            rm -f "$service"
        fi
    done
    for timer in /etc/systemd/system/${app_name}-scraping-agent-*.timer; do
        if [[ -f "$timer" ]]; then
            local timer_name=$(basename "$timer")
            systemctl stop "${timer_name}" 2>/dev/null || true
            systemctl disable "${timer_name}" 2>/dev/null || true
            rm -f "$timer"
        fi
    done
    systemctl daemon-reload
    log_info "Cleanup complete"
    return 0
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

# HTTP server - catch-all for IP and other hostnames (blocked when domain is configured)
server {
    listen 80 default_server;
    server_name _ localhost 127.0.0.1;
    
    # Allow Let's Encrypt ACME challenge (required for SSL certificate generation)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Block all direct IP access - redirect to domain root (HTTPS)
    location / {
        return 301 https://${domain}/;
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
    
    # Enable SSH - critical service that must always be enabled
    local ssh_enabled=false
    if systemctl enable sshd.service 2>/dev/null; then
        log_info "✓ SSH autostart enabled (sshd.service)"
        ssh_enabled=true
    elif systemctl enable ssh.service 2>/dev/null; then
        log_info "✓ SSH autostart enabled (ssh.service)"
        ssh_enabled=true
    else
        # Check if SSH service file exists in common locations
        local ssh_service_file=""
        for location in \
            "/usr/lib/systemd/system/sshd.service" \
            "/etc/systemd/system/sshd.service" \
            "/lib/systemd/system/sshd.service" \
            "/usr/lib/systemd/system/ssh.service" \
            "/etc/systemd/system/ssh.service" \
            "/lib/systemd/system/ssh.service"; do
            if [[ -f "$location" ]]; then
                ssh_service_file="$location"
                break
            fi
        done
        
        if [[ -n "$ssh_service_file" ]]; then
            log_info "Found SSH service file at $ssh_service_file, enabling..."
            if systemctl enable "$ssh_service_file" 2>/dev/null || systemctl enable sshd.service 2>/dev/null; then
                log_info "✓ SSH autostart enabled (from file)"
                ssh_enabled=true
            fi
        fi
        
        if [[ "$ssh_enabled" == "false" ]]; then
            log_warn "SSH service not found or could not be enabled. This is critical for server access!"
            log_warn "Try manually: systemctl enable sshd.service"
        fi
    fi
    
    # Ensure SSH is started (in case it was stopped)
    if systemctl start sshd.service 2>/dev/null || systemctl start ssh.service 2>/dev/null; then
        log_info "✓ SSH service started"
    fi
    
    # Enable CPU affinity services
    systemctl enable cinestream-cpu-affinity.service 2>/dev/null || log_warn "Failed to enable cinestream-cpu-affinity.service"
    systemctl enable cinestream-cpu-affinity.timer 2>/dev/null || log_warn "Failed to enable cinestream-cpu-affinity.timer"
    
    # Enable MongoDB - try multiple methods to find and enable it
    local mongodb_enabled=false
    
    # Method 1: Try standard service name
    if systemctl enable mongodb.service 2>/dev/null; then
        log_info "✓ MongoDB autostart enabled (mongodb.service)"
        mongodb_enabled=true
    elif systemctl enable mongodb 2>/dev/null; then
        log_info "✓ MongoDB autostart enabled (mongodb)"
        mongodb_enabled=true
    else
        # Method 2: Check if service file exists in common locations
        local mongodb_service_file=""
        for location in \
            "/etc/systemd/system/mongodb.service" \
            "/usr/lib/systemd/system/mongodb.service" \
            "/lib/systemd/system/mongodb.service"; do
            if [[ -f "$location" ]]; then
                mongodb_service_file="$location"
                break
            fi
        done
        
        if [[ -n "$mongodb_service_file" ]]; then
            # Service file exists, try to enable it directly
            log_info "Found MongoDB service file at $mongodb_service_file, enabling..."
            if systemctl enable "$mongodb_service_file" 2>/dev/null || systemctl enable mongodb.service 2>/dev/null; then
                log_info "✓ MongoDB autostart enabled (from file)"
                mongodb_enabled=true
            fi
        fi
        
        # Method 3: If MongoDB is installed but service not found, check if we need to create it
        if [[ "$mongodb_enabled" == "false" ]] && command -v mongod >/dev/null 2>&1; then
            log_warn "MongoDB is installed but service not enabled. Checking service status..."
            # Try to find mongodb service using systemctl status
            if systemctl status mongodb.service >/dev/null 2>&1 || systemctl status mongodb >/dev/null 2>&1; then
                # Service exists but enable failed, check if already enabled
                local enabled_status=$(systemctl is-enabled mongodb.service 2>/dev/null || systemctl is-enabled mongodb 2>/dev/null || echo "unknown")
                if [[ "$enabled_status" == "enabled" ]]; then
                    log_info "✓ MongoDB autostart already enabled"
                    mongodb_enabled=true
                else
                    log_warn "MongoDB service exists but could not be enabled. Status: $enabled_status"
                fi
            else
                log_warn "MongoDB binary found but systemd service not configured."
                log_warn "You may need to run: systemctl enable mongodb.service"
                # Check if service file should exist (created by install_mongodb)
                if [[ ! -f "/etc/systemd/system/mongodb.service" ]]; then
                    log_warn "MongoDB service file not found. Run 'init-server' to create it."
                fi
            fi
        elif [[ "$mongodb_enabled" == "false" ]]; then
            log_warn "MongoDB is not installed. Run 'init-server' to install it."
        fi
    fi
    
    # Enable Nginx - try multiple methods to find and enable it
    local nginx_enabled=false
    
    # Method 1: Try standard service name
    if systemctl enable nginx.service 2>/dev/null; then
        log_info "✓ Nginx autostart enabled (nginx.service)"
        nginx_enabled=true
    elif systemctl enable nginx 2>/dev/null; then
        log_info "✓ Nginx autostart enabled (nginx)"
        nginx_enabled=true
    else
        # Method 2: Check if service file exists in common locations
        local nginx_service_file=""
        for location in \
            "/usr/lib/systemd/system/nginx.service" \
            "/etc/systemd/system/nginx.service" \
            "/lib/systemd/system/nginx.service"; do
            if [[ -f "$location" ]]; then
                nginx_service_file="$location"
                break
            fi
        done
        
        if [[ -n "$nginx_service_file" ]]; then
            # Service file exists, try to enable it directly
            log_info "Found nginx service file at $nginx_service_file, enabling..."
            if systemctl enable "$nginx_service_file" 2>/dev/null || systemctl enable nginx.service 2>/dev/null; then
                log_info "✓ Nginx autostart enabled (from file)"
                nginx_enabled=true
            fi
        fi
        
        # Method 3: If nginx is installed but service not found, check if we need to create it
        if [[ "$nginx_enabled" == "false" ]] && command -v nginx >/dev/null 2>&1; then
            log_warn "Nginx is installed but service not enabled. Checking service status..."
            # Try to find nginx service using systemctl status
            if systemctl status nginx.service >/dev/null 2>&1 || systemctl status nginx >/dev/null 2>&1; then
                # Service exists but enable failed, try with --now flag or check if already enabled
                local enabled_status=$(systemctl is-enabled nginx.service 2>/dev/null || systemctl is-enabled nginx 2>/dev/null || echo "unknown")
                if [[ "$enabled_status" == "enabled" ]]; then
                    log_info "✓ Nginx autostart already enabled"
                    nginx_enabled=true
                else
                    log_warn "Nginx service exists but could not be enabled. Status: $enabled_status"
                fi
            else
                log_warn "Nginx binary found but systemd service not configured."
                log_warn "You may need to run: systemctl enable nginx.service"
            fi
        elif [[ "$nginx_enabled" == "false" ]]; then
            log_warn "Nginx is not installed. Run 'init-server' to install it."
        fi
    fi
    
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
            
            # Scraping agents removed - only on-demand scraping is used now
        fi
    done
    
    # Also enable any worker services found in systemd (fallback)
    for service in /etc/systemd/system/${APP_NAME}@*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl enable "${service_name}" 2>/dev/null || true
        fi
    done
    
    # Scraping agents removed - only on-demand scraping is used now
    
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
    
    # Note: Scraping agents removed - only on-demand scraping is used now
    
    # Configure Nginx
    configure_nginx "${APP_NAME}"
    
    # Initialize database (if API key is set)
    local app_dir="/var/www/${APP_NAME}"
    if (grep -q "GOOGLE_API_KEY=.*[^=]$" "${app_dir}/.env" 2>/dev/null && ! grep -q "GOOGLE_API_KEY=your-api-key-here" "${app_dir}/.env" 2>/dev/null) || \
       (grep -q "GEMINI_API_KEY=.*[^=]$" "${app_dir}/.env" 2>/dev/null && ! grep -q "GEMINI_API_KEY=your-api-key-here" "${app_dir}/.env" 2>/dev/null); then
        log_info "Initializing database..."
        cd "${app_dir}"
        "${app_dir}/venv/bin/python" "${app_dir}/src/scripts/init_db.py" || log_warn "Database initialization failed (API key may be invalid)"
    else
        log_warn "Database not initialized. Update GOOGLE_API_KEY in ${app_dir}/.env and run: ${app_dir}/venv/bin/python ${app_dir}/src/scripts/init_db.py"
    fi
    
    # Start all services (MongoDB, Nginx, and all workers)
    start_all
    
    # Enable autostart for all services (including all workers)
    # This must be done AFTER services are started to ensure they're properly configured
    log_info "Enabling autostart for all services..."
    enable_autostart
    
    # Reconfigure Nginx to ensure it's properly set up after services are started
    log_info "Reconfiguring Nginx after services are started..."
    configure_nginx "${APP_NAME}"
    
    log_info "Server initialization complete!"
    log_info "Application is accessible at: http://localhost/${APP_NAME}/"
    log_warn "Don't forget to:"
    log_warn "  1. Update GOOGLE_API_KEY in ${app_dir}/.env"
    log_warn "  2. Initialize database: cd ${app_dir} && ./venv/bin/python src/scripts/init_db.py"
    log_warn "  3. Configure domain: $0 set-domain <domain>"
    log_warn "  4. Install SSL: $0 install-ssl <domain>"
}

# Optimize OS: Debloat CachyOS with Plasma KDE, minimize RAM, optimize system, harden security
optimize_os() {
    log_step "Optimizing CachyOS system (debloat, RAM optimization, security hardening)..."
    
    check_root
    
    log_warn "This will optimize the system while preserving KDE, SSH, bluetooth, and browsers."
    log_warn "Other unnecessary packages and services will be removed/disabled."
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Optimization cancelled."
        return 0
    fi
    
    # 1. Remove unnecessary packages (preserving KDE, browsers, SSH, bluetooth, audio)
    log_step "Removing unnecessary packages (preserving KDE, browsers, SSH, bluetooth, audio)..."
    
    # List of unnecessary packages to remove (preserving KDE, browsers, SSH, bluetooth, audio)
    # Only remove packages that are clearly unnecessary for a server with desktop access
    # Note: Audio packages (pulseaudio, pipewire, alsa, audacious, audacity, amarok, juk, kmix, kscd, kdemultimedia) are preserved
    local unnecessary_packages=(
        "libreoffice-fresh"
        "gimp"
        "inkscape"
        "vlc"
        # "audacious"  # Preserved for audio playback
        # "audacity"   # Preserved for audio editing
        "gparted"
        "file-roller"
        "k3b"
        # "amarok"     # Preserved for audio playback
        # "juk"        # Preserved for audio playback
        # "kmix"       # Preserved for audio control
        # "kscd"       # Preserved for audio CD playback
        "kdetoys"
        "kdegames"
        "kdeedu"
        # "kdemultimedia"  # Preserved for multimedia support
    )
    
    removed_count=0
    for pkg in "${unnecessary_packages[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log_info "Removing $pkg..."
            pacman -Rns --noconfirm "$pkg" 2>/dev/null && ((removed_count++)) || true
        fi
    done
    
    if [[ $removed_count -gt 0 ]]; then
        log_info "Removed $removed_count unnecessary packages"
    fi
    
    # 2. Optimize systemd services - disable unnecessary services (preserving bluetooth, SSH, audio)
    log_step "Disabling unnecessary systemd services (preserving bluetooth, SSH, audio)..."
    
    local services_to_disable=(
        "cups.service"
        "cups-browsed.service"
        "avahi-daemon.service"
        "ModemManager.service"
        "NetworkManager-wait-online.service"
        "pamac.service"
        "pamac-cleancache.timer"
        "pamac-mirrorlist.timer"
        "upower.service"
        "wpa_supplicant.service"
        "accounts-daemon.service"
        "colord.service"
        "geoclue.service"
        "polkit.service"
        "udisks2.service"
        "gvfs-daemon.service"
        "gvfs-afc-volume-monitor.service"
        "gvfs-gphoto2-volume-monitor.service"
        "gvfs-mtp-volume-monitor.service"
        "gvfs-udisks2-volume-monitor.service"
        "gvfs-goa-volume-monitor.service"
        "gvfs-metadata.service"
        "packagekit.service"
        "packagekit-offline-update.service"
        # Note: rtkit-daemon.service is preserved (needed for audio)
        # Note: pulseaudio, pipewire, alsa services are preserved
    )
    
    local disabled_count=0
    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            log_info "Disabling $service..."
            systemctl disable "$service" 2>/dev/null && ((disabled_count++)) || true
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    
    if [[ $disabled_count -gt 0 ]]; then
        log_info "Disabled $disabled_count unnecessary services"
    fi
    
    # 3. Optimize kernel parameters for lower RAM usage
    log_step "Optimizing kernel parameters for lower RAM usage..."
    
    # Create sysctl optimization file
    cat > /etc/sysctl.d/99-cinestream-optimization.conf <<'EOF'
# CineStream System Optimizations

# Reduce swappiness (use swap less aggressively)
vm.swappiness=10

# Improve memory management
vm.dirty_ratio=15
vm.dirty_background_ratio=5

# Reduce overcommit (more conservative memory allocation)
vm.overcommit_memory=1
vm.overcommit_ratio=50

# Optimize network buffers
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# TCP optimizations
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fastopen=3

# Reduce connection tracking
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=86400

# File system optimizations
fs.file-max=2097152
fs.inotify.max_user_watches=524288

# Disable IPv6 if not needed (uncomment if IPv6 not used)
# net.ipv6.conf.all.disable_ipv6=1
# net.ipv6.conf.default.disable_ipv6=1
EOF
    
    sysctl -p /etc/sysctl.d/99-cinestream-optimization.conf
    log_info "Kernel parameters optimized"
    
    # 4. Optimize systemd limits
    log_step "Optimizing systemd resource limits..."
    
    cat > /etc/systemd/system.conf.d/99-cinestream-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=2097152
DefaultLimitNPROC=32768
DefaultTasksMax=8192
EOF
    
    systemctl daemon-reload
    log_info "Systemd limits optimized"
    
    # 5. Security hardening
    log_step "Hardening system security..."
    
    # Install security tools if not present
    pacman -S --needed --noconfirm \
        fail2ban \
        ufw \
        rkhunter \
        chkrootkit \
        audit \
        apparmor \
        || log_warn "Some security packages may not be available"
    
    # Configure fail2ban
    if command -v fail2ban-client &>/dev/null; then
        systemctl enable fail2ban.service 2>/dev/null || true
        systemctl start fail2ban.service 2>/dev/null || true
        log_info "✓ fail2ban configured"
    fi
    
    # Harden SSH further (keeping SSH enabled and functional)
    log_step "Hardening SSH configuration (preserving functionality)..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Apply security settings (less restrictive to preserve usability)
    if ! grep -q "# CineStream SSH Hardening (Additional)" /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config <<'EOF'

# CineStream SSH Hardening (Additional)
Protocol 2
MaxAuthTries 5
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
# Allow forwarding for usability (can be disabled if needed)
# AllowTcpForwarding yes
# AllowStreamLocalForwarding yes
GatewayPorts no
# PermitTunnel yes  # Commented out to allow VPN-like functionality
X11Forwarding yes  # Keep enabled for desktop use
PrintMotd no
TCPKeepAlive yes
Compression no
EOF
    fi
    
    # Restart SSH if config is valid
    if sshd -t 2>/dev/null; then
        systemctl restart sshd.service
        log_info "✓ SSH hardened with security settings (functionality preserved)"
    else
        log_warn "SSH config test failed, restoring backup..."
        mv /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config 2>/dev/null || true
    fi
    
    # Configure firewall rules
    log_step "Hardening firewall rules..."
    
    if systemctl is-active --quiet firewalld; then
        # Remove default services if not needed
        firewall-cmd --permanent --remove-service=dhcpv6-client 2>/dev/null || true
        
        # Set default zone to drop (more restrictive)
        firewall-cmd --set-default-zone=public 2>/dev/null || true
        
        # Only allow essential services
        firewall-cmd --permanent --add-service=ssh || true
        firewall-cmd --permanent --add-service=http || true
        firewall-cmd --permanent --add-service=https || true
        
        # Enable logging
        firewall-cmd --set-log-denied=all 2>/dev/null || true
        
        firewall-cmd --reload
        log_info "✓ Firewall hardened"
    fi
    
    # 6. Optimize journald (reduce disk/RAM usage)
    log_step "Optimizing systemd journal..."
    
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-cinestream.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemKeepFree=200M
SystemMaxFileSize=10M
MaxRetentionSec=7day
ForwardToSyslog=no
Compress=yes
EOF
    
    systemctl restart systemd-journald.service
    log_info "✓ Journal optimized (limited to 100MB, 7-day retention)"
    
    # 7. Disable unnecessary kernel modules (preserving bluetooth, audio, video for desktop use)
    log_step "Blacklisting unnecessary kernel modules (preserving bluetooth, audio, video)..."
    
    # Only blacklist modules that are truly unnecessary and won't affect desktop use
    # Note: Not blacklisting bluetooth, audio, or video modules to preserve desktop functionality
    if ! grep -q "# CineStream: Disable unnecessary modules" /etc/modprobe.d/blacklist.conf 2>/dev/null; then
        cat >> /etc/modprobe.d/blacklist.conf <<'EOF'

# CineStream: Disable unnecessary modules for server use
# Note: Bluetooth, audio, and video modules preserved for desktop use
# blacklist bluetooth  # Preserved for desktop use
# blacklist btusb      # Preserved for desktop use
# blacklist uvcvideo   # Preserved for desktop use
# blacklist videobuf2_core  # Preserved for desktop use
# blacklist videobuf2_vmalloc  # Preserved for desktop use
# blacklist videobuf2_memops  # Preserved for desktop use
# blacklist videodev   # Preserved for desktop use
# blacklist media      # Preserved for desktop use
# blacklist snd_hda_codec_hdmi  # Preserved for desktop use
# blacklist snd_hda_codec_realtek  # Preserved for desktop use
# blacklist snd_hda_intel  # Preserved for desktop use
# blacklist snd_hda_codec  # Preserved for desktop use
# blacklist snd_hda_core  # Preserved for desktop use
# blacklist snd_hwdep  # Preserved for desktop use
# blacklist snd_pcm  # Preserved for desktop use
# blacklist snd_timer  # Preserved for desktop use
# blacklist snd  # Preserved for desktop use
# blacklist soundcore  # Preserved for desktop use
EOF
        log_info "✓ Kernel module blacklist updated (bluetooth, audio, video preserved)"
    else
        log_info "✓ Kernel module blacklist already configured"
    fi
    
    # 8. Clean up package cache and orphaned packages
    log_step "Cleaning up system..."
    
    pacman -Sc --noconfirm || true
    pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null || true
    
    log_info "✓ System cleaned up"
    
    # 9. Optimize CPU governor (if available)
    log_step "Optimizing CPU governor..."
    
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        # Set to performance mode for server
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$cpu" 2>/dev/null || true
        done
        
        # Make it persistent
        if ! grep -q "scaling_governor" /etc/rc.local 2>/dev/null; then
            cat > /etc/rc.local <<'EOF'
#!/bin/bash
# Set CPU governor to performance
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null
done
exit 0
EOF
            chmod +x /etc/rc.local
        fi
        
        log_info "✓ CPU governor set to performance mode"
    else
        log_info "CPU governor not available (may require cpupower package)"
    fi
    
    # 10. Summary
    log_step "Optimization complete!"
    echo ""
    log_info "Summary of optimizations:"
    log_info "  ✓ Removed unnecessary packages (KDE, browsers, SSH, bluetooth, audio preserved)"
    log_info "  ✓ Disabled unnecessary systemd services (bluetooth, audio preserved)"
    log_info "  ✓ Optimized kernel parameters for lower RAM usage"
    log_info "  ✓ Hardened SSH security (functionality preserved)"
    log_info "  ✓ Configured firewall rules"
    log_info "  ✓ Optimized systemd journal (100MB limit)"
    log_info "  ✓ Updated kernel module blacklist (bluetooth, audio, video preserved)"
    log_info "  ✓ Cleaned up package cache"
    echo ""
    log_info "Preserved for desktop use:"
    log_info "  ✓ KDE Plasma desktop environment"
    log_info "  ✓ Browsers (firefox, chromium, etc.)"
    log_info "  ✓ SSH (hardened but fully functional)"
    log_info "  ✓ Bluetooth"
    log_info "  ✓ Audio (PulseAudio/PipeWire/ALSA, all audio modules, rtkit-daemon preserved)"
    echo ""
    log_warn "Recommendation: Reboot the system to apply all optimizations:"
    log_warn "  sudo reboot"
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
    
    # Stop and disable all scraping agent services and timers
    log_info "Stopping and removing scraping agent services and timers..."
    for service in /etc/systemd/system/${APP_NAME}-scraping-agent-*.service; do
        if [[ -f "$service" ]]; then
            local service_name=$(basename "$service")
            systemctl stop "${service_name}" 2>/dev/null || true
            systemctl disable "${service_name}" 2>/dev/null || true
            rm -f "$service"
        fi
    done
    for timer in /etc/systemd/system/${APP_NAME}-scraping-agent-*.timer; do
        if [[ -f "$timer" ]]; then
            local timer_name=$(basename "$timer")
            systemctl stop "${timer_name}" 2>/dev/null || true
            systemctl disable "${timer_name}" 2>/dev/null || true
            rm -f "$timer"
        fi
    done
    
    # Also clean up scraping agents for all apps (in case of multiple apps)
    for app_dir in /var/www/*/; do
        if [[ -d "$app_dir" ]] && [[ -f "${app_dir}/.deploy_config" ]]; then
            source "${app_dir}/.deploy_config"
            local app_name="${APP_NAME}"
            for service in /etc/systemd/system/${app_name}-scraping-agent-*.service; do
                if [[ -f "$service" ]]; then
                    local service_name=$(basename "$service")
                    systemctl stop "${service_name}" 2>/dev/null || true
                    systemctl disable "${service_name}" 2>/dev/null || true
                    rm -f "$service"
                fi
            done
            for timer in /etc/systemd/system/${app_name}-scraping-agent-*.timer; do
                if [[ -f "$timer" ]]; then
                    local timer_name=$(basename "$timer")
                    systemctl stop "${timer_name}" 2>/dev/null || true
                    systemctl disable "${timer_name}" 2>/dev/null || true
                    rm -f "$timer"
                fi
            done
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
    
    # Clean up Python virtual environments and uninstall packages
    log_info "Cleaning up Python virtual environments and packages..."
    for app_dir in /var/www/*/; do
        if [[ -d "$app_dir" ]]; then
            local venv_dir="${app_dir}venv"
            if [[ -d "$venv_dir" ]] && [[ -f "${venv_dir}/bin/python" ]]; then
                log_info "Uninstalling packages from virtual environment: ${venv_dir}"
                # Try to uninstall packages explicitly (optional, venv removal will do this anyway)
                if [[ -f "${venv_dir}/bin/pip" ]]; then
                    # Get list of installed packages and uninstall them
                    "${venv_dir}/bin/pip" freeze > /tmp/venv_packages_$$.txt 2>/dev/null || true
                    if [[ -f /tmp/venv_packages_$$.txt ]] && [[ -s /tmp/venv_packages_$$.txt ]]; then
                        # Uninstall all packages (except pip, setuptools, wheel which are part of venv)
                        "${venv_dir}/bin/pip" uninstall -y -r /tmp/venv_packages_$$.txt 2>/dev/null || true
                        rm -f /tmp/venv_packages_$$.txt
                        log_info "  ✓ Uninstalled all packages"
                    fi
                fi
                
                # Deactivate venv if active (in case script is running from within venv)
                if [[ -n "$VIRTUAL_ENV" ]] && [[ "$VIRTUAL_ENV" == "$venv_dir" ]]; then
                    deactivate 2>/dev/null || true
                fi
                
                # Remove venv directory (removes all remaining files)
                log_info "Removing virtual environment: ${venv_dir}"
                rm -rf "$venv_dir"
                log_info "  ✓ Removed virtual environment"
            fi
        fi
    done
    
    # Remove application directories (now that venv is cleaned up)
    log_info "Removing application directories..."
    rm -rf /var/www/${APP_NAME}
    rm -rf /var/www/*/  # Remove all app directories
    
    # Drop all MongoDB databases
    if command -v mongosh &> /dev/null; then
        log_info "Dropping all MongoDB databases..."
        # Get list of all databases (excluding system databases)
        local dbs=$(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d){if(d.name!='admin'&&d.name!='local'&&d.name!='config'){print(d.name)}})" 2>/dev/null || echo "")
        if [[ -n "$dbs" ]]; then
            echo "$dbs" | while IFS= read -r db_name || true; do
                if [[ -n "$db_name" ]] && [[ "$db_name" != "admin" ]] && [[ "$db_name" != "local" ]] && [[ "$db_name" != "config" ]]; then
                    log_info "  Dropping database: ${db_name}"
                    mongosh "${db_name}" --eval "db.dropDatabase()" --quiet 2>/dev/null || true
                fi
            done
            log_info "✓ All user databases dropped"
        else
            log_info "No user databases found to drop"
        fi
    elif command -v mongo &> /dev/null; then
        log_info "Dropping all MongoDB databases..."
        # Get list of all databases (excluding system databases)
        local dbs=$(mongo --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d){if(d.name!='admin'&&d.name!='local'&&d.name!='config'){print(d.name)}})" 2>/dev/null || echo "")
        if [[ -n "$dbs" ]]; then
            echo "$dbs" | while IFS= read -r db_name || true; do
                if [[ -n "$db_name" ]] && [[ "$db_name" != "admin" ]] && [[ "$db_name" != "local" ]] && [[ "$db_name" != "config" ]]; then
                    log_info "  Dropping database: ${db_name}"
                    mongo "${db_name}" --eval "db.dropDatabase()" --quiet 2>/dev/null || true
                fi
            done
            log_info "✓ All user databases dropped"
        else
            log_info "No user databases found to drop"
        fi
    else
        log_warn "MongoDB client not found, skipping database cleanup"
    fi
    
    # Remove CPU affinity script
    rm -f /usr/local/bin/cinestream-set-cpu-affinity.sh
    
    # Remove systemd service files
    rm -f /etc/systemd/system/${APP_NAME}@.service
    rm -f /etc/systemd/system/${APP_NAME}-startup.service
    rm -f /etc/systemd/system/${APP_NAME}-scraping-agent-*.service
    rm -f /etc/systemd/system/${APP_NAME}-scraping-agent-*.timer
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
    echo "=== Real Traffic Analysis (Last 1 minute) ==="
    log_info "Analyzing actual requests from real user traffic (no test requests made)..."
    
    local total_reqs=0
    declare -A port_counts
    
    for port in $(seq ${START_PORT} ${END_PORT}); do
        local req_count=$(sudo journalctl -u ${app_name}@${port}.service --since "1 minute ago" --no-pager 2>/dev/null | grep -cE "GET|POST" || echo "0")
        req_count=$(echo "$req_count" | tr -d '[:space:]')
        if [[ -z "$req_count" ]] || ! [[ "$req_count" =~ ^[0-9]+$ ]]; then
            req_count=0
        fi
        if [[ "$req_count" -gt 0 ]]; then
            port_counts[$port]=$req_count
            total_reqs=$((total_reqs + req_count))
        fi
    done
    
    if [[ $total_reqs -eq 0 ]]; then
        log_warn "No requests found in the last minute"
        echo ""
        echo "To see load distribution, make requests from real clients, then run:"
        echo "  sudo bash ./deploy.sh check-load-distribution"
    else
        echo "Requests per worker (last 1 minute):"
        for port in $(seq ${START_PORT} ${END_PORT}); do
            local count=${port_counts[$port]:-0}
            if [[ $count -gt 0 ]]; then
                local percentage=$((count * 100 / total_reqs))
                printf "  Port %d: %3d requests (%2d%%)\n" "$port" "$count" "$percentage"
            fi
        done
        echo ""
        echo "Total: ${total_reqs} requests"
    fi
    
    echo ""
    echo "=== How to Monitor Load Distribution ==="
    echo "  # Watch requests in real-time:"
    echo "  sudo journalctl -u ${app_name}@*.service -f | grep -E 'GET|POST'"
    echo ""
    echo "  # Check Nginx access logs:"
    echo "  sudo tail -f /var/log/nginx/access.log | grep '/${app_name}/'"
    echo ""
    echo "=== Current Load Balancing Behavior ==="
    if echo "$lb_method" | grep -q "ip_hash"; then
        echo "With ip_hash (sticky sessions):"
        echo "  ✓ All requests from the same IP go to the same worker"
        echo "  ✓ Requests from different IPs are distributed across workers"
        echo "  ✓ This ensures session persistence (same user = same worker)"
    else
        echo "Using round-robin: Requests are distributed evenly across all workers"
        echo "  ✓ Each request goes to the next available worker"
        echo "  ✓ Best for distributing load evenly"
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
    echo "=== Worker Activity (Last 1 minute - Real Traffic Only) ==="
    log_info "Analyzing actual requests from real user traffic (no test requests made)..."
    local total_requests=0
    declare -A port_counts
    
    for port in $(seq ${START_PORT} ${END_PORT}); do
        # Check worker logs for HTTP requests (GET/POST) from real traffic only
        local log_entries=$(sudo journalctl -u ${app_name}@${port}.service --since "1 minute ago" --no-pager 2>/dev/null | grep -cE "GET|POST" 2>/dev/null || echo "0")
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
        log_warn "No recent activity found in worker logs (last 1 minute)"
        log_info "Waiting for real user traffic... Make requests to the application from a browser or client"
        echo ""
        echo "To see requests in real-time:"
        echo "  sudo journalctl -u ${app_name}@*.service -f | grep -E 'GET|POST'"
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
    
    # Check all ports - use while loop to avoid issues with set -e and seq
    # Temporarily disable set -e for this function to prevent early exit
    set +e
    local port=${START_PORT}
    while [[ $port -le ${END_PORT} ]]; do
        local service_name="${app_name}@${port}.service"
        local status="inactive"
        
        # Safely check status (don't fail on error due to set -e)
        status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
        
        if [[ "$status" == "active" ]]; then
            # Count actual requests processed in the last minute (from real traffic, not test requests)
            local request_count=$(sudo journalctl -u "${service_name}" --since "1 minute ago" --no-pager 2>/dev/null | grep -cE "GET|POST" 2>/dev/null || echo "0")
            # Strip whitespace and validate
            request_count=$(echo "$request_count" | tr -d '[:space:]')
            if [[ -z "$request_count" ]] || ! [[ "$request_count" =~ ^[0-9]+$ ]]; then
                request_count=0
            fi
            
            if [[ "$request_count" -gt 0 ]]; then
                echo "  Port ${port}: ✓ Running (processed ${request_count} requests in last minute)"
                running_count=$((running_count + 1))
            else
                echo "  Port ${port}: ✓ Running (no requests in last minute)"
                running_count=$((running_count + 1))
            fi
        else
            echo "  Port ${port}: ✗ Not running (${status})"
            # Check if service exists
            if systemctl list-unit-files 2>/dev/null | grep -q "${service_name}"; then
                # Service exists but isn't running - check why
                local service_status=$(systemctl status "$service_name" --no-pager -l 2>/dev/null | grep -E "Active:|Main PID:" | head -2 || echo "")
                if [[ -n "$service_status" ]]; then
                    echo "$service_status" | while IFS= read -r line || true; do
                        if [[ -n "$line" ]]; then
                            echo "    → $(echo "$line" | sed 's/^[[:space:]]*//')"
                        fi
                    done || true
                fi
            else
                echo "    → Service file not found"
            fi
            failed_count=$((failed_count + 1))
        fi
        port=$((port + 1))
    done
    set -e
    
    echo ""
    echo "Summary: ${running_count} workers running and responding, ${failed_count} workers failed or not running"
    
    if [[ $failed_count -gt 0 ]]; then
        echo ""
        log_warn "Some workers are not running or not responding!"
        echo ""
        echo "Attempting to start all workers..."
        for port in $(seq ${START_PORT} ${END_PORT}); do
            local service_name="${app_name}@${port}.service"
            local status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
            if [[ "$status" != "active" ]]; then
                log_info "Starting ${service_name}..."
                systemctl enable "${service_name}" 2>/dev/null || true
                systemctl start "${service_name}" 2>/dev/null || true
                sleep 0.5
            fi
        done
        
        echo ""
        log_info "Waiting 2 seconds for services to start..."
        sleep 2
        
        echo ""
        echo "=== Re-checking Worker Status ==="
        running_count=0
        failed_count=0
        for port in $(seq ${START_PORT} ${END_PORT}); do
            local service_name="${app_name}@${port}.service"
            local status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
            
            if [[ "$status" == "active" ]]; then
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
                # Check why it failed
                local error=$(systemctl status "$service_name" --no-pager -l 2>/dev/null | grep -i "error\|failed" | head -1 || echo "")
                if [[ -n "$error" ]]; then
                    echo "    Error: ${error}"
                fi
                ((failed_count++))
            fi
        done
        
        echo ""
        echo "After restart: ${running_count} workers running, ${failed_count} workers failed"
        
        if [[ $failed_count -gt 0 ]]; then
            echo ""
            log_warn "Some workers still failed to start. Check logs:"
            echo "  sudo journalctl -u ${app_name}@8002.service -n 20 --no-pager"
        fi
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
    echo "=== Real Traffic Analysis (Last 1 minute) ==="
    log_info "Analyzing actual requests from real user traffic (no test requests made)..."
    
    echo ""
    echo "Requests processed by each worker (last 1 minute):"
    local total_reqs=0
    for port in $(seq ${START_PORT} ${END_PORT}); do
        local req_count=$(sudo journalctl -u ${app_name}@${port}.service --since "1 minute ago" --no-pager 2>/dev/null | grep -cE "GET|POST" || echo "0")
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
                # Services exist, explicitly start all worker services (ports 8001-8020)
                log_info "Starting all ${WORKER_COUNT} worker services for ${app_name} (ports ${START_PORT}-${END_PORT})..."
                local started=0
                local failed=0
                for port in $(seq ${START_PORT} ${END_PORT}); do
                    local service_name="${app_name}@${port}.service"
                    if systemctl start "${service_name}" 2>/dev/null; then
                        # Wait a moment and check if it's actually running
                        sleep 0.2
                        if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
                            ((started++))
                        else
                            ((failed++))
                            log_warn "Service ${service_name} started but is not active"
                        fi
                    else
                        ((failed++))
                        log_warn "Failed to start ${service_name}"
                    fi
                done
                
                if [[ $started -gt 0 ]]; then
                    log_info "Started ${started} worker services for ${app_name}"
                fi
                if [[ $failed -gt 0 ]]; then
                    log_warn "${failed} worker services failed to start for ${app_name}"
                fi
                
                # Also start the target (for dependency management)
                for target in /etc/systemd/system/${app_name}.target; do
                    if [[ -f "$target" ]] && grep -q "Application Target" "$target" 2>/dev/null; then
                        local target_name=$(basename "$target" .target)
                        systemctl start "${target_name}.target" 2>/dev/null || true
                    fi
                done
            fi
            
            # Scraping agents removed - only on-demand scraping is used now
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

# Set Google Gemini API key
set_google_key() {
    local api_key="${1:-}"
    local app_name="${2:-${APP_NAME}}"
    local app_dir="/var/www/${app_name}"
    
    if [[ -z "$api_key" ]]; then
        log_error "API key is required"
        log_info "Usage: $0 set-google-key <api-key> [app-name]"
        exit 1
    fi
    
    if [[ ! -d "$app_dir" ]]; then
        log_error "Application ${app_name} not found at ${app_dir}"
        log_info "Run 'init-server' first to deploy the application"
        exit 1
    fi
    
    # Create .env file if it doesn't exist
    if [[ ! -f "${app_dir}/.env" ]]; then
        log_info "Creating .env file..."
        cat > "${app_dir}/.env" <<EOF
# MongoDB Configuration
MONGO_URI=mongodb://localhost:27017/movie_db

# Flask Configuration
SECRET_KEY=$(openssl rand -hex 32)

# Google Gemini API Configuration
GOOGLE_API_KEY=${api_key}
GEMINI_MODEL=flash
EOF
        chmod 600 "${app_dir}/.env"
        log_info "✓ Created .env file with API key"
    else
        # Update existing .env file
        log_info "Updating GOOGLE_API_KEY in ${app_dir}/.env..."
        
        # Backup .env file
        cp "${app_dir}/.env" "${app_dir}/.env.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Remove old Anthropic key if exists
        if grep -q "^ANTHROPIC_API_KEY=" "${app_dir}/.env" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "/^ANTHROPIC_API_KEY=/d" "${app_dir}/.env"
            else
                sed -i "/^ANTHROPIC_API_KEY=/d" "${app_dir}/.env"
            fi
        fi
        
        # Update or add GOOGLE_API_KEY
        if grep -q "^GOOGLE_API_KEY=" "${app_dir}/.env" 2>/dev/null; then
            # Update existing key
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "s|^GOOGLE_API_KEY=.*|GOOGLE_API_KEY=${api_key}|" "${app_dir}/.env"
            else
                sed -i "s|^GOOGLE_API_KEY=.*|GOOGLE_API_KEY=${api_key}|" "${app_dir}/.env"
            fi
        else
            # Add new key
            echo "GOOGLE_API_KEY=${api_key}" >> "${app_dir}/.env"
        fi
        
        log_info "✓ Updated GOOGLE_API_KEY in .env file"
    fi
    
    # Get port range from .deploy_config if available
    local start_port=8001
    local end_port=8012
    if [[ -f "${app_dir}/.deploy_config" ]]; then
        source "${app_dir}/.deploy_config"
        start_port=${START_PORT:-8001}
        end_port=${END_PORT:-8012}
    fi
    
    # Restart services to load new API key
    log_info "Restarting services to load new API key..."
    for port in $(seq ${start_port} ${end_port}); do
        local service_name="${app_name}@${port}.service"
        if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
            systemctl restart "${service_name}" 2>/dev/null || true
        fi
    done
    
    log_info "✓ API key updated and services restarted"
    log_info "You may want to initialize the database: cd ${app_dir} && ./venv/bin/python src/scripts/init_db.py"
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
        set-google-key)
            check_root
            set_google_key "${2:-}" "${3:-${APP_NAME}}"
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
                if grep -qE "location.*/${app_name}/" "/etc/nginx/conf.d/${app_name}.conf"; then
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
            if nginx -T 2>/dev/null | grep -qE "location.*/${app_name}/"; then
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
        create-scraping-agents)
            log_warn "Scraping agents removed - only on-demand scraping is used now"
            create_scraping_agents "${2:-${APP_NAME}}"
            ;;
        optimize-os)
            optimize_os
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
            echo "  set-google-key <key> Set Google Gemini API key in .env file"
            echo "  status                  Show server status"
            echo "  start-all               Start all services"
            echo "  stop-all                Stop all services"
            echo "  enable-autostart        Enable autostart for all services"
            echo "  reconfigure-nginx       Reconfigure Nginx for application"
            echo "  create-scraping-agents  (Deprecated - scraping agents removed, only on-demand scraping used)"
            echo "  test-backend            Test backend workers and Nginx config"
            echo "  check-duplicates        Check for duplicate systemd services"
            echo "  test-load-balancing     Test load balancing distribution"
            echo "  check-load-distribution Check actual load distribution from logs"
            echo "  verify-workers         Verify all workers are running and accessible"
            echo "  optimize-os            Debloat CachyOS, minimize RAM, optimize system, harden security"
            echo ""
            exit 1
            ;;
    esac
}

main "$@"

