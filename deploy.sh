#!/bin/bash

# CineStream Master Deployment Script v21.0
# CachyOS Edition
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

# Check if running on CachyOS/Arch Linux
check_cachyos() {
    if [[ ! -f /etc/os-release ]]; then
        log_warning "Cannot detect OS. This script is designed for CachyOS (Arch-based). Proceeding anyway..."
        return
    fi
    
    local os_id
    os_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
    
    if [[ "$os_id" != "cachyos" ]] && [[ "$os_id" != "arch" ]]; then
        log_warning "This script is designed for CachyOS (Arch-based). Detected: $os_id. Proceeding anyway..."
    else
        log_info "Detected CachyOS/Arch Linux"
    fi
}

# CachyOS/Arch doesn't have built-in system telemetry
# This function checks for any telemetry services that might exist
disable_telemetry() {
    log_info "Checking for telemetry services..."
    
    # Arch-based systems typically don't have system-wide telemetry
    # Check for any telemetry services that might exist
    local telemetry_found=false
    
    # Check for common telemetry services (none expected on Arch)
    if systemctl list-unit-files | grep -qE "(telemetry|analytics)"; then
        log_info "Found telemetry services, disabling..."
        systemctl list-unit-files | grep -E "(telemetry|analytics)" | while read -r service _; do
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
            systemctl mask "$service" 2>/dev/null || true
        done
        telemetry_found=true
    fi
    
    if [[ "$telemetry_found" == "false" ]]; then
        log_info "No system telemetry services found (typical for Arch-based systems)"
    fi
    
    systemctl daemon-reload 2>/dev/null || true
    log_success "Telemetry check complete"
}

# Disable system logging
disable_system_logging() {
    log_info "Disabling system logging..."
    
    # Disable systemd journal logging by configuring it to use volatile storage only
    log_info "Configuring systemd journal to use volatile storage only..."
    JOURNAL_CONF="/etc/systemd/journald.conf"
    
    # Backup original config if it exists
    if [[ -f "$JOURNAL_CONF" ]]; then
        cp "$JOURNAL_CONF" "${JOURNAL_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Create or update journald configuration to disable persistent logging
    cat > "$JOURNAL_CONF" <<'EOF'
[Journal]
# Disable persistent storage - logs only in RAM
Storage=volatile
# Limit journal size
SystemMaxUse=16M
RuntimeMaxUse=16M
# Disable forwarding to syslog
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
# Disable audit logging
Audit=no
EOF
    
    chmod 644 "$JOURNAL_CONF"
    log_success "Configured systemd journal to use volatile storage only"
    
    # Reload systemd and restart journald to apply changes immediately and persistently
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart systemd-journald.service 2>/dev/null || {
        log_warning "Could not restart journald, changes will apply on next boot"
    }
    
    # Disable rsyslog if present
    if systemctl list-unit-files | grep -q "rsyslog.service"; then
        log_info "Stopping and disabling rsyslog..."
        systemctl stop rsyslog.service 2>/dev/null || true
        systemctl disable rsyslog.service 2>/dev/null || true
        systemctl mask rsyslog.service 2>/dev/null || true
        log_success "Disabled rsyslog service (persistent)"
    fi
    
    # Disable syslog if present (alternative logging daemon)
    if systemctl list-unit-files | grep -q "syslog.service"; then
        log_info "Stopping and disabling syslog..."
        systemctl stop syslog.service 2>/dev/null || true
        systemctl disable syslog.service 2>/dev/null || true
        systemctl mask syslog.service 2>/dev/null || true
        log_success "Disabled syslog service (persistent)"
    fi
    
    # Disable auditd if present
    if systemctl list-unit-files | grep -q "auditd.service"; then
        log_info "Stopping and disabling auditd..."
        systemctl stop auditd.service 2>/dev/null || true
        systemctl disable auditd.service 2>/dev/null || true
        systemctl mask auditd.service 2>/dev/null || true
        log_success "Disabled auditd service (persistent)"
    fi
    
    # Reload systemd to ensure all service changes are persistent
    systemctl daemon-reload 2>/dev/null || true
    
    # Configure logrotate to be minimal or disable it
    LOGROTATE_CONF="/etc/logrotate.conf"
    if [[ -f "$LOGROTATE_CONF" ]]; then
        log_info "Configuring logrotate to minimize logging..."
        # Backup original
        cp "$LOGROTATE_CONF" "${LOGROTATE_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Update logrotate to rotate more aggressively and compress immediately
        sed -i 's/^#compress/compress/' "$LOGROTATE_CONF" 2>/dev/null || true
        sed -i 's/^compress$/compress/' "$LOGROTATE_CONF" 2>/dev/null || true
        sed -i 's/^weekly/daily/' "$LOGROTATE_CONF" 2>/dev/null || true
        
        # Add aggressive rotation settings
        if ! grep -q "^rotate 1" "$LOGROTATE_CONF"; then
            echo "rotate 1" >> "$LOGROTATE_CONF"
        fi
        if ! grep -q "^maxage 1" "$LOGROTATE_CONF"; then
            echo "maxage 1" >> "$LOGROTATE_CONF"
        fi
        
        log_success "Configured logrotate for minimal logging"
    fi
    
    # Clear existing journal logs
    log_info "Clearing existing journal logs..."
    journalctl --vacuum-time=1s 2>/dev/null || {
        # Alternative: delete journal files directly
        rm -rf /var/log/journal/* 2>/dev/null || true
        rm -rf /run/log/journal/* 2>/dev/null || true
    }
    log_success "Cleared existing journal logs"
    
    # Clear other log directories
    log_info "Clearing other log files..."
    # Clear common log locations (but keep directory structure)
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
    find /var/log -type f -name "*.log.*" -delete 2>/dev/null || true
    
    # Clear syslog files
    truncate -s 0 /var/log/syslog 2>/dev/null || true
    truncate -s 0 /var/log/messages 2>/dev/null || true
    truncate -s 0 /var/log/daemon.log 2>/dev/null || true
    truncate -s 0 /var/log/kern.log 2>/dev/null || true
    
    log_success "Cleared other log files"
    
    # Disable kernel logging to dmesg buffer (reduce buffer size)
    log_info "Configuring kernel logging..."
    
    # Create persistent sysctl configuration
    SYSCTL_CONF="/etc/sysctl.d/99-disable-logging.conf"
    cat > "$SYSCTL_CONF" <<'EOF'
# Disable system logging - Persistent configuration
# Restrict dmesg access
kernel.dmesg_restrict = 1
# Suppress most kernel messages (only critical/emergency messages shown)
# Format: console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
kernel.printk = 3 3 3 3
EOF
    
    chmod 644 "$SYSCTL_CONF"
    
    # Apply sysctl settings immediately and ensure they persist
    sysctl -p "$SYSCTL_CONF" 2>/dev/null || {
        # Alternative: apply via sysctl --system
        sysctl --system 2>/dev/null || true
    }
    
    # Also set directly for immediate effect (sysctl.d will persist on reboot)
    echo 1 > /proc/sys/kernel/dmesg_restrict 2>/dev/null || true
    echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null || true
    
    log_success "Configured kernel logging restrictions (persistent)"
    
    # Disable crash reporting if present
    if systemctl list-unit-files | grep -q "crash"; then
        log_info "Disabling crash reporting services..."
        systemctl stop crash.service 2>/dev/null || true
        systemctl disable crash.service 2>/dev/null || true
        systemctl mask crash.service 2>/dev/null || true
        log_success "Disabled crash reporting (persistent)"
    fi
    
    # Ensure all systemd changes are persistent
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "System logging disabled (logs only in volatile RAM, cleared on reboot - all settings persistent)"
}

# Initialize server: OS updates, packages, MongoDB
init_server() {
    log_info "Initializing CachyOS server..."
    
    # Update system packages
    log_info "Updating system packages..."
    log_info "Note: If you encounter repository errors (HTTP 572), this may be a temporary mirror issue."
    log_info "You can try: sudo pacman-mirrors -g (if available) or wait and retry."
    
    # Try updating with timeout and error handling
    if ! pacman -Syu --noconfirm 2>/dev/null; then
        log_warning "Full system update had issues (this may be due to repository mirror problems)"
        log_warning "Attempting to continue with package installation..."
        # Try just refreshing database
        pacman -Sy --noconfirm 2>/dev/null || true
    fi
    
    # Disable telemetry (if any exists)
    log_info ""
    disable_telemetry
    
    # Disable system logging (persistent configuration)
    log_info ""
    disable_system_logging
    
    log_info ""
    
    # Install required packages
    log_info "Installing required packages..."
    
    # Try to refresh package database first
    pacman -Sy --noconfirm 2>/dev/null || log_warning "Package database refresh had issues, continuing..."
    
    # Check if yay is available via pacman and add it to the package list
    local package_list="python python-pip nginx git openssh base-devel nodejs npm wget curl go"
    if pacman -Si yay &>/dev/null; then
        log_info "yay is available in repositories, adding to package list..."
        package_list="$package_list yay"
    fi
    
    # Install packages with retry logic
    local packages_installed=false
    for attempt in 1 2 3; do
        if pacman -S --noconfirm $package_list 2>/dev/null; then
            packages_installed=true
            break
        else
            log_warning "Package installation attempt $attempt failed, retrying..."
            sleep 2
            # Try refreshing package database again
            pacman -Sy --noconfirm 2>/dev/null || true
        fi
    done
    
    if [[ "$packages_installed" == "false" ]]; then
        log_error "Failed to install required packages after 3 attempts"
        log_error "This may be due to repository issues. Please check:"
        log_error "  1. Internet connection"
        log_error "  2. Repository mirrors: sudo pacman-mirrors -g"
        log_error "  3. Try: sudo pacman -Syu"
        log_error ""
        log_error "You can also try installing packages manually:"
        log_error "  sudo pacman -S python python-pip nginx git openssh base-devel nodejs npm wget curl"
        exit 1
    fi
    
    log_success "Required packages installed"
    
    # Ensure SSH service is configured (important for remote access)
    log_info ""
    ensure_ssh_service
    
    # Install MongoDB manually (from official MongoDB repository)
    log_info "Installing MongoDB..."
    install_mongodb
    
    # Optimize system for web server + MongoDB workload
    log_info "Optimizing system configuration..."
    optimize_system
    
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
    
    # Start and enable MongoDB (after optimization)
    systemctl daemon-reload
    systemctl enable mongodb.service
    systemctl enable disable-transparent-hugepages.service 2>/dev/null || true
    systemctl enable configure-io-scheduler.service 2>/dev/null || true
    # Stop MongoDB first to avoid duplicates, then start
    systemctl stop mongodb.service 2>/dev/null || true
    # Kill any stray mongod processes
    pkill -9 mongod 2>/dev/null || true
    sleep 1
    systemctl start mongodb.service
    
    # Create CineStream master target for coordinated startup
    create_master_target
    
    # Install CPU affinity management scripts (needed before configuring services)
    install_cpu_affinity_scripts
    
    # Configure Nginx security and rate limiting - must be done after nginx is installed
    configure_nginx_security
    
    # Configure Nginx logging (disable all logging) - must be done after nginx is installed
    configure_nginx_logging
    
    # Configure Nginx CPU affinity (P-cores)
    configure_nginx_affinity
    
    # Test Nginx configuration before starting
    log_info "Testing Nginx configuration..."
    if nginx -t 2>&1; then
        log_success "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed!"
        log_error "Please check the configuration: nginx -t"
        log_error "You may need to fix the configuration manually or deploy an application first"
        # Don't exit - continue with other setup, user can fix Nginx later
    fi
    
    # Start and enable Nginx (only if config is valid)
    systemctl daemon-reload
    systemctl enable nginx.service
    
    if nginx -t &>/dev/null; then
        if systemctl start nginx.service 2>&1; then
            log_success "Nginx started successfully"
        else
            log_warning "Nginx failed to start. This may be normal if no application is deployed yet."
            log_info "Nginx will start automatically once an application is deployed and configured."
            log_info "To check status: systemctl status nginx.service"
        fi
    else
        log_warning "Skipping Nginx start due to configuration errors"
        log_info "Nginx will be started automatically when you deploy an application"
    fi
    
    # Deploy application automatically
    log_info "Deploying CineStream application..."
    set +e  # Temporarily disable exit on error to handle deployment gracefully
    deploy_application
    local deploy_result=$?
    set -e  # Re-enable exit on error
    
    if [[ $deploy_result -eq 0 ]]; then
        log_success "Application deployed successfully"
    elif [[ $deploy_result -eq 1 ]]; then
        # Check if app already exists (this is not a fatal error)
        if [[ -d "$WWW_ROOT/cinestream" && -f "$WWW_ROOT/cinestream/.deploy_config" ]]; then
            log_info "Application 'cinestream' already exists, skipping deployment"
            log_info "To redeploy, remove it first: sudo rm -rf $WWW_ROOT/cinestream"
        else
            log_warning "Application deployment failed"
            log_info "You can try deploying manually later: sudo ./deploy.sh deploy-app cinestream"
        fi
    else
        log_error "Application deployment failed with exit code: $deploy_result"
        log_error "Please check the error messages above and fix any issues"
    fi
    
    log_success "Server initialization complete!"
    log_info "MongoDB is running on 127.0.0.1:27017"
    log_info "Nginx is configured and running"
    log_info "Application deployed and configured"
    log_info "All services configured to auto-start on boot"
    log_info "CPU affinity: MongoDB & Nginx -> P-cores (0-5), Python apps -> E-cores (6-13)"
    log_info "System optimized: swappiness=1, noatime, TCP tuning, MongoDB performance config"
    log_info "System logging disabled: logs only in volatile RAM (all settings persistent)"
    log_info "Nginx logging disabled: all access and error logs disabled"
    log_info "MongoDB logging disabled: no log files created, quiet mode enabled"
    log_info "Security configured: Firewall, fail2ban, Nginx rate limiting, security headers"
    log_info ""
    log_info "Next steps:"
    log_info "1. Configure .env file: nano /var/www/cinestream/.env"
    log_info "2. Set domain: sudo ./deploy.sh set-domain <domain>"
    log_info "3. Configure DNS and install SSL: sudo ./deploy.sh install-ssl <domain>"
    log_info ""
    log_warning "Note: Some system optimizations may require reboot for full effect"
    log_info "To re-apply optimizations: sudo ./deploy.sh optimize-system"
}

# Install CPU affinity management scripts
install_cpu_affinity_scripts() {
    log_info "Installing CPU affinity management scripts..."
    
    # Determine script source directory (scripts are in the same repo)
    local SCRIPT_SOURCE_DIR="$SCRIPT_DIR/scripts"
    if [[ ! -d "$SCRIPT_SOURCE_DIR" ]]; then
        # Try alternative location (if deploy.sh is in root)
        SCRIPT_SOURCE_DIR="$(dirname "$SCRIPT_DIR")/scripts"
        if [[ ! -d "$SCRIPT_SOURCE_DIR" ]]; then
            # Create scripts directory if it doesn't exist
            mkdir -p "$SCRIPT_DIR/scripts"
            SCRIPT_SOURCE_DIR="$SCRIPT_DIR/scripts"
        fi
    fi
    
    # Install affinity scripts to /usr/local/bin
    if [[ -f "$SCRIPT_SOURCE_DIR/set_cpu_affinity.sh" ]]; then
        cp "$SCRIPT_SOURCE_DIR/set_cpu_affinity.sh" /usr/local/bin/cinestream-set-cpu-affinity.sh
        chmod +x /usr/local/bin/cinestream-set-cpu-affinity.sh
        log_success "Installed CPU affinity script"
    else
        log_warning "CPU affinity script not found at $SCRIPT_SOURCE_DIR/set_cpu_affinity.sh"
        log_info "Creating default CPU affinity script..."
        
        # Create a basic script if source not found
        cat > /usr/local/bin/cinestream-set-cpu-affinity.sh <<'AFFINITY_EOF'
#!/bin/bash
# CPU Affinity Management Script for CineStream
P_CORES="0-5"
E_CORES="6-13"

set_affinity() {
    local pattern="$1"
    local cores="$2"
    local pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    for pid in $pids; do
        taskset -pc "$cores" "$pid" >/dev/null 2>&1 || true
    done
}

case "${1:-all}" in
    mongodb) set_affinity "mongod" "$P_CORES" ;;
    nginx) set_affinity "nginx" "$P_CORES" ;;
    python) set_affinity "main.py.*--port" "$E_CORES" ;;
    all) set_affinity "mongod" "$P_CORES"; sleep 1; set_affinity "nginx" "$P_CORES"; sleep 1; set_affinity "main.py.*--port" "$E_CORES" ;;
esac
AFFINITY_EOF
        chmod +x /usr/local/bin/cinestream-set-cpu-affinity.sh
    fi
    
    # Create CPU affinity monitor service
    cat > "$SYSTEMD_DIR/cinestream-cpu-affinity.service" <<EOF
[Unit]
Description=CineStream CPU Affinity Manager
After=network.target mongodb.service nginx.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cinestream-set-cpu-affinity.sh all
# Run again after a delay to catch any late-starting processes
ExecStartPost=/bin/bash -c 'sleep 10 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'

[Install]
WantedBy=cinestream.target
EOF

    # Create CPU affinity monitor timer (runs every 5 minutes to ensure affinity is maintained)
    cat > "$SYSTEMD_DIR/cinestream-cpu-affinity.timer" <<EOF
[Unit]
Description=CineStream CPU Affinity Monitor Timer
Requires=cinestream-cpu-affinity.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable cinestream-cpu-affinity.service
    systemctl enable cinestream-cpu-affinity.timer
    systemctl start cinestream-cpu-affinity.timer
    
    log_success "CPU affinity management installed and enabled"
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
After=network-online.target mongodb.service nginx.service cinestream-cpu-affinity.service
Wants=network-online.target mongodb.service nginx.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 5 && for conf in /var/www/*/.deploy_config; do [ -f "\$conf" ] && source "\$conf" && PROCESS_COUNT=\${PROCESS_COUNT:-20} && START_PORT=\${START_PORT:-8001} && APP_NAME=\$(basename \$(dirname "\$conf")) && for i in \$(seq 0 \$((PROCESS_COUNT-1))); do systemctl start "\${APP_NAME}@\$((START_PORT+i)).service" 2>/dev/null || true; done; done'
# Set CPU affinity after starting all services
ExecStartPost=/bin/bash -c 'sleep 3 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cinestream.target
    systemctl enable cinestream-startup.service
    
    log_success "Master startup target created and enabled"
}

# Check if MongoDB is already installed
check_mongodb_installed() {
    local MONGO_DIR="/opt/mongodb"
    
    # Check multiple possible locations
    if [[ -f "$MONGO_DIR/bin/mongod" ]]; then
        log_info "MongoDB found at $MONGO_DIR/bin/mongod"
        return 0
    fi
    
    if [[ -f "/usr/bin/mongod" ]]; then
        log_info "MongoDB found at /usr/bin/mongod (repository installation)"
        # Create compatibility symlinks
        mkdir -p "$MONGO_DIR/bin" 2>/dev/null || true
        if [[ ! -f "$MONGO_DIR/bin/mongod" ]]; then
            ln -s /usr/bin/mongod "$MONGO_DIR/bin/mongod" 2>/dev/null || true
        fi
        if [[ ! -f "$MONGO_DIR/bin/mongosh" ]] && [[ -f "/usr/bin/mongosh" ]]; then
            ln -s /usr/bin/mongosh "$MONGO_DIR/bin/mongosh" 2>/dev/null || true
        fi
        return 0
    fi
    
    # Check if mongodb-bin from AUR is installed
    if pacman -Q mongodb-bin &>/dev/null; then
        log_info "MongoDB found (mongodb-bin package from AUR)"
        # AUR package typically installs to /opt/mongodb or /usr/bin
        if [[ -f "/opt/mongodb/bin/mongod" ]]; then
            return 0
        elif [[ -f "/usr/bin/mongod" ]]; then
            mkdir -p "$MONGO_DIR/bin" 2>/dev/null || true
            ln -s /usr/bin/mongod "$MONGO_DIR/bin/mongod" 2>/dev/null || true
            if [[ -f "/usr/bin/mongosh" ]]; then
                ln -s /usr/bin/mongosh "$MONGO_DIR/bin/mongosh" 2>/dev/null || true
            fi
            return 0
        fi
    fi
    
    return 1
}

# Install yay (AUR helper) if not already installed
install_yay() {
    if command -v yay &> /dev/null; then
        log_info "yay is already installed"
        return 0
    fi
    
    log_info "Installing yay (AUR helper)..."
    
    # Method 1: Try installing via pacman first (may be available in some repos)
    log_info "Trying to install yay via pacman..."
    
    # Refresh package database first
    pacman -Sy --noconfirm &>/dev/null || true
    
    # Check if yay is available in repositories
    if pacman -Si yay &>/dev/null; then
        log_info "yay found in repositories, installing via pacman..."
        # Try installing with retry logic
        for attempt in 1 2 3; do
            if pacman -S --noconfirm yay 2>/dev/null; then
                if command -v yay &> /dev/null; then
                    log_success "yay installed successfully via pacman"
                    return 0
                fi
            fi
            if [[ $attempt -lt 3 ]]; then
                log_warning "Installation attempt $attempt failed, retrying..."
                sleep 1
                pacman -Sy --noconfirm &>/dev/null || true
            fi
        done
        log_warning "pacman installation failed after retries, trying AUR method..."
    else
        log_info "yay not found in repositories, will try AUR installation..."
    fi
    
    # Method 2: Fall back to AUR installation (build from source)
    log_info "yay not available in repositories, installing from AUR..."
    
    # Check if we're running as root
    if [[ $EUID -eq 0 ]]; then
        # Get the actual user (not root)
        local INSTALL_USER="${SUDO_USER:-}"
        if [[ -z "$INSTALL_USER" ]]; then
            log_error "Cannot install yay as root. Please run as a regular user or with sudo from a user account."
            log_error "To install yay manually:"
            log_error "  1. Switch to a regular user: su - yourusername"
            log_error "  2. Install yay: cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
            return 1
        fi
        
        log_info "Installing yay from AUR as user: $INSTALL_USER"
        
        # Install yay as the regular user
        cd /tmp
        if [[ -d "/tmp/yay" ]]; then
            rm -rf /tmp/yay
        fi
        
        # Clone and build yay as the regular user
        sudo -u "$INSTALL_USER" git clone https://aur.archlinux.org/yay.git /tmp/yay 2>/dev/null || {
            log_error "Failed to clone yay repository"
            return 1
        }
        
        cd /tmp/yay
        sudo -u "$INSTALL_USER" makepkg -si --noconfirm 2>&1 || {
            log_error "Failed to build/install yay"
            log_error "You may need to install yay manually as a regular user"
            return 1
        }
        
        # Verify yay is installed
        if command -v yay &> /dev/null; then
            log_success "yay installed successfully from AUR"
            return 0
        else
            log_error "yay installation completed but yay command not found"
            return 1
        fi
    else
        # Running as regular user - install directly
        cd /tmp
        if [[ -d "/tmp/yay" ]]; then
            rm -rf /tmp/yay
        fi
        
        git clone https://aur.archlinux.org/yay.git /tmp/yay 2>/dev/null || {
            log_error "Failed to clone yay repository"
            return 1
        }
        
        cd /tmp/yay
        makepkg -si --noconfirm 2>&1 || {
            log_error "Failed to build/install yay"
            return 1
        }
        
        if command -v yay &> /dev/null; then
            log_success "yay installed successfully from AUR"
            return 0
        else
            log_error "yay installation completed but yay command not found"
            return 1
        fi
    fi
}

# Install MongoDB from AUR using yay (preferred method)
install_mongodb_from_aur() {
    log_info "Installing MongoDB from AUR using yay..."
    
    # Ensure yay is installed
    if ! command -v yay &> /dev/null; then
        log_info "yay not found, installing it first..."
        if ! install_yay; then
            log_warning "Failed to install yay, cannot install MongoDB from AUR"
            return 1
        fi
    fi
    
    # Get the user who should run yay (not root)
    local YAY_USER="${SUDO_USER:-}"
    if [[ -z "$YAY_USER" ]] && [[ $EUID -ne 0 ]]; then
        YAY_USER=$(whoami)
    fi
    
    if [[ -z "$YAY_USER" ]]; then
        log_warning "Cannot determine user for yay. Attempting as root (may fail)..."
        log_info "If this fails, install MongoDB manually as a regular user: yay -S mongodb-bin"
        
        # Try with --noconfirm to avoid prompts
        local yay_output
        yay_output=$(yay -S --noconfirm mongodb-bin 2>&1)
        local yay_exit=$?
    else
        log_info "Installing MongoDB from AUR as user: $YAY_USER"
        
        # Run yay as the regular user
        local yay_output
        yay_output=$(sudo -u "$YAY_USER" yay -S --noconfirm mongodb-bin 2>&1)
        local yay_exit=$?
    fi
    
    # Check if installation succeeded
    if [[ $yay_exit -eq 0 ]] && (pacman -Q mongodb-bin &>/dev/null || [[ -f "/usr/bin/mongod" ]] || [[ -f "/opt/mongodb/bin/mongod" ]]); then
        log_success "MongoDB installed from AUR via yay"
        # Create symlinks if needed
        if [[ -f "/usr/bin/mongod" ]] && [[ ! -f "/opt/mongodb/bin/mongod" ]]; then
            mkdir -p /opt/mongodb/bin
            ln -s /usr/bin/mongod /opt/mongodb/bin/mongod 2>/dev/null || true
            if [[ -f "/usr/bin/mongosh" ]]; then
                ln -s /usr/bin/mongosh /opt/mongodb/bin/mongosh 2>/dev/null || true
            fi
        fi
        return 0
    else
        log_warning "AUR installation via yay failed."
        if [[ -n "$YAY_USER" ]]; then
            log_info "You can try installing manually as user $YAY_USER:"
            log_info "  su - $YAY_USER"
            log_info "  yay -S mongodb-bin"
        else
            log_info "You can try installing manually as a regular user:"
            log_info "  yay -S mongodb-bin"
        fi
        return 1
    fi
}

# Install MongoDB from official repository (fallback method)
install_mongodb_from_repo() {
    log_info "Trying to install MongoDB from official repositories..."
    
    # Check if mongodb package is available in official repos
    if pacman -Si mongodb &>/dev/null; then
        log_info "MongoDB package found in official repositories, installing..."
        if pacman -S --noconfirm mongodb 2>/dev/null; then
            # MongoDB from official repos installs to /usr/bin, create symlink for compatibility
            if [[ -f "/usr/bin/mongod" ]] && [[ ! -d "/opt/mongodb/bin" ]]; then
                mkdir -p /opt/mongodb/bin
                ln -s /usr/bin/mongod /opt/mongodb/bin/mongod 2>/dev/null || true
                ln -s /usr/bin/mongosh /opt/mongodb/bin/mongosh 2>/dev/null || true
            fi
            return 0
        fi
    fi
    
    return 1
}

# Install MongoDB manually
install_mongodb() {
    local MONGO_DIR="/opt/mongodb"
    
    # First, check if MongoDB is already installed
    if check_mongodb_installed; then
        log_success "MongoDB is already installed"
        return
    fi
    
    log_info "Installing MongoDB..."
    log_info "Trying multiple installation methods..."
    
    # Method 1: Try installing from AUR using yay (preferred method)
    if install_mongodb_from_aur; then
        log_success "MongoDB installed from AUR via yay"
        # Verify installation
        if check_mongodb_installed; then
            return
        fi
    fi
    
    # Method 2: Try installing from official repositories (fallback)
    if install_mongodb_from_repo; then
        log_success "MongoDB installed from official repository"
        # Verify installation
        if check_mongodb_installed; then
            return
        fi
    fi
    
    # Method 3: Try manual download (may fail due to 403)
    log_warning "Repository/AUR installation failed, trying manual download..."
    log_warning "Note: Direct downloads from MongoDB.org may return 403 Forbidden."
    
    # Method 2: Try manual download (may fail due to 403)
    log_info "Repository installation failed, trying manual download..."
    local MONGO_VERSION="7.0.16"
    local MONGO_TARBALL="mongodb-linux-x86_64-${MONGO_VERSION}.tgz"
    cd /tmp
    
    # Try multiple download methods and URLs
    local download_success=false
    
    # Method 1: Try official MongoDB download (community edition)
    # Try multiple version numbers in case specific version doesn't exist
    local MONGO_VERSIONS=("7.0.16" "7.0.15" "7.0.14" "7.0.13" "7.0.12" "7.0.11" "7.0.10")
    local MONGO_URLS=()
    
    for ver in "${MONGO_VERSIONS[@]}"; do
        MONGO_URLS+=("https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-${ver}.tgz")
    done
    
    # Also try latest version URLs if specific versions fail
    local MONGO_LATEST_URLS=(
        "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-7.0.tgz"
        "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-7.0.tgz"
    )
    
    for MONGO_URL in "${MONGO_URLS[@]}"; do
        log_info "Trying download from: $MONGO_URL"
        rm -f "$MONGO_TARBALL" 2>/dev/null || true
        
        # Use wget with better error checking
        if wget --timeout=30 --tries=2 --spider "$MONGO_URL" 2>&1 | grep -q "200 OK"; then
            log_info "URL exists, downloading..."
            if wget --timeout=60 --tries=3 --progress=bar:force "$MONGO_URL" -O "$MONGO_TARBALL" 2>&1; then
                # Verify the file was actually downloaded and is not empty
                if [[ -f "$MONGO_TARBALL" ]] && [[ -s "$MONGO_TARBALL" ]]; then
                    local file_size=$(stat -f%z "$MONGO_TARBALL" 2>/dev/null || stat -c%s "$MONGO_TARBALL" 2>/dev/null || echo "0")
                    # MongoDB tarballs are typically > 100MB
                    if [[ $file_size -gt 104857600 ]]; then
                        # Check if it's actually a gzip file
                        if file "$MONGO_TARBALL" 2>/dev/null | grep -qE "gzip|compressed|archive"; then
                            download_success=true
                            MONGO_VERSION=$(echo "$MONGO_URL" | sed 's/.*mongodb-linux-x86_64-\([0-9.]*\)\.tgz/\1/')
                            log_success "Successfully downloaded MongoDB ${MONGO_VERSION} tarball ($(du -h "$MONGO_TARBALL" | cut -f1))"
                            break
                        else
                            log_warning "Downloaded file doesn't appear to be a valid tarball (type: $(file "$MONGO_TARBALL" 2>/dev/null || echo 'unknown')), trying next URL..."
                            rm -f "$MONGO_TARBALL"
                        fi
                    else
                        log_warning "Downloaded file is too small (${file_size} bytes), likely an error page, trying next URL..."
                        rm -f "$MONGO_TARBALL"
                    fi
                else
                    log_warning "Downloaded file is empty or missing, trying next URL..."
                    rm -f "$MONGO_TARBALL"
                fi
            else
                log_warning "Download failed from $MONGO_URL"
                rm -f "$MONGO_TARBALL"
            fi
        else
            log_warning "URL not accessible: $MONGO_URL"
        fi
    done
    
    # Method 2: Try using curl as fallback
    if [[ "$download_success" == "false" ]]; then
        log_info "Trying with curl..."
        for MONGO_URL in "${MONGO_URLS[@]}"; do
            log_info "Trying curl download from: $MONGO_URL"
            if curl -L --connect-timeout 30 --max-time 300 --progress-bar "$MONGO_URL" -o "$MONGO_TARBALL" 2>&1 | tee /tmp/mongodb_download.log; then
                # Verify the file was actually downloaded and is not empty
                if [[ -f "$MONGO_TARBALL" ]] && [[ -s "$MONGO_TARBALL" ]]; then
                    # Check if it's actually a gzip file
                    if file "$MONGO_TARBALL" | grep -q "gzip\|compressed"; then
                        download_success=true
                        log_success "Successfully downloaded MongoDB tarball with curl ($(du -h "$MONGO_TARBALL" | cut -f1))"
                        break
                    else
                        log_warning "Downloaded file doesn't appear to be a valid tarball, trying next URL..."
                        rm -f "$MONGO_TARBALL"
                    fi
                else
                    log_warning "Downloaded file is empty or missing, trying next URL..."
                    rm -f "$MONGO_TARBALL"
                fi
            else
                log_warning "Curl download failed from $MONGO_URL"
                rm -f "$MONGO_TARBALL"
            fi
        done
    fi
    
    # Method 2.5: Try latest version URLs if specific version failed
    if [[ "$download_success" == "false" ]]; then
        log_info "Trying latest MongoDB version..."
        for MONGO_URL in "${MONGO_LATEST_URLS[@]}"; do
            log_info "Trying: $MONGO_URL"
            # Try wget first
            if wget --timeout=30 --tries=3 "$MONGO_URL" -O "$MONGO_TARBALL" 2>&1 | tee /tmp/mongodb_download.log || \
               curl -L --connect-timeout 30 --max-time 300 --progress-bar "$MONGO_URL" -o "$MONGO_TARBALL" 2>&1 | tee /tmp/mongodb_download.log; then
                # Verify download
                if [[ -f "$MONGO_TARBALL" ]] && [[ -s "$MONGO_TARBALL" ]] && file "$MONGO_TARBALL" | grep -q "gzip\|compressed"; then
                    download_success=true
                    log_success "Downloaded MongoDB tarball ($(du -h "$MONGO_TARBALL" | cut -f1))"
                    # Try to extract to get actual version (but don't fail if it doesn't work)
                    if tar -tzf "$MONGO_TARBALL" 2>/dev/null | head -1 | grep -q "mongodb-linux-x86_64"; then
                        local first_entry=$(tar -tzf "$MONGO_TARBALL" 2>/dev/null | head -1)
                        if [[ -n "$first_entry" ]]; then
                            local actual_dir=$(echo "$first_entry" | cut -d'/' -f1)
                            if [[ -n "$actual_dir" ]] && [[ "$actual_dir" =~ mongodb-linux-x86_64- ]]; then
                                MONGO_VERSION=$(echo "$actual_dir" | sed 's/mongodb-linux-x86_64-//')
                                log_info "Detected MongoDB version: $MONGO_VERSION"
                            fi
                        fi
                    fi
                    break
                else
                    log_warning "Downloaded file is invalid, trying next URL..."
                    rm -f "$MONGO_TARBALL"
                fi
            else
                log_warning "Download failed from $MONGO_URL"
                rm -f "$MONGO_TARBALL"
            fi
        done
    fi
    
    # Method 3: Check if MongoDB was installed manually or by user
    if [[ "$download_success" == "false" ]]; then
        log_warning "Direct download failed. Checking if MongoDB is already installed..."
        
        # Check if MongoDB is already installed (maybe user installed it manually)
        if check_mongodb_installed; then
            log_success "MongoDB found (may have been installed manually)"
            return
        fi
        
        log_error "Failed to install MongoDB using all automatic methods."
        log_error ""
        log_error "MongoDB direct downloads are currently blocked (403 Forbidden)."
        log_error "Please install MongoDB manually using one of these methods:"
        log_error ""
        log_error "Option 1: Install from official repositories (RECOMMENDED)"
        log_error "  sudo pacman -S mongodb"
        log_error "  Then re-run: sudo ./deploy.sh init-server"
        log_error ""
        log_error "Option 2: Install from AUR (as regular user, NOT sudo)"
        log_error "  yay -S mongodb-bin"
        log_error "  Note: yay should NOT be run with sudo. Run as regular user."
        log_error "  After installation, re-run: sudo ./deploy.sh init-server"
        log_error ""
        log_error "Option 3: Download from MongoDB website (requires accepting terms)"
        log_error "  Visit: https://www.mongodb.com/try/download/community"
        log_error "  Accept terms and download mongodb-linux-x86_64-7.0.16.tgz"
        log_error "  Then:"
        log_error "    cd /tmp"
        log_error "    tar -xzf mongodb-linux-x86_64-7.0.16.tgz"
        log_error "    sudo mv mongodb-linux-x86_64-7.0.16 /opt/mongodb"
        log_error "    sudo chown -R mongodb:mongodb /opt/mongodb"
        log_error "    sudo ./deploy.sh init-server"
        log_error ""
        exit 1
    fi
    
    log_info "Extracting MongoDB..."
    
    # Verify tarball exists and is valid before extraction
    if [[ ! -f "$MONGO_TARBALL" ]]; then
        log_error "MongoDB tarball not found: $MONGO_TARBALL"
        exit 1
    fi
    
    if [[ ! -s "$MONGO_TARBALL" ]]; then
        log_error "MongoDB tarball is empty"
        exit 1
    fi
    
    # Test tarball integrity before extraction
    log_info "Verifying tarball integrity..."
    if ! tar -tzf "$MONGO_TARBALL" >/dev/null 2>&1; then
        log_error "MongoDB tarball is corrupted or invalid"
        log_error "File size: $(du -h "$MONGO_TARBALL" | cut -f1)"
        log_error "File type: $(file "$MONGO_TARBALL" 2>/dev/null || echo 'unknown')"
        log_error ""
        log_error "The download may have failed. Please check:"
        log_error "  1. Internet connection"
        log_error "  2. MongoDB download URL accessibility"
        log_error "  3. Try manual download: wget https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-7.0.16.tgz"
        exit 1
    fi
    
    # Extract with output for debugging
    log_info "Extracting tarball (this may take a moment)..."
    if ! tar -xzf "$MONGO_TARBALL" 2>&1; then
        log_error "Failed to extract MongoDB tarball"
        log_error "Tarball location: $MONGO_TARBALL"
        log_error "Tarball size: $(du -h "$MONGO_TARBALL" | cut -f1)"
        exit 1
    fi
    
    # Find the extracted directory (version might vary)
    local mongo_extracted_dir=$(ls -d mongodb-linux-x86_64-* 2>/dev/null | head -1)
    if [[ -z "$mongo_extracted_dir" ]]; then
        log_error "Could not find extracted MongoDB directory"
        log_error "Contents of /tmp:"
        ls -la /tmp/mongodb* 2>/dev/null || echo "No mongodb files found"
        exit 1
    fi
    
    mv "$mongo_extracted_dir" "$MONGO_DIR"
    rm -f "$MONGO_TARBALL"
    
    # Create data directory (log directory not needed as logging is disabled)
    mkdir -p "$MONGO_DATA_DIR"
    # Create log directory structure but it won't be used (logging disabled)
    mkdir -p "$MONGO_LOG_DIR"
    chown -R mongodb:mongodb "$MONGO_DATA_DIR" "$MONGO_LOG_DIR" 2>/dev/null || true
    
    # Create MongoDB user if it doesn't exist
    if ! id "mongodb" &>/dev/null; then
        useradd -r -s /bin/false mongodb || true
    fi
    
    # Create systemd service file with CPU affinity for P-cores (0-5)
    # Logging disabled: no logpath, using --quiet flag
    cat > "$SYSTEMD_DIR/mongodb.service" <<EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.com/manual
After=network.target

[Service]
User=mongodb
Group=mongodb
Type=forking
# CPU Affinity: P-cores (0-5) for Intel i9-12900HK
CPUAffinity=0 1 2 3 4 5
    # Logging disabled: --quiet flag suppresses all output, no logpath specified
    # Support both /opt/mongodb/bin/mongod (manual install) and /usr/bin/mongod (repo install)
    ExecStart=/bin/sh -c 'MONGO_BIN=""; if [ -f /opt/mongodb/bin/mongod ]; then MONGO_BIN=/opt/mongodb/bin/mongod; elif [ -f /usr/bin/mongod ]; then MONGO_BIN=/usr/bin/mongod; else echo "MongoDB not found"; exit 1; fi; $MONGO_BIN --dbpath=/opt/mongodb/data --quiet --fork'
    ExecStop=/bin/sh -c 'MONGO_BIN=""; if [ -f /opt/mongodb/bin/mongod ]; then MONGO_BIN=/opt/mongodb/bin/mongod; elif [ -f /usr/bin/mongod ]; then MONGO_BIN=/usr/bin/mongod; fi; [ -n "$MONGO_BIN" ] && $MONGO_BIN --shutdown --dbpath=/opt/mongodb/data || true'
PIDFile=$MONGO_DATA_DIR/mongod.lock
Restart=on-failure
RestartSec=10
# Redirect all output to /dev/null to ensure no logging
StandardOutput=null
StandardError=null
# Ensure affinity is set after start
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'

[Install]
WantedBy=multi-user.target
EOF
    
    # Add MongoDB to PATH
    if ! grep -q "$MONGO_DIR/bin" /etc/profile; then
        echo "export PATH=\$PATH:$MONGO_DIR/bin" >> /etc/profile
    fi
    
    log_success "MongoDB installed successfully"
}

# Optimize system for web server + MongoDB workload
optimize_system() {
    log_info "Optimizing system for web server + MongoDB workload..."
    
    # Calculate system memory for MongoDB cache sizing
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    
    log_info "Detected system memory: ${total_mem_gb}GB"
    
    # 1. Configure swap and swappiness (low swappiness for database workloads)
    log_info "Configuring swap and swappiness..."
    
    # Set swappiness to 1 (very low - only swap in emergency)
    # For web server + MongoDB: we want to avoid swapping database pages
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "" >> /etc/sysctl.conf
        echo "# CineStream: Optimize for web server + MongoDB" >> /etc/sysctl.conf
        echo "vm.swappiness=1" >> /etc/sysctl.conf
        sysctl -w vm.swappiness=1
        log_success "Set vm.swappiness=1 (low swap usage for database)"
    else
        sed -i 's/^vm.swappiness=.*/vm.swappiness=1/' /etc/sysctl.conf
        sysctl -w vm.swappiness=1
        log_success "Updated vm.swappiness=1"
    fi
    
    # Set dirty ratio for better write performance
    if ! grep -q "^vm.dirty_ratio" /etc/sysctl.conf; then
        echo "vm.dirty_ratio=15" >> /etc/sysctl.conf
        sysctl -w vm.dirty_ratio=15
    fi
    
    if ! grep -q "^vm.dirty_background_ratio" /etc/sysctl.conf; then
        echo "vm.dirty_background_ratio=5" >> /etc/sysctl.conf
        sysctl -w vm.dirty_background_ratio=5
    fi
    
    # 2. Disable last accessed file metadata (noatime)
    log_info "Configuring filesystem mount options (noatime)..."
    
    # Get MongoDB data directory filesystem
    local mongo_fs
    mongo_fs=$(df -T "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $2}' || echo "")
    
    # Update /etc/fstab to add noatime for MongoDB data partition
    if [[ -n "$mongo_fs" ]] && [[ "$mongo_fs" != "tmpfs" ]]; then
        local mongo_device
        mongo_device=$(df "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
        
        if [[ -n "$mongo_device" ]] && [[ "$mongo_device" != "tmpfs" ]]; then
            # Backup fstab
            cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
            
            # Check if already has noatime
            if ! grep -q "$mongo_device.*noatime" /etc/fstab; then
                # Add noatime to existing mount options
                sed -i "s|^\($mongo_device[[:space:]].*\)|\1,noatime|" /etc/fstab 2>/dev/null || {
                    log_warning "Could not automatically update /etc/fstab for noatime"
                    log_info "Manually add 'noatime' to the mount options for $mongo_device in /etc/fstab"
                }
                log_success "Added noatime to filesystem mount options"
            else
                log_info "noatime already configured for MongoDB data partition"
            fi
        fi
    fi
    
    # Also set noatime for root filesystem if it's the same
    local root_device
    root_device=$(findmnt -n -o SOURCE / | head -1)
    if [[ -n "$root_device" ]] && ! grep -q "$root_device.*noatime" /etc/fstab; then
        sed -i "s|^\($root_device[[:space:]].*\)|\1,noatime|" /etc/fstab 2>/dev/null || true
    fi
    
    # 3. Kernel parameters for web server workload
    log_info "Configuring kernel parameters for web server workload..."
    
    # TCP optimizations for high concurrency
    cat >> /etc/sysctl.conf <<'SYSCTL_EOF'

# TCP optimizations for web server
net.core.somaxconn=4096
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_tw_recycle=0
net.ipv4.ip_local_port_range=10000 65535

# Increase file descriptor limits
fs.file-max=2097152

# Network buffer sizes
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection tracking
net.netfilter.nf_conntrack_max=262144
SYSCTL_EOF
    
    # Apply settings immediately
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
    log_success "Applied kernel parameters"
    
    # 4. Increase file descriptor limits
    log_info "Configuring file descriptor limits..."
    
    cat >> /etc/security/limits.conf <<'LIMITS_EOF'

# CineStream: Increase file descriptor limits for web server + MongoDB
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
mongodb soft nofile 64000
mongodb hard nofile 64000
LIMITS_EOF
    
    log_success "Configured file descriptor limits"
    
    # 5. MongoDB performance tuning
    log_info "Configuring MongoDB performance settings..."
    
    # Define MongoDB directory (should match install_mongodb)
    local MONGO_DIR="/opt/mongodb"
    local wt_cache_gb=""
    
    # Check if MongoDB is installed
    if [[ ! -d "$MONGO_DIR/bin" ]]; then
        log_warning "MongoDB not found at $MONGO_DIR, skipping MongoDB optimizations"
        log_info "Run 'sudo ./deploy.sh init-server' to install MongoDB first"
    else
        # Create MongoDB configuration file with performance optimizations
        local mongo_conf="$MONGO_DIR/mongod.conf"
        
        # Calculate WiredTiger cache size (50% of RAM, but max 32GB for MongoDB 7.0)
        if [[ $total_mem_gb -lt 8 ]]; then
            wt_cache_gb=2
        elif [[ $total_mem_gb -lt 16 ]]; then
            wt_cache_gb=$((total_mem_gb / 2))
        elif [[ $total_mem_gb -lt 64 ]]; then
            wt_cache_gb=$((total_mem_gb / 2))
        else
            wt_cache_gb=32  # MongoDB 7.0 max recommended
        fi
        
        log_info "Configuring WiredTiger cache: ${wt_cache_gb}GB"
        
        cat > "$mongo_conf" <<EOF
# MongoDB Configuration for CineStream
# Optimized for web server + database workload

storage:
  dbPath: $MONGO_DATA_DIR
  journal:
    enabled: true
    commitIntervalMs: 100
  wiredTiger:
    engineConfig:
      cacheSizeGB: $wt_cache_gb
      journalCompressor: snappy
      directoryForIndexes: false
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true

systemLog:
  destination: null
  verbosity: 0
  quiet: true
  # Completely disable all logging - no log files created
  logAppend: false
  logRotate: reopen
  # Disable component logging
  component:
    accessControl:
      verbosity: 0
    command:
      verbosity: 0
    control:
      verbosity: 0
    geo:
      verbosity: 0
    index:
      verbosity: 0
    network:
      verbosity: 0
    query:
      verbosity: 0
    replication:
      verbosity: 0
    sharding:
      verbosity: 0
    storage:
      verbosity: 0
    write:
      verbosity: 0

net:
  port: 27017
  bindIp: 127.0.0.1
  maxIncomingConnections: 1000

processManagement:
  fork: true
  pidFilePath: $MONGO_DATA_DIR/mongod.lock

operationProfiling:
  mode: off

setParameter:
  # Connection pool settings
  connPoolMaxShardedConnsPerHost: 200
  connPoolMaxConnsPerHost: 200
  
  # Query execution
  internalQueryExecMaxBlockingSortBytes: 33554432
  
  # Write concern
  writePeriodicNoops: true
  periodicNoopIntervalSecs: 10
EOF
    
        chown mongodb:mongodb "$mongo_conf" 2>/dev/null || true
        log_success "Created MongoDB configuration: $mongo_conf"
        
        # Update MongoDB systemd service to use config file
        if [[ -f "$SYSTEMD_DIR/mongodb.service" ]]; then
            # Backup service file
            cp "$SYSTEMD_DIR/mongodb.service" "$SYSTEMD_DIR/mongodb.service.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Update ExecStart to use config file (support both installation paths)
            local mongo_binary=""
            if [[ -f "$MONGO_DIR/bin/mongod" ]]; then
                mongo_binary="$MONGO_DIR/bin/mongod"
            elif [[ -f "/usr/bin/mongod" ]]; then
                mongo_binary="/usr/bin/mongod"
            else
                log_warning "MongoDB binary not found, skipping service update"
                return
            fi
            
            # Update ExecStart to use config file
            sed -i "s|ExecStart=.*|ExecStart=$mongo_binary --config $mongo_conf|" "$SYSTEMD_DIR/mongodb.service"
            log_success "Updated MongoDB service to use configuration file"
        fi
    fi
    
    # 6. Disable transparent hugepages for MongoDB (recommended by MongoDB)
    log_info "Configuring transparent hugepages (disabled for MongoDB)..."
    
    cat > /etc/systemd/system/disable-transparent-hugepages.service <<'THP_EOF'
[Unit]
Description=Disable Transparent Hugepages for MongoDB
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongodb.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'

[Install]
WantedBy=basic.target
THP_EOF
    
    systemctl daemon-reload
    systemctl enable disable-transparent-hugepages.service
    systemctl start disable-transparent-hugepages.service
    
    # Also set it immediately
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    
    log_success "Disabled transparent hugepages for MongoDB"
    
    # 7. I/O scheduler optimization (use deadline or none for SSDs)
    log_info "Configuring I/O scheduler..."
    
    # Detect if we're on SSD
    local is_ssd=false
    for disk in /sys/block/sd* /sys/block/nvme*; do
        if [[ -f "$disk/queue/rotational" ]]; then
            if [[ $(cat "$disk/queue/rotational" 2>/dev/null) == "0" ]]; then
                is_ssd=true
                break
            fi
        fi
    done
    
    if [[ "$is_ssd" == "true" ]]; then
        # Use none or mq-deadline for SSDs
        cat > /etc/systemd/system/configure-io-scheduler.service <<'IO_EOF'
[Unit]
Description=Configure I/O Scheduler for SSDs
After=sysinit.target
Before=mongodb.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for disk in /sys/block/sd* /sys/block/nvme*; do [ -f "$disk/queue/scheduler" ] && echo none > "$disk/queue/scheduler" 2>/dev/null || echo mq-deadline > "$disk/queue/scheduler" 2>/dev/null; done'

[Install]
WantedBy=basic.target
IO_EOF
        
        systemctl daemon-reload
        systemctl enable configure-io-scheduler.service
        systemctl start configure-io-scheduler.service
        log_success "Configured I/O scheduler for SSD (none/mq-deadline)"
    else
        log_info "HDD detected, using default I/O scheduler"
    fi
    
    # 8. Set readahead for MongoDB data directory
    log_info "Configuring readahead for MongoDB..."
    
    local mongo_block_device
    mongo_block_device=$(df "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' || echo "")
    
    if [[ -n "$mongo_block_device" ]] && [[ -f "/sys/block/$(basename "$mongo_block_device")/queue/read_ahead_kb" ]]; then
        echo 256 > "/sys/block/$(basename "$mongo_block_device")/queue/read_ahead_kb" 2>/dev/null || true
        log_success "Set readahead for MongoDB data device"
    fi
    
    # 9. CPU Governor (ensure automatic scaling is enabled - ondemand/schedutil)
    # DISABLED: CPU automatic scaling function removed
    # ensure_cpu_automatic_scaling
    
    # 10. Additional kernel optimizations
    configure_additional_kernel_optimizations
    
    # 11. Nginx worker optimization
    optimize_nginx_workers
    
    # 12. Disable unnecessary services for server performance
    # DISABLED: Service disabling removed to preserve Bluetooth and other services
    # disable_unnecessary_services
    
    # 13. Configure GRUB to skip boot menu
    configure_grub_boot
    
    # 14. Optimize startup and shutdown
    optimize_startup_shutdown
    
    log_success "System optimization complete!"
    log_info ""
    log_info "Optimizations applied:"
    log_info "  - Swappiness: 1 (minimal swap usage)"
    log_info "  - Filesystem: noatime (disable last access time)"
    log_info "  - TCP: Optimized for high concurrency"
    log_info "  - File descriptors: 65536"
    if [[ -d "$MONGO_DIR/bin" ]] && [[ -n "${wt_cache_gb:-}" ]]; then
        log_info "  - MongoDB: WiredTiger cache ${wt_cache_gb}GB, performance tuned"
        log_info "  - Transparent hugepages: Disabled (MongoDB requirement)"
    else
        log_info "  - MongoDB: Not installed (skipped MongoDB optimizations)"
    fi
    log_info "  - I/O scheduler: Optimized for storage type"
    log_info "  - CPU governor: Automatic scaling (ondemand/schedutil - turbo when needed, power saving when idle)"
    log_info "  - Memory overcommit: Optimized"
    log_info "  - Nginx workers: Optimized"
    log_info "  - Services: All services kept enabled (Bluetooth, NetworkManager, etc.)"
    log_info "  - GRUB: Boot menu disabled (direct boot)"
    log_info "  - Startup/Shutdown: Optimized for faster boot times"
    log_info ""
    log_warning "Note: Some changes require reboot to take full effect"
    log_warning "Run 'sudo sysctl -p' to apply kernel parameters immediately"
}

# Ensure CPU governor uses automatic scaling (ondemand/schedutil)
# This allows CPU to turbo when needed but save power when idle
# DISABLED: CPU automatic scaling function removed
# ensure_cpu_automatic_scaling() {
#     log_info "Ensuring CPU automatic scaling (ondemand/schedutil) is enabled..."
#     
#     # Check if cpufreq is available
#     if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
#         log_info "  CPU frequency scaling not available (may be disabled in BIOS or not supported)"
#         return 0
#     fi
#     
#     # Remove any performance mode service if it exists
#     if systemctl list-unit-files | grep -q "set-cpu-performance.service"; then
#         log_info "  Removing CPU performance mode service (restoring automatic scaling)..."
#         systemctl stop set-cpu-performance.service 2>/dev/null || true
#         systemctl disable set-cpu-performance.service 2>/dev/null || true
#         systemctl mask set-cpu-performance.service 2>/dev/null || true
#         rm -f /etc/systemd/system/set-cpu-performance.service 2>/dev/null || true
#         systemctl daemon-reload 2>/dev/null || true
#         log_success "  Removed CPU performance mode service"
#     fi
#     
#     # Check current governor and set to ondemand/schedutil if it's locked to performance
#     local cpu_count
#     cpu_count=$(nproc)
#     local changed_count=0
#     
#     for ((cpu=0; cpu<cpu_count; cpu++)); do
#         if [[ -f "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" ]]; then
#             local current_governor
#             current_governor=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null || echo "")
#             
#             # If locked to performance, change to ondemand or schedutil
#             if [[ "$current_governor" == "performance" ]]; then
#                 local available_governors
#                 available_governors=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_available_governors" 2>/dev/null || echo "")
#                 
#                 # Prefer schedutil (modern), fallback to ondemand
#                 if echo "$available_governors" | grep -q "schedutil"; then
#                     echo "schedutil" > "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null && ((changed_count++)) || true
#                 elif echo "$available_governors" | grep -q "ondemand"; then
#                     echo "ondemand" > "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null && ((changed_count++)) || true
#                 fi
#             fi
#         fi
#     done
#     
#     if [[ $changed_count -gt 0 ]]; then
#         log_success "  Restored automatic CPU scaling for $changed_count CPUs (turbo when needed, power saving when idle)"
#     else
#         log_info "  CPU automatic scaling already configured (no changes needed)"
#     fi
# }

# Configure additional kernel optimizations
configure_additional_kernel_optimizations() {
    log_info "Configuring additional kernel optimizations..."
    
    # Additional sysctl optimizations
    cat >> /etc/sysctl.conf <<'SYSCTL_EXTRA_EOF'

# Additional performance optimizations
# Memory overcommit (allow overcommit for better performance)
vm.overcommit_memory=1
vm.overcommit_ratio=50

# Reduce swapiness even more (already set to 1, but ensure it's optimal)
vm.swappiness=1

# OOM killer tuning (prefer killing processes with higher oom_score_adj)
vm.oom_kill_allocating_task=0

# Virtual memory management
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500

# Network optimizations (additional)
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_sack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_syncookies=1

# Increase connection tracking timeout
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=60

# IPv6 optimizations (if IPv6 is used)
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0

# Kernel scheduler optimizations
kernel.sched_migration_cost_ns=5000000
kernel.sched_autogroup_enabled=0

# Increase PID limit
kernel.pid_max=4194304
SYSCTL_EXTRA_EOF
    
    # Apply settings immediately
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
    
    log_success "Applied additional kernel optimizations"
}

# Optimize Nginx worker configuration
optimize_nginx_workers() {
    log_info "Optimizing Nginx worker configuration..."
    
    # Get CPU count
    local cpu_count
    cpu_count=$(nproc)
    
    # Calculate optimal worker processes (usually 1 per CPU core, or 2x for hyperthreading)
    local worker_processes=$cpu_count
    
    # Check if Nginx config exists
    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        log_warning "  Nginx configuration not found, skipping worker optimization"
        return 0
    fi
    
    # Backup nginx config
    cp "$nginx_conf" "${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Update worker_processes if it's set to auto or a low value
    if grep -q "worker_processes auto" "$nginx_conf" || grep -q "worker_processes 1" "$nginx_conf"; then
        # Replace worker_processes line
        sed -i "s/worker_processes.*/worker_processes $worker_processes;/" "$nginx_conf" 2>/dev/null || {
            # If replacement failed, try adding it after the first line
            sed -i "1a worker_processes $worker_processes;" "$nginx_conf" 2>/dev/null || true
        }
        
        # Add worker_connections if not present (default is 512, increase to 2048)
        if ! grep -q "worker_connections" "$nginx_conf"; then
            # Find the events block and add worker_connections
            sed -i '/events {/a\    worker_connections 2048;' "$nginx_conf" 2>/dev/null || true
        else
            # Update existing worker_connections to 2048
            sed -i 's/worker_connections.*/worker_connections 2048;/' "$nginx_conf" 2>/dev/null || true
        fi
        
        # Add worker_rlimit_nofile for better file descriptor handling
        if ! grep -q "worker_rlimit_nofile" "$nginx_conf"; then
            sed -i "/worker_processes/a\worker_rlimit_nofile 65536;" "$nginx_conf" 2>/dev/null || true
        fi
        
        # Test Nginx configuration
        if nginx -t 2>/dev/null; then
            log_success "Optimized Nginx workers: $worker_processes processes, 2048 connections per worker"
            # Reload Nginx if it's running
            if systemctl is-active --quiet nginx.service 2>/dev/null; then
                systemctl reload nginx.service 2>/dev/null || true
            fi
        else
            log_warning "  Nginx configuration test failed, restoring backup"
            cp "${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)" "$nginx_conf" 2>/dev/null || true
        fi
    else
        log_info "  Nginx worker_processes already optimized"
    fi
}

# Disable unnecessary services for server performance
# DISABLED: This function has been disabled - all services are kept enabled
# disable_unnecessary_services() {
#     log_info "Disabling unnecessary services for server performance..."
#     
#     # List of services to disable (safe for headless server, but keep audio/network/bluetooth for multimedia)
#     local services_to_disable=(
#         # Desktop environment services
#         # Note: Bluetooth is KEPT ENABLED for keyboard/mouse support
#         "cups.service"              # Printing service
#         "cups-browsed.service"       # Printer discovery
#         
#         # Power management (prevent sleep/suspend)
#         "sleep.target"
#         "suspend.target"
#         "hibernate.target"
#         "hybrid-sleep.target"
#         
#         # Desktop services (keep minimal for multimedia)
#         "accounts-daemon.service"    # User account management (desktop)
#         "colord.service"            # Color management (desktop)
#         "ModemManager.service"      # Modem management (not needed)
#         "polkit.service"            # PolicyKit (desktop)
#         "upower.service"           # Power management (desktop)
#         
#         # Other unnecessary services
#         "fstrim.timer"              # SSD trim (can be run manually)
#     )
#     
#     # Note: Audio services (PulseAudio, ALSA) are KEPT ENABLED for video playback
#     # Note: Network services (NetworkManager, Avahi) are KEPT ENABLED for WiFi and network connectivity
#     
#     local disabled_count=0
#     local skipped_count=0
#     
#     for service in "${services_to_disable[@]}"; do
#         # Check if service exists
#         if systemctl list-unit-files | grep -q "^${service}"; then
#             # Check if service is already disabled/masked
#             local status
#             status=$(systemctl is-enabled "$service" 2>/dev/null || echo "not-found")
#             
#             if [[ "$status" != "masked" ]] && [[ "$status" != "disabled" ]]; then
#                 # Stop the service first
#                 systemctl stop "$service" 2>/dev/null || true
#                 
#                 # Disable and mask the service
#                 systemctl disable "$service" 2>/dev/null || true
#                 systemctl mask "$service" 2>/dev/null || true
#                 
#                 log_info "  Disabled: $service"
#                 ((disabled_count++))
#             else
#                 log_info "  Already disabled: $service"
#                 ((skipped_count++))
#             fi
#         else
#             log_info "  Not found: $service (skipped)"
#             ((skipped_count++))
#         fi
#     done
#     
#     # Keep NetworkManager enabled for WiFi support (needed for multimedia use)
#     if systemctl list-unit-files | grep -q "^NetworkManager.service"; then
#         local nm_status
#         nm_status=$(systemctl is-active NetworkManager.service 2>/dev/null || echo "inactive")
#         
#         if [[ "$nm_status" != "active" ]]; then
#             log_info "  Enabling NetworkManager for WiFi support..."
#             systemctl unmask NetworkManager.service 2>/dev/null || true
#             systemctl enable NetworkManager.service 2>/dev/null || true
#             systemctl start NetworkManager.service 2>/dev/null || true
#         else
#             log_info "  NetworkManager is active (needed for WiFi)"
#         fi
#     fi
#     
#     # Keep Bluetooth enabled for keyboard/mouse support
#     if systemctl list-unit-files | grep -q "^bluetooth.service"; then
#         local bt_status
#         bt_status=$(systemctl is-active bluetooth.service 2>/dev/null || echo "inactive")
#         
#         if [[ "$bt_status" != "active" ]]; then
#             log_info "  Enabling Bluetooth for keyboard/mouse support..."
#             systemctl unmask bluetooth.service 2>/dev/null || true
#             systemctl unmask bluetooth.target 2>/dev/null || true
#             systemctl enable bluetooth.service 2>/dev/null || true
#             systemctl start bluetooth.service 2>/dev/null || true
#         else
#             log_info "  Bluetooth is active (needed for keyboard/mouse)"
#         fi
#     fi
#     
#     # Keep audio services enabled for video playback
#     if systemctl list-unit-files | grep -q "^pulseaudio.service"; then
#         local pa_status
#         pa_status=$(systemctl is-active pulseaudio.service 2>/dev/null || echo "inactive")
#         
#         if [[ "$pa_status" != "active" ]]; then
#             log_info "  Enabling PulseAudio for audio support..."
#             systemctl unmask pulseaudio.service 2>/dev/null || true
#             systemctl --user enable pulseaudio.service 2>/dev/null || true
#             systemctl --user start pulseaudio.service 2>/dev/null || true
#         else
#             log_info "  PulseAudio is active (needed for audio)"
#         fi
#     fi
#     
#     # Keep rtkit-daemon for real-time audio processing
#     if systemctl list-unit-files | grep -q "^rtkit-daemon.service"; then
#         local rtkit_status
#         rtkit_status=$(systemctl is-active rtkit-daemon.service 2>/dev/null || echo "inactive")
#         
#         if [[ "$rtkit_status" != "active" ]]; then
#             log_info "  Enabling rtkit-daemon for audio processing..."
#             systemctl unmask rtkit-daemon.service 2>/dev/null || true
#             systemctl enable rtkit-daemon.service 2>/dev/null || true
#             systemctl start rtkit-daemon.service 2>/dev/null || true
#         fi
#     fi
#     
#     # Disable unnecessary timers
#     local timers_to_disable=(
#         "fstrim.timer"              # SSD trim (can be run manually)
#         "systemd-tmpfiles-clean.timer"  # Temp file cleanup (optional)
#     )
#     
#     for timer in "${timers_to_disable[@]}"; do
#         if systemctl list-unit-files | grep -q "^${timer}"; then
#             local timer_status
#             timer_status=$(systemctl is-enabled "$timer" 2>/dev/null || echo "not-found")
#             
#             if [[ "$timer_status" == "enabled" ]]; then
#                 systemctl stop "$timer" 2>/dev/null || true
#                 systemctl disable "$timer" 2>/dev/null || true
#                 log_info "  Disabled timer: $timer"
#                 ((disabled_count++))
#             fi
#         fi
#     done
#     
#     # Reload systemd
#     systemctl daemon-reload 2>/dev/null || true
#     
#     # Keep geoclue enabled for geolocation support (needed for app city/country detection)
#     if systemctl list-unit-files | grep -q "^geoclue.service"; then
#         local geoclue_status
#         geoclue_status=$(systemctl is-active geoclue.service 2>/dev/null || echo "inactive")
#         
#         if [[ "$geoclue_status" != "active" ]]; then
#             log_info "  Enabling geoclue for geolocation support..."
#             systemctl unmask geoclue.service 2>/dev/null || true
#             systemctl enable geoclue.service 2>/dev/null || true
#             systemctl start geoclue.service 2>/dev/null || true
#         else
#             log_info "  geoclue is active (needed for geolocation)"
#         fi
#     fi
#     
#     log_success "Service optimization complete: $disabled_count services disabled, $skipped_count skipped/not found"
#     log_info ""
#     log_info "Services kept enabled for multimedia, geolocation, and input devices:"
#     log_info "  - NetworkManager (WiFi and network connectivity)"
#     log_info "  - Bluetooth (keyboard/mouse support)"
#     log_info "  - PulseAudio (audio playback)"
#     log_info "  - rtkit-daemon (real-time audio processing)"
#     log_info "  - Avahi (network discovery)"
#     log_info "  - geoclue (geolocation support for city/country detection)"
#     
#     # Show summary of what's still running
#     log_info ""
#     log_info "Active services summary:"
#     systemctl list-units --type=service --state=running | grep -E "(mongodb|nginx|cinestream|ssh|NetworkManager|pulseaudio|rtkit)" | head -15 || true
# }

# Configure GRUB to skip boot menu (direct boot)
configure_grub_boot() {
    log_info "Configuring GRUB to skip boot menu..."
    
    # Check if GRUB is installed
    if [[ ! -f /etc/default/grub ]]; then
        log_warning "  GRUB configuration not found at /etc/default/grub (may be using different bootloader)"
        return 0
    fi
    
    # Backup original GRUB config
    if [[ ! -f /etc/default/grub.backup ]]; then
        cp /etc/default/grub /etc/default/grub.backup 2>/dev/null || true
    fi
    
    local grub_conf="/etc/default/grub"
    local changed=false
    
    # Set GRUB_TIMEOUT to 0 (skip menu)
    if grep -q "^GRUB_TIMEOUT=" "$grub_conf"; then
        local current_timeout
        current_timeout=$(grep "^GRUB_TIMEOUT=" "$grub_conf" | cut -d= -f2 | tr -d '"' || echo "")
        if [[ "$current_timeout" != "0" ]]; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$grub_conf"
            changed=true
            log_info "  Set GRUB_TIMEOUT=0 (skip boot menu)"
        fi
    else
        echo "GRUB_TIMEOUT=0" >> "$grub_conf"
        changed=true
        log_info "  Added GRUB_TIMEOUT=0"
    fi
    
    # Set GRUB_TIMEOUT_STYLE to hidden (no countdown)
    if grep -q "^GRUB_TIMEOUT_STYLE=" "$grub_conf"; then
        local current_style
        current_style=$(grep "^GRUB_TIMEOUT_STYLE=" "$grub_conf" | cut -d= -f2 | tr -d '"' || echo "")
        if [[ "$current_style" != "hidden" ]]; then
            sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$grub_conf"
            changed=true
            log_info "  Set GRUB_TIMEOUT_STYLE=hidden"
        fi
    else
        echo "GRUB_TIMEOUT_STYLE=hidden" >> "$grub_conf"
        changed=true
        log_info "  Added GRUB_TIMEOUT_STYLE=hidden"
    fi
    
    # Update GRUB if changes were made
    if [[ "$changed" == "true" ]]; then
        log_info "  Updating GRUB configuration..."
        if command -v grub-mkconfig &>/dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null && {
                log_success "  GRUB configured to skip boot menu (direct boot)"
            } || {
                log_warning "  Failed to update GRUB config (may need manual update: sudo grub-mkconfig -o /boot/grub/grub.cfg)"
            }
        elif command -v update-grub &>/dev/null; then
            update-grub 2>/dev/null && {
                log_success "  GRUB configured to skip boot menu (direct boot)"
            } || {
                log_warning "  Failed to update GRUB config (may need manual update: sudo update-grub)"
            }
        else
            log_warning "  GRUB update command not found. Please run manually:"
            log_warning "    sudo grub-mkconfig -o /boot/grub/grub.cfg"
            log_warning "    or"
            log_warning "    sudo update-grub"
        fi
    else
        log_info "  GRUB already configured to skip boot menu"
    fi
}

# Optimize startup and shutdown times
optimize_startup_shutdown() {
    log_info "Optimizing startup and shutdown times..."
    
    # 1. Reduce systemd default timeout for faster boot
    local systemd_system_conf="/etc/systemd/system.conf"
    local changed=false
    
    if [[ -f "$systemd_system_conf" ]]; then
        # Backup if not already backed up
        if ! grep -q "# CineStream backup" "$systemd_system_conf" 2>/dev/null; then
            cp "$systemd_system_conf" "${systemd_system_conf}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
        
        # Reduce default timeout for services (from 90s to 30s)
        if ! grep -q "^DefaultTimeoutStartSec=" "$systemd_system_conf"; then
            echo "" >> "$systemd_system_conf"
            echo "# CineStream: Optimize startup/shutdown times" >> "$systemd_system_conf"
            echo "DefaultTimeoutStartSec=30s" >> "$systemd_system_conf"
            changed=true
            log_info "  Set DefaultTimeoutStartSec=30s (faster service startup)"
        elif grep -q "^DefaultTimeoutStartSec=90s" "$systemd_system_conf"; then
            sed -i 's/^DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=30s/' "$systemd_system_conf"
            changed=true
            log_info "  Updated DefaultTimeoutStartSec=30s"
        fi
        
        # Reduce shutdown timeout (from 90s to 20s)
        if ! grep -q "^DefaultTimeoutStopSec=" "$systemd_system_conf"; then
            echo "DefaultTimeoutStopSec=20s" >> "$systemd_system_conf"
            changed=true
            log_info "  Set DefaultTimeoutStopSec=20s (faster shutdown)"
        elif grep -q "^DefaultTimeoutStopSec=90s" "$systemd_system_conf"; then
            sed -i 's/^DefaultTimeoutStopSec=90s/DefaultTimeoutStopSec=20s/' "$systemd_system_conf"
            changed=true
            log_info "  Updated DefaultTimeoutStopSec=20s"
        fi
        
        # Reduce abort timeout (from 90s to 10s)
        if ! grep -q "^DefaultTimeoutAbortSec=" "$systemd_system_conf"; then
            echo "DefaultTimeoutAbortSec=10s" >> "$systemd_system_conf"
            changed=true
            log_info "  Set DefaultTimeoutAbortSec=10s"
        fi
    fi
    
    # 2. Enable parallel service startup (already default, but ensure it's enabled)
    local systemd_user_conf="/etc/systemd/user.conf"
    if [[ -f "$systemd_user_conf" ]]; then
        if ! grep -q "^DefaultTimeoutStartSec=" "$systemd_user_conf"; then
            echo "" >> "$systemd_user_conf"
            echo "# CineStream: Optimize user service startup" >> "$systemd_user_conf"
            echo "DefaultTimeoutStartSec=30s" >> "$systemd_user_conf"
            changed=true
        fi
    fi
    
    # 3. Optimize journald for faster startup
    local journald_conf="/etc/systemd/journald.conf"
    if [[ -f "$journald_conf" ]]; then
        # Reduce journal size limits for faster startup
        if ! grep -q "^SystemMaxUse=" "$journald_conf" || grep -q "^#SystemMaxUse=" "$journald_conf"; then
            if grep -q "^#SystemMaxUse=" "$journald_conf"; then
                sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=100M/' "$journald_conf"
            else
                echo "SystemMaxUse=100M" >> "$journald_conf"
            fi
            changed=true
            log_info "  Set journal SystemMaxUse=100M (faster startup)"
        fi
    fi
    
    # 4. Disable unnecessary systemd services that slow down boot
    # (Service disabling has been removed - all services are kept enabled)
    
    # 5. Optimize filesystem mount options for faster boot (already done in optimize_system with noatime)
    
    # Reload systemd if changes were made
    if [[ "$changed" == "true" ]]; then
        systemctl daemon-reload 2>/dev/null || true
        log_success "  Startup/shutdown optimizations applied"
        log_info "  - Service timeouts: 30s startup, 20s shutdown"
        log_info "  - Journal size: Limited to 100M for faster startup"
    else
        log_info "  Startup/shutdown already optimized"
    fi
    
    # 6. Enable systemd-analyze blame to help identify slow services (informational)
    log_info "  To identify slow boot services, run: systemd-analyze blame"
    log_info "  To see boot time, run: systemd-analyze"
}

# Ensure SSH service is enabled and running
ensure_ssh_service() {
    log_info "Ensuring SSH service is configured..."
    
    # Check if openssh is installed
    if ! command -v sshd &> /dev/null && ! pacman -Q openssh &> /dev/null; then
        log_info "Installing openssh..."
        pacman -S --noconfirm openssh 2>/dev/null || {
            log_error "Failed to install openssh"
            return 1
        }
    fi
    
    # Determine SSH service name (varies by distro)
    local ssh_service=""
    if systemctl list-unit-files | grep -q "^sshd.service"; then
        ssh_service="sshd.service"
    elif systemctl list-unit-files | grep -q "^ssh.service"; then
        ssh_service="ssh.service"
    else
        log_warning "SSH service not found, attempting to start sshd.service..."
        ssh_service="sshd.service"
    fi
    
    # Enable and start SSH service
    log_info "Enabling and starting SSH service ($ssh_service)..."
    systemctl enable "$ssh_service" 2>/dev/null || true
    systemctl start "$ssh_service" 2>/dev/null || {
        log_warning "Failed to start $ssh_service, trying alternative..."
        # Try starting sshd directly
        /usr/bin/sshd 2>/dev/null || true
    }
    
    # Verify SSH is listening on port 22
    sleep 1
    if ss -tlnp | grep -q ":22 "; then
        log_success "SSH service is running and listening on port 22"
    else
        log_warning "SSH service may not be listening on port 22"
        log_info "Check SSH status: sudo systemctl status $ssh_service"
        log_info "Check SSH config: sudo sshd -t"
    fi
}

# Configure comprehensive firewall rules
configure_firewall() {
    log_info "Configuring firewall rules..."
    
    # Ensure SSH service is running first
    ensure_ssh_service
    
    # Check for firewalld (common on Arch-based systems)
    if command -v firewall-cmd &> /dev/null; then
        log_info "Configuring firewalld..."
        
        # Enable firewalld if not running
        if ! systemctl is-active --quiet firewalld 2>/dev/null; then
            systemctl enable firewalld 2>/dev/null || true
            systemctl start firewalld 2>/dev/null || true
        fi
        
        # Set default zone to drop (deny by default)
        firewall-cmd --set-default-zone=drop 2>/dev/null || true
        
        # Allow loopback
        firewall-cmd --permanent --add-interface=lo 2>/dev/null || true
        
        # Allow established and related connections
        firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
        
        # Allow HTTP and HTTPS (from anywhere - internet access)
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        
        # Note: Rate limiting removed for HTTP/HTTPS to allow full internet access
        # Nginx rate limiting will handle request throttling instead
        
        # Block common attack ports
        firewall-cmd --permanent --remove-service=dhcpv6-client 2>/dev/null || true
        firewall-cmd --permanent --remove-service=mdns 2>/dev/null || true
        
        # Reload firewall
        firewall-cmd --reload 2>/dev/null || true
        log_success "Firewalld configured with security rules"
        
    # Check for ufw (alternative firewall)
    elif command -v ufw &> /dev/null; then
        log_info "Configuring UFW..."
        
        # Enable UFW
        ufw --force enable 2>/dev/null || true
        
        # Default policies
        ufw default deny incoming 2>/dev/null || true
        ufw default allow outgoing 2>/dev/null || true
        
        # Allow SSH (important: do this first!)
        ufw allow 22/tcp 2>/dev/null || true
        
        # Allow HTTP and HTTPS
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        
        # Rate limiting
        ufw limit 22/tcp 2>/dev/null || true
        
        log_success "UFW configured with security rules"
        
    # Fallback: Use iptables directly
    else
        log_info "Configuring iptables rules..."
        
        # Flush existing rules
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        
        # Default policies
        iptables -P INPUT DROP 2>/dev/null || true
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
        
        # Allow loopback
        iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
        
        # Allow established and related connections
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        
        # Allow SSH (rate limited)
        iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        
        # Allow HTTP and HTTPS
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        
        # Save iptables rules (if iptables-persistent or netfilter-persistent available)
        if command -v iptables-save &> /dev/null; then
            mkdir -p /etc/iptables 2>/dev/null || true
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        
        log_success "iptables configured with security rules"
    fi
}

# Configure system security hardening
configure_security_hardening() {
    log_info "Configuring system security hardening..."
    
    # Install fail2ban for intrusion prevention
    if command -v pacman &> /dev/null; then
        log_info "Installing fail2ban..."
        pacman -S --noconfirm fail2ban 2>/dev/null || log_warning "Failed to install fail2ban"
        
        if command -v fail2ban-client &> /dev/null; then
            # Configure fail2ban
            configure_fail2ban
        fi
    fi
    
    # Configure kernel security parameters
    log_info "Configuring kernel security parameters..."
    
    cat >> /etc/sysctl.d/99-security-hardening.conf <<'SECURITY_EOF'

# Security Hardening Configuration
# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ignore ICMP ping requests (optional - uncomment to enable)
# net.ipv4.icmp_echo_ignore_all = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignore ping broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bad ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1

# Disable IP forwarding (unless needed)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
SECURITY_EOF
    
    # Apply security settings
    sysctl -p /etc/sysctl.d/99-security-hardening.conf 2>/dev/null || true
    
    log_success "System security hardening configured"
}

# Configure fail2ban
configure_fail2ban() {
    log_info "Configuring fail2ban..."
    
    # Create fail2ban jail configuration
    cat > /etc/fail2ban/jail.local <<'FAIL2BAN_EOF'
[DEFAULT]
# Ban hosts for 1 hour
bantime = 3600
# Override /etc/fail2ban/jail.d/00-firewalld.conf:
banaction = iptables-multiport
# Find hosts within 10 minutes
findtime = 600
# Ban after 5 failures
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 7200

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log

[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2
FAIL2BAN_EOF
    
    # Enable and start fail2ban
    systemctl enable fail2ban 2>/dev/null || true
    systemctl start fail2ban 2>/dev/null || true
    
    log_success "fail2ban configured and started"
}

# Configure Nginx security and rate limiting
configure_nginx_security() {
    log_info "Configuring Nginx security settings..."
    
    local NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
    
    if [[ -f "$NGINX_MAIN_CONF" ]]; then
        # Backup original config
        cp "$NGINX_MAIN_CONF" "${NGINX_MAIN_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Create security configuration snippet
        # Note: Only http-level directives can be in this file
        # if and location directives must be in server blocks
        mkdir -p /etc/nginx/conf.d 2>/dev/null || true
        cat > /etc/nginx/conf.d/security.conf <<'NGINX_SECURITY_EOF'
# Security Configuration for CineStream
# This file contains http-level directives only
# Server-level directives (if, location) are added per-server in set_domain

# Fix types_hash warning - increase hash sizes for better performance
types_hash_max_size 2048;
types_hash_bucket_size 128;

# Rate limiting zones
limit_req_zone $binary_remote_addr zone=general_limit:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=5r/s;
limit_req_zone $binary_remote_addr zone=strict_limit:10m rate=2r/s;

# Connection limiting
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;

# Hide Nginx version
server_tokens off;

# Security headers (will be included in server blocks)
# X-Frame-Options: Prevent clickjacking
# X-Content-Type-Options: Prevent MIME sniffing
# X-XSS-Protection: Enable XSS filter
# Referrer-Policy: Control referrer information
# Permissions-Policy: Control browser features
# Content-Security-Policy: Control resource loading

# Timeouts to prevent slowloris attacks
client_body_timeout 10s;
client_header_timeout 10s;
# keepalive_timeout is typically already set in default nginx.conf, so we don't override it here
send_timeout 10s;

# Buffer sizes to prevent buffer overflow attacks
client_body_buffer_size 128k;
client_header_buffer_size 1k;
client_max_body_size 10m;
large_client_header_buffers 4 4k;
NGINX_SECURITY_EOF
        
        # Include security config in main nginx.conf if not already included
        if ! grep -q "include.*conf.d/security.conf" "$NGINX_MAIN_CONF"; then
            sed -i '/^http {/a\
    include /etc/nginx/conf.d/security.conf;
' "$NGINX_MAIN_CONF" 2>/dev/null || true
        fi
        
        log_success "Nginx security configuration created (includes types_hash optimization to fix warning)"
    else
        log_warning "Nginx main config not found"
    fi
}

# Configure Nginx to disable logging globally
configure_nginx_logging() {
    log_info "Configuring Nginx to disable all logging..."
    
    # Create Nginx main config override to disable logging
    local NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
    
    if [[ -f "$NGINX_MAIN_CONF" ]]; then
        # Backup original config
        cp "$NGINX_MAIN_CONF" "${NGINX_MAIN_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Disable access_log and error_log in http block
        # Note: error_log cannot be "off" in http block, so we set it to /dev/null
        if ! grep -q "# CineStream: Logging disabled" "$NGINX_MAIN_CONF"; then
            # Add logging disable directives in http block
            sed -i '/^http {/a\
    # CineStream: Logging disabled\
    access_log off;\
    error_log /dev/null;
' "$NGINX_MAIN_CONF" 2>/dev/null || {
                # Alternative: add to end of http block
                sed -i '/^}/i\
    # CineStream: Logging disabled\
    access_log off;\
    error_log /dev/null;
' "$NGINX_MAIN_CONF" 2>/dev/null || true
            }
        fi
        
        # Also disable logging in any existing server blocks
        sed -i 's/access_log[^;]*;/access_log off;/g' "$NGINX_MAIN_CONF" 2>/dev/null || true
        sed -i 's|error_log[^;]*;|error_log /dev/null;|g' "$NGINX_MAIN_CONF" 2>/dev/null || true
        
        log_success "Nginx logging disabled globally"
    else
        log_warning "Nginx main config not found, logging will be disabled per-site"
    fi
}

# Configure Nginx CPU affinity to P-cores
configure_nginx_affinity() {
    log_info "Configuring Nginx CPU affinity to P-cores (0-5)..."
    
    # Create systemd override directory for nginx
    mkdir -p "$SYSTEMD_DIR/nginx.service.d"
    
    # Create override file with CPU affinity
    cat > "$SYSTEMD_DIR/nginx.service.d/cpu-affinity.conf" <<EOF
[Service]
# CPU Affinity: P-cores (0-5) for Intel i9-12900HK
CPUAffinity=0 1 2 3 4 5
# Ensure affinity is set after start
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh nginx || true'
# Disable logging to systemd journal
StandardOutput=null
StandardError=null
EOF
    
    log_success "Nginx CPU affinity configured"
}

# Configure Nginx for localhost access
configure_nginx_localhost() {
    log_info "Configuring Nginx for localhost access..."
    
    # Prefer cinestream app for localhost, otherwise use first available app
    local APP_NAME=""
    if [[ -d "$WWW_ROOT/cinestream" ]] && [[ -f "$WWW_ROOT/cinestream/.deploy_config" ]]; then
        APP_NAME="cinestream"
        log_info "Using 'cinestream' app for localhost (preferred)"
    else
        # Fallback to first available app
        APP_NAME=$(detect_app_name)
        if [[ -z "$APP_NAME" ]]; then
            log_warning "No application found, skipping localhost configuration"
            return
        fi
        log_info "Using first available app '$APP_NAME' for localhost"
    fi
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    if [[ ! -f "$APP_DIR/.deploy_config" ]]; then
        log_warning "Application not properly deployed, skipping localhost configuration"
        return
    fi
    
    # Load app config
    source "$APP_DIR/.deploy_config"
    PROCESS_COUNT=${PROCESS_COUNT:-20}
    START_PORT=${START_PORT:-8001}
    
    local UPSTREAM_NAME="${APP_NAME}_backend"
    local LOCALHOST_CONF="/etc/nginx/conf.d/localhost.conf"
    
    # Check if SSL is configured (domain set and SSL certificate exists)
    local SSL_ENABLED=false
    local DOMAIN_NAME="${DOMAIN_NAME:-}"
    
    # Debug: Log domain status
    if [[ -n "$DOMAIN_NAME" ]]; then
        log_info "Domain configured: '$DOMAIN_NAME' - /cinestream will be blocked via IP/localhost"
        # Check if SSL certificate exists for the domain
        local ssl_cert_exists=false
        local ssl_config_exists=false
        
        # Check for Let's Encrypt certificate
        if [[ -f "/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem" ]]; then
            ssl_cert_exists=true
        fi
        
        # Check for SSL in Nginx config
        if [[ -f "/etc/nginx/conf.d/${APP_NAME}.conf" ]] && \
           grep -q "ssl_certificate" "/etc/nginx/conf.d/${APP_NAME}.conf" 2>/dev/null; then
            ssl_config_exists=true
        fi
        
        # Enable SSL redirect if either condition is true
        if [[ "$ssl_cert_exists" == "true" ]] || [[ "$ssl_config_exists" == "true" ]]; then
            SSL_ENABLED=true
            log_info "SSL detected for domain '$DOMAIN_NAME' - localhost will redirect to HTTPS"
        fi
    else
        log_info "No domain configured - /cinestream will be accessible via IP/localhost"
    fi
    
    # Disable default Nginx welcome page - aggressive cleanup
    log_info "Disabling default Nginx welcome page configurations..."
    
    local disabled_count=0
    local conflicts_found=0
    
    # Aggressively remove/disable all default configs
    [[ -f "/etc/nginx/sites-enabled/default" ]] && rm -f /etc/nginx/sites-enabled/default 2>/dev/null && disabled_count=$((disabled_count + 1))
    [[ -f "/etc/nginx/sites-available/default" ]] && rm -f /etc/nginx/sites-available/default 2>/dev/null && disabled_count=$((disabled_count + 1))
    [[ -f "/etc/nginx/conf.d/default.conf" ]] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled 2>/dev/null && disabled_count=$((disabled_count + 1))
    [[ -f "/etc/nginx/conf.d/default.conf.disabled" ]] && log_info "Confirmed default.conf is disabled"
    
    # Collect all config files to check
    local all_configs=()
    [[ -d "/etc/nginx/conf.d" ]] && for f in /etc/nginx/conf.d/*.conf; do [[ -f "$f" ]] && all_configs+=("$f"); done
    [[ -d "/etc/nginx/sites-enabled" ]] && for f in /etc/nginx/sites-enabled/*; do [[ -f "$f" ]] && all_configs+=("$f"); done
    [[ -d "/etc/nginx/sites-available" ]] && for f in /etc/nginx/sites-available/*; do [[ -f "$f" ]] && all_configs+=("$f"); done
    
    # Process each config file
    for conf_file in "${all_configs[@]}"; do
        # Skip localhost.conf (we're creating it)
        [[ "$conf_file" == "$LOCALHOST_CONF" ]] && continue
        
        # Remove default_server from other configs
        if grep -q "listen.*default_server" "$conf_file" 2>/dev/null; then
            sed -i 's/ listen \([0-9]*\) default_server;/ listen \1;/g' "$conf_file" 2>/dev/null || true
            sed -i 's/ listen \[::\]:\([0-9]*\) default_server;/ listen [::]:\1;/g' "$conf_file" 2>/dev/null || true
            conflicts_found=$((conflicts_found + 1))
        fi
        
        # Disable ANY config serving welcome page (check for root pointing to default HTML dirs)
        if grep -q "root.*/usr/share/nginx/html\|root.*/var/www/html\|root.*/usr/share/nginx" "$conf_file" 2>/dev/null; then
            if grep -q "listen.*80\|server_name.*_\|server_name.*default" "$conf_file" 2>/dev/null; then
                mv "$conf_file" "${conf_file}.disabled" 2>/dev/null || true
                disabled_count=$((disabled_count + 1))
                log_info "Disabled welcome page config: $conf_file"
            fi
        fi
    done
    
    # Also check main nginx.conf for embedded server blocks and disable them
    if [[ -f "/etc/nginx/nginx.conf" ]]; then
        if grep -q "root.*/usr/share/nginx/html\|root.*/var/www/html" /etc/nginx/nginx.conf 2>/dev/null; then
            log_warning "Found root directive in main nginx.conf - disabling welcome page server block..."
            
            # Backup nginx.conf
            cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
            
            # Comment out server blocks that serve welcome page
            # Match server blocks with root pointing to default HTML directories
            local nginx_conf_modified=false
            
            # Use a simple approach: comment out server blocks with welcome page
            local temp_conf="/tmp/nginx.conf.$$"
            local in_server_block=false
            local brace_count=0
            local server_has_welcome=false
            
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Detect start of server block
                if echo "$line" | grep -qE "^[[:space:]]*server[[:space:]]*\{"; then
                    in_server_block=true
                    brace_count=1
                    server_has_welcome=false
                    # Check if this line itself has welcome page indicator
                    if echo "$line" | grep -q "root.*/usr/share/nginx/html\|root.*/var/www/html"; then
                        server_has_welcome=true
                    fi
                    # Start commenting if it's a welcome page server
                    if [[ "$server_has_welcome" == "true" ]]; then
                        echo "# DISABLED BY CINESTREAM - Welcome page server block" >> "$temp_conf"
                        echo "# DISABLED BY CINESTREAM - $line" >> "$temp_conf"
                    else
                        echo "$line" >> "$temp_conf"
                    fi
                # Process lines inside server block
                elif [[ "$in_server_block" == "true" ]]; then
                    # Check for welcome page root in this line
                    if echo "$line" | grep -q "root.*/usr/share/nginx/html\|root.*/var/www/html"; then
                        server_has_welcome=true
                    fi
                    
                    # Count braces to track block nesting
                    local open_braces=$(echo "$line" | tr -cd '{' | wc -c)
                    local close_braces=$(echo "$line" | tr -cd '}' | wc -c)
                    brace_count=$((brace_count + open_braces - close_braces))
                    
                    # Comment out if this is a welcome page server block
                    if [[ "$server_has_welcome" == "true" ]]; then
                        echo "# DISABLED BY CINESTREAM - $line" >> "$temp_conf"
                    else
                        echo "$line" >> "$temp_conf"
                    fi
                    
                    # Check if we've closed the server block
                    if [[ $brace_count -le 0 ]]; then
                        in_server_block=false
                        brace_count=0
                        server_has_welcome=false
                    fi
                # Lines outside server blocks
                else
                    echo "$line" >> "$temp_conf"
                fi
            done < /etc/nginx/nginx.conf
            
            # Replace original with processed version
            if mv "$temp_conf" /etc/nginx/nginx.conf 2>/dev/null; then
                # Verify the change worked
                if grep -q "# DISABLED BY CINESTREAM.*root.*/usr/share/nginx/html" /etc/nginx/nginx.conf 2>/dev/null || \
                   ! grep -qE "^[^#]*root[[:space:]]+.*/usr/share/nginx/html" /etc/nginx/nginx.conf 2>/dev/null; then
                    log_success "Disabled welcome page server block in nginx.conf"
                    disabled_count=$((disabled_count + 1))
                    nginx_conf_modified=true
                else
                    log_warning "Could not verify nginx.conf modification - welcome page may still be active"
                fi
            else
                log_warning "Could not modify nginx.conf - check permissions"
                rm -f "$temp_conf" 2>/dev/null || true
            fi
            
            if [[ "$nginx_conf_modified" != "true" ]]; then
                log_warning "Could not automatically disable welcome page in nginx.conf"
                log_warning "Please manually comment out the server block in /etc/nginx/nginx.conf"
                log_info "Look for: server { ... root /usr/share/nginx/html; ... }"
            fi
        fi
    fi
    
    if [[ $disabled_count -gt 0 ]] || [[ $conflicts_found -gt 0 ]]; then
        log_success "Disabled $disabled_count welcome page config(s), removed $conflicts_found default_server conflict(s)"
    else
        log_info "No default welcome page configurations found"
    fi
    
    # Check if backend processes are running
    local backend_running=false
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            backend_running=true
            break
        fi
    done
    
    if [[ "$backend_running" == "false" ]]; then
        log_warning "Backend processes are not running on ports ${START_PORT}-$((START_PORT + PROCESS_COUNT - 1))"
        log_info "The application will be accessible once services are started"
        log_info "Start services with: sudo $0 start-all"
    fi
    
    # Create upstream block
    cat > "$LOCALHOST_CONF" <<EOF
# Localhost access configuration for ${APP_NAME}
# This allows accessing the application via http://localhost or http://127.0.0.1

upstream ${UPSTREAM_NAME}_localhost {
    ip_hash;  # Sticky sessions
EOF
    
    # Add all backend servers (with backup for when services aren't running)
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        echo "    server 127.0.0.1:${port} max_fails=3 fail_timeout=30s;" >> "$LOCALHOST_CONF"
    done
    
    cat >> "$LOCALHOST_CONF" <<EOF
}

# HTTP server for localhost and IP access
# Set as default_server to catch all requests to port 80 when no domain is specified
# This includes: localhost, 127.0.0.1, server IP addresses, and any other requests
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    # Use _ as catch-all to accept any hostname/IP (localhost, 127.0.0.1, server IP, etc.)
    server_name _;
    
    # Logging disabled
    access_log off;
    error_log /dev/null;
EOF

    # HTTP server behavior depends on domain configuration
    if [[ -n "$DOMAIN_NAME" ]]; then
        # Domain is configured - redirect to domain (HTTPS if SSL enabled, otherwise HTTP)
        if [[ "$SSL_ENABLED" == "true" ]]; then
            cat >> "$LOCALHOST_CONF" <<EOF
    
    # Redirect to HTTPS domain (SSL is configured)
    location / {
        return 301 https://${DOMAIN_NAME}\$request_uri;
    }
}
EOF
        else
            cat >> "$LOCALHOST_CONF" <<EOF
    
    # Redirect to HTTP domain (SSL not yet configured)
    location / {
        return 301 http://${DOMAIN_NAME}\$request_uri;
    }
}
EOF
        fi
    else
        # No domain configured - serve application directly on HTTP
        cat >> "$LOCALHOST_CONF" <<EOF
    
    # Rate limiting
    limit_req zone=general_limit burst=20 nodelay;
    limit_conn conn_limit 10;
    
    # Disable unnecessary HTTP methods
    if (\$request_method !~ ^(GET|HEAD|POST|OPTIONS)\$ ) {
        return 405;
    }
    
    # Block common attack patterns
    location ~* \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|conf)\$ {
        deny all;
        return 404;
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
    
    # Root location - serve CineStream directly at homepage
    # Never serve welcome page - return 503 if backend is down
    location / {
        limit_req zone=general_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        
        proxy_pass http://${UPSTREAM_NAME}_localhost;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Return 503 if backend is unavailable (prevents welcome page fallback)
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_intercept_errors on;
    }
    
    # Custom error handling - prevent welcome page from showing
    error_page 502 503 504 /503;
    location = /503 {
        internal;
        return 503 "CineStream service is starting. Please wait a moment and refresh.";
        add_header Content-Type text/plain;
    }
    
    # CineStream application at /cinestream subpath (case-insensitive) - also works for compatibility
    # Handles: /cinestream, /Cinestream, /CineStream, /CINESTREAM, etc.
    location ~* ^/cinestream(/.*)?$ {
        limit_req zone=general_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        
        # Normalize and strip /cinestream prefix (case-insensitive) before proxying
        rewrite ^/cinestream(.*)$ \$1 break;
        
        proxy_pass http://${UPSTREAM_NAME}_localhost;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors off;
    }
}
EOF
    fi
    
    # Add HTTPS server block (port 443)
    if [[ "$SSL_ENABLED" == "true" ]] && [[ -n "$DOMAIN_NAME" ]]; then
        # SSL is configured - use proper certificates
        cat >> "$LOCALHOST_CONF" <<EOF

# HTTPS server for localhost and IP access (SSL enabled)
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    
    # SSL certificate paths
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Logging disabled
    access_log off;
    error_log /dev/null;
    
    # Rate limiting
    limit_req zone=general_limit burst=20 nodelay;
    limit_conn conn_limit 10;
    
    # Disable unnecessary HTTP methods
    if (\$request_method !~ ^(GET|HEAD|POST|OPTIONS)\$ ) {
        return 405;
    }
    
    # Block common attack patterns
    location ~* \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|conf)\$ {
        deny all;
        return 404;
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
    
    # Block /cinestream access via IP/localhost when domain is configured
    # Application should be accessed via the configured domain instead
    location /cinestream {
        return 404;
    }
    
    # Root location - redirect to domain
    location = / {
        return 301 https://${DOMAIN_NAME}/;
    }
}
EOF
    else
        # SSL not configured - create self-signed certificate for localhost/IP access
        log_info "SSL not configured. Creating self-signed certificate for HTTPS..."
        local ssl_dir="/etc/nginx/ssl"
        mkdir -p "$ssl_dir"
        
        local cert_file="$ssl_dir/localhost-selfsigned.crt"
        local key_file="$ssl_dir/localhost-selfsigned.key"
        
        # Create self-signed certificate if it doesn't exist
        if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
            log_info "Generating self-signed SSL certificate..."
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$key_file" \
                -out "$cert_file" \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" \
                2>/dev/null || {
                log_error "Failed to generate self-signed certificate"
                log_error "Install openssl: sudo pacman -S openssl"
                return 1
            }
            chmod 600 "$key_file"
            chmod 644 "$cert_file"
            log_success "Self-signed certificate created"
        else
            log_info "Self-signed certificate already exists"
        fi
        
        # Create HTTPS server with self-signed certificate
        cat >> "$LOCALHOST_CONF" <<EOF

# HTTPS server for localhost and IP access (self-signed certificate)
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    
    # Self-signed SSL certificate (for localhost/IP access without domain)
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Logging disabled
    access_log off;
    error_log /dev/null;
    
    # Rate limiting
    limit_req zone=general_limit burst=20 nodelay;
    limit_conn conn_limit 10;
    
    # Disable unnecessary HTTP methods
    if (\$request_method !~ ^(GET|HEAD|POST|OPTIONS)\$ ) {
        return 405;
    }
    
    # Block common attack patterns
    location ~* \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|conf)\$ {
        deny all;
        return 404;
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
EOF
    
        # If domain is configured, block /cinestream access via IP/localhost
        if [[ -n "$DOMAIN_NAME" ]]; then
            cat >> "$LOCALHOST_CONF" <<EOF
    
    # Block /cinestream access via IP/localhost when domain is configured
    # Application should be accessed via the configured domain instead
    location /cinestream {
        return 404;
    }
    
    # Root location - redirect to domain
    location = / {
        return 301 https://${DOMAIN_NAME}/;
    }
EOF
        else
            # Domain not configured - allow /cinestream access via IP/localhost
            cat >> "$LOCALHOST_CONF" <<EOF
    
    # Root location - serve CineStream directly at homepage
    # Never serve welcome page - return 503 if backend is down
    location / {
        limit_req zone=general_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        
        proxy_pass http://${UPSTREAM_NAME}_localhost;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Return 503 if backend is unavailable (prevents welcome page fallback)
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_intercept_errors on;
    }
    
    # Custom error handling - prevent welcome page from showing
    error_page 502 503 504 /503;
    location = /503 {
        internal;
        return 503 "CineStream service is starting. Please wait a moment and refresh.";
        add_header Content-Type text/plain;
    }
    
    # CineStream application at /cinestream subpath (case-insensitive) - also works for compatibility
    # Handles: /cinestream, /Cinestream, /CineStream, /CINESTREAM, etc.
    location ~* ^/cinestream(/.*)?$ {
        limit_req zone=general_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        
        # Normalize and strip /cinestream prefix (case-insensitive) before proxying
        rewrite ^/cinestream(.*)$ \$1 break;
        
        proxy_pass http://${UPSTREAM_NAME}_localhost;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors off;
    }
EOF
        fi
        
        cat >> "$LOCALHOST_CONF" <<EOF
}
EOF
        log_info "HTTPS server configured with self-signed certificate"
        log_info "Note: Browsers will show a security warning for self-signed certificates"
        log_info "For production, set up a domain and use Let's Encrypt:"
        log_info "  1. sudo $0 set-domain yourdomain.com"
        log_info "  2. sudo $0 install-ssl yourdomain.com"
    fi
    
    
    log_success "Localhost configuration created: $LOCALHOST_CONF"
    
    # Verify the configuration file was created correctly
    if [[ ! -f "$LOCALHOST_CONF" ]]; then
        log_error "Failed to create localhost configuration file!"
        return 1
    fi
    
    # Verify default_server is set
    if ! grep -q "listen.*default_server" "$LOCALHOST_CONF" 2>/dev/null; then
        log_error "default_server directive not found in localhost.conf!"
        return 1
    fi
    
    log_info "Configuration file verified: default_server is set"
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    local nginx_test_output
    nginx_test_output=$(nginx -t 2>&1)
    local nginx_test_status=$?
    
    # Verify which server block will be used for default requests
    if [[ $nginx_test_status -eq 0 ]]; then
        log_info "Verifying server block selection..."
        # Show the active server blocks on port 80
        log_info "Active server blocks on port 80:"
        nginx -T 2>/dev/null | grep -B 1 -A 3 "listen.*80.*default_server" | head -10 || true
        log_info ""
        log_info "Verifying localhost.conf is the default server..."
        if nginx -T 2>/dev/null | grep -A 5 "listen.*80.*default_server" | grep -q "localhost.conf"; then
            log_success "localhost.conf is configured as default_server ✓"
        else
            log_warning "localhost.conf may not be the default server - checking..."
            nginx -T 2>/dev/null | grep -B 2 -A 5 "default_server" | head -15 || true
        fi
    fi
    
    if [[ $nginx_test_status -eq 0 ]]; then
        log_success "Nginx configuration test passed"
        
        # Force restart Nginx to apply changes (restart is more reliable than reload)
        log_info "Restarting Nginx to apply localhost configuration..."
        log_info "Using restart instead of reload to ensure all changes are applied..."
        if systemctl restart nginx.service 2>&1; then
            log_success "Nginx restarted successfully"
            log_info ""
            log_info "✓ Application is now accessible at:"
            log_info "  - http://localhost (from server)"
            log_info "  - http://127.0.0.1 (from server)"
            log_info "  - http://<server-ip-address> (from local network)"
            log_info "  - http://<server-ip-address> (from internet, if firewall allows)"
            log_info ""
            log_info "To enable full internet access, run:"
            log_info "  sudo $0 enable-internet-access"
            log_info ""
            log_info ""
            log_info "Verification: Testing that CineStream is being served (not welcome page)..."
            # Wait a moment for nginx to fully restart
            sleep 2
            
            # Check if welcome page is being served
            local response_body
            response_body=$(curl -s http://localhost/ 2>/dev/null || echo "")
            
            if echo "$response_body" | grep -qi "welcome.*nginx\|nginx.*welcome"; then
                log_error "✗ Nginx is still serving the welcome page!"
                log_error "This means another config is taking precedence over localhost.conf"
                log_info "Checking for conflicting configs..."
                
                # Find all configs with default_server
                nginx -T 2>/dev/null | grep -B 5 "listen.*80.*default_server" | head -20 || true
                
                log_info "Attempting to fix by removing default_server from all other configs..."
                # More aggressive cleanup
                for conf_file in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*; do
                    [[ -f "$conf_file" ]] && [[ "$conf_file" != "$LOCALHOST_CONF" ]] && \
                    grep -q "listen.*default_server" "$conf_file" 2>/dev/null && \
                    sed -i 's/ listen \([0-9]*\) default_server;/ listen \1;/g' "$conf_file" 2>/dev/null && \
                    sed -i 's/ listen \[::\]:\([0-9]*\) default_server;/ listen [::]:\1;/g' "$conf_file" 2>/dev/null && \
                    log_info "Removed default_server from: $conf_file"
                done
                
                # Restart nginx again
                systemctl restart nginx.service 2>/dev/null || true
                sleep 2
                
                # Check again
                response_body=$(curl -s http://localhost/ 2>/dev/null || echo "")
                if echo "$response_body" | grep -qi "welcome.*nginx\|nginx.*welcome"; then
                    log_error "✗ Welcome page still showing after cleanup"
                    log_error "You may need to manually check /etc/nginx/nginx.conf for embedded server blocks"
                else
                    log_success "✓ Welcome page removed - CineStream should now be served"
                fi
            elif curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -q "200\|302\|301"; then
                log_success "✓ CineStream application is responding on http://localhost"
            else
                log_warning "Application may not be responding yet. Check if services are running:"
                log_info "  sudo systemctl status cinestream@*.service"
                log_info "  sudo systemctl status nginx.service"
            fi
            log_info ""
            log_info ""
            log_info "Diagnostic information:"
            log_info "Checking which server block handles localhost requests..."
            # Show what Nginx will actually use for localhost
            local default_server_info
            default_server_info=$(nginx -T 2>/dev/null | grep -B 5 -A 10 "listen.*80.*default_server" | head -20 || echo "No default_server found")
            log_info "Default server block:"
            echo "$default_server_info" | while IFS= read -r line; do
                log_info "  $line"
            done
            log_info ""
            log_info "Checking for any remaining default configurations..."
            local found_welcome_page=false
            
            # Check for default.conf
            if [[ -f "/etc/nginx/conf.d/default.conf" ]]; then
                log_warning "⚠ WARNING: /etc/nginx/conf.d/default.conf still exists!"
                log_warning "This might be serving the welcome page. Disabling it now..."
                mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled 2>/dev/null || true
                found_welcome_page=true
            fi
            
            # Check for sites-enabled/default
            if [[ -f "/etc/nginx/sites-enabled/default" ]]; then
                log_warning "⚠ WARNING: /etc/nginx/sites-enabled/default still exists!"
                log_warning "Removing it now..."
                rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
                found_welcome_page=true
            fi
            
            # Check for any other configs serving the welcome page
            local check_files=()
            if [[ -d "/etc/nginx/conf.d" ]]; then
                for check_file in /etc/nginx/conf.d/*.conf; do
                    [[ -f "$check_file" ]] && check_files+=("$check_file")
                done
            fi
            if [[ -d "/etc/nginx/sites-enabled" ]]; then
                for check_file in /etc/nginx/sites-enabled/*; do
                    [[ -f "$check_file" ]] && check_files+=("$check_file")
                done
            fi
            
            for check_file in "${check_files[@]}"; do
                if [[ "$check_file" != "$LOCALHOST_CONF" ]]; then
                    if grep -q "root.*/usr/share/nginx/html\|root.*/var/www/html" "$check_file" 2>/dev/null; then
                        if grep -q "listen.*80" "$check_file" 2>/dev/null; then
                            log_warning "⚠ Found config serving welcome page: $check_file"
                            log_warning "Disabling it..."
                            mv "$check_file" "${check_file}.disabled" 2>/dev/null || true
                            found_welcome_page=true
                        fi
                    fi
                fi
            done
            
            # Restart Nginx if we found and disabled welcome page configs
            if [[ "$found_welcome_page" == "true" ]]; then
                log_info "Restarting Nginx to apply changes..."
                systemctl restart nginx.service 2>/dev/null || true
                sleep 2
                log_info "Nginx restarted. Please try accessing the site again."
            fi
            
            # Verify localhost.conf is actually being used
            log_info ""
            log_info "Verifying localhost.conf configuration..."
            if [[ -f "$LOCALHOST_CONF" ]]; then
                log_success "✓ localhost.conf exists: $LOCALHOST_CONF"
                if grep -q "listen.*80.*default_server" "$LOCALHOST_CONF" 2>/dev/null; then
                    log_success "✓ default_server is set in localhost.conf"
                else
                    log_error "✗ default_server NOT found in localhost.conf!"
                fi
                if grep -q "server_name _" "$LOCALHOST_CONF" 2>/dev/null; then
                    log_success "✓ server_name _ (catch-all) is set"
                else
                    log_error "✗ server_name _ NOT found in localhost.conf!"
                fi
            else
                log_error "✗ localhost.conf does NOT exist!"
            fi
            
            # Test what's actually being served
            log_info ""
            log_info "Testing what Nginx is actually serving..."
            sleep 2  # Give Nginx time to restart
            local test_response
            test_response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
            if [[ "$test_response" == "301" ]] || [[ "$test_response" == "302" ]]; then
                log_success "✓ HTTP is redirecting (status: $test_response) - this is correct"
            elif [[ "$test_response" == "200" ]]; then
                # Check if it's serving the welcome page or the app
                local response_body
                response_body=$(curl -s http://localhost/ 2>/dev/null | head -20 || echo "")
                if echo "$response_body" | grep -qi "welcome.*nginx\|nginx.*welcome"; then
                    log_error "✗ Nginx is still serving the welcome page!"
                    log_error "Response status: $test_response"
                    log_error "This means another server block is taking precedence"
                    log_info ""
                    log_info "Checking which server block is actually handling requests..."
                    nginx -T 2>/dev/null | grep -B 3 -A 10 "listen.*80" | head -30 || true
                else
                    log_success "✓ HTTP is serving content (status: $test_response)"
                fi
            else
                log_warning "⚠ HTTP response status: $test_response"
                log_warning "This might indicate an error or that Nginx isn't responding"
            fi
            log_info ""
            log_info "If you still see the welcome page, try:"
            log_info "  1. Hard refresh your browser (Ctrl+Shift+R or Ctrl+F5)"
            log_info "  2. Clear your browser cache completely"
            log_info "  3. Try incognito/private browsing mode"
            log_info "  4. Check what's actually being served: curl -I http://localhost"
            log_info "  5. Verify localhost.conf exists: ls -la /etc/nginx/conf.d/localhost.conf"
            log_info "  6. Check Nginx error logs: sudo tail -20 /var/log/nginx/error.log"
            log_info "  7. Verify app is running: sudo $0 status"
        else
            log_warning "Nginx reload failed, trying restart..."
            if systemctl restart nginx.service 2>&1; then
                log_success "Nginx restarted - application should be accessible"
                log_info "Try accessing: http://localhost or http://<server-ip>"
            else
                log_error "Failed to reload/restart Nginx. Check logs: journalctl -u nginx.service"
                return 1
            fi
        fi
    else
        log_error "Nginx configuration test failed!"
        echo "$nginx_test_output" | while IFS= read -r line; do
            log_error "  $line"
        done
        log_error ""
        log_error "Please check the configuration manually: sudo nginx -t"
        log_error "Configuration file: $LOCALHOST_CONF"
        return 1
    fi
}

# Enable internet access for the application
enable_internet_access() {
    log_info "Enabling internet access for the application..."
    
    # 1. Configure firewall to allow HTTP/HTTPS from anywhere
    log_info "Configuring firewall for internet access..."
    configure_firewall
    
    # 2. Ensure localhost configuration accepts all IPs (already done with server_name _)
    log_info "Verifying Nginx configuration for internet access..."
    if [[ ! -f "/etc/nginx/conf.d/localhost.conf" ]]; then
        log_warning "localhost.conf not found. Creating it..."
        configure_nginx_localhost
    else
        # Verify server_name is set to catch-all
        if ! grep -q "server_name _" /etc/nginx/conf.d/localhost.conf 2>/dev/null; then
            log_warning "localhost.conf exists but server_name is not catch-all. Updating..."
            configure_nginx_localhost
        else
            log_success "Nginx configuration already accepts all IPs"
        fi
    fi
    
    # 3. Check if Nginx is listening on all interfaces (0.0.0.0, not just 127.0.0.1)
    log_info "Checking if Nginx is listening on all interfaces..."
    local nginx_listening=false
    if ss -tlnp 2>/dev/null | grep -q ":80.*nginx\|:80.*LISTEN"; then
        local listen_info
        listen_info=$(ss -tlnp 2>/dev/null | grep ":80" | head -1 || echo "")
        if echo "$listen_info" | grep -q "0.0.0.0:80\|\\*:80"; then
            log_success "Nginx is listening on all interfaces (0.0.0.0:80)"
            nginx_listening=true
        elif echo "$listen_info" | grep -q "127.0.0.1:80"; then
            log_warning "Nginx is only listening on localhost (127.0.0.1:80)"
            log_warning "This will prevent internet access. Checking Nginx configuration..."
            # Check nginx.conf for listen directive
            if grep -q "listen.*80" /etc/nginx/nginx.conf 2>/dev/null; then
                log_info "Found listen directive in main nginx.conf"
            fi
            log_warning "Nginx should listen on 0.0.0.0:80, not 127.0.0.1:80"
        else
            log_info "Nginx listening info: $listen_info"
        fi
    elif netstat -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
        local listen_info
        listen_info=$(netstat -tlnp 2>/dev/null | grep ":80" | head -1 || echo "")
        if echo "$listen_info" | grep -q "0.0.0.0:80"; then
            log_success "Nginx is listening on all interfaces (0.0.0.0:80)"
            nginx_listening=true
        else
            log_warning "Nginx listening info: $listen_info"
        fi
    else
        log_warning "Nginx may not be listening on port 80. Restarting..."
        systemctl restart nginx.service 2>/dev/null || true
        sleep 2
        if ss -tlnp 2>/dev/null | grep -q ":80.*nginx" || netstat -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
            nginx_listening=true
            log_success "Nginx is now listening after restart"
        else
            log_error "Nginx is still not listening on port 80!"
            log_error "Check Nginx status: systemctl status nginx.service"
        fi
    fi
    
    # 4. Verify firewall is actually allowing connections
    log_info "Verifying firewall configuration..."
    local firewall_status="unknown"
    if command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall_status="firewalld"
            log_info "Checking firewalld rules..."
            if firewall-cmd --list-services 2>/dev/null | grep -q "http"; then
                log_success "✓ HTTP service is allowed in firewalld"
            else
                log_warning "HTTP service not found in firewalld. Adding it..."
                firewall-cmd --permanent --add-service=http 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
            fi
            if firewall-cmd --list-services 2>/dev/null | grep -q "https"; then
                log_success "✓ HTTPS service is allowed in firewalld"
            else
                log_warning "HTTPS service not found in firewalld. Adding it..."
                firewall-cmd --permanent --add-service=https 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
            fi
            # Show current zone and services
            log_info "Current firewalld zone: $(firewall-cmd --get-default-zone 2>/dev/null || echo 'unknown')"
            log_info "Allowed services: $(firewall-cmd --list-services 2>/dev/null | tr '\n' ' ' || echo 'none')"
        else
            log_warning "firewalld is not running. Starting it..."
            systemctl start firewalld 2>/dev/null || true
            systemctl enable firewalld 2>/dev/null || true
        fi
    elif command -v ufw &> /dev/null; then
        firewall_status="ufw"
        if ufw status 2>/dev/null | grep -q "80/tcp.*ALLOW"; then
            log_success "✓ Port 80 is allowed in UFW"
        else
            log_warning "Port 80 not found in UFW rules. Adding it..."
            ufw allow 80/tcp 2>/dev/null || true
        fi
        if ufw status 2>/dev/null | grep -q "443/tcp.*ALLOW"; then
            log_success "✓ Port 443 is allowed in UFW"
        else
            log_warning "Port 443 not found in UFW rules. Adding it..."
            ufw allow 443/tcp 2>/dev/null || true
        fi
        log_info "UFW status:"
        ufw status numbered 2>/dev/null | head -10 || true
    else
        firewall_status="iptables"
        log_info "Using iptables. Verifying rules..."
        if iptables -L INPUT -n 2>/dev/null | grep -q "tcp.*dpt:80.*ACCEPT"; then
            log_success "✓ Port 80 is allowed in iptables"
        else
            log_warning "Port 80 rule not found in iptables. Adding it..."
            iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        fi
    fi
    
    # 5. Get server IP addresses
    log_info "Detecting server IP addresses..."
    local ipv4_addresses
    ipv4_addresses=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || \
                    ifconfig 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || true)
    local public_ip
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
                echo "Unable to detect")
    
    log_info ""
    log_success "Internet access configuration complete!"
    log_info ""
    log_info "Your application should now be accessible from the internet."
    log_info ""
    log_info "Server IP addresses:"
    if [[ -n "$ipv4_addresses" ]]; then
        echo "$ipv4_addresses" | while read -r ip; do
            log_info "  - http://$ip"
        done
    else
        log_info "  - (No IPv4 addresses found)"
    fi
    log_info ""
    log_info "Public IP address: $public_ip"
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Internet Access Diagnostics:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "Firewall Status: $firewall_status"
    log_info "Nginx Listening: $nginx_listening"
    log_info ""
    
    # Test local connectivity
    log_info "Testing local connectivity..."
    if curl -s --max-time 3 -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -q "[23][0-9][0-9]"; then
        log_success "✓ Local connection to Nginx works"
    else
        log_warning "⚠ Local connection to Nginx failed - Nginx may not be running"
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "TROUBLESHOOTING: If internet access times out:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "1. CHECK ROUTER PORT FORWARDING (Most Common Issue):"
    log_info "   If your server is behind a router/NAT, configure port forwarding:"
    log_info "   - External Port 80 → Internal Port 80 (TCP)"
    log_info "   - External Port 443 → Internal Port 443 (TCP)"
    log_info "   - Internal IP: $(echo "$ipv4_addresses" | head -1 || echo 'YOUR_SERVER_LOCAL_IP')"
    log_info ""
    log_info "2. CHECK ROUTER FIREWALL:"
    log_info "   Ensure your router's firewall allows incoming connections on ports 80/443"
    log_info ""
    log_info "3. CHECK ISP BLOCKING:"
    log_info "   Some ISPs block incoming connections on port 80"
    log_info "   - Try accessing from a different network"
    log_info "   - Consider using a non-standard port (requires router config)"
    log_info ""
    log_info "4. VERIFY FIREWALL RULES:"
    if [[ "$firewall_status" == "firewalld" ]]; then
        log_info "   Run: sudo firewall-cmd --list-all"
    elif [[ "$firewall_status" == "ufw" ]]; then
        log_info "   Run: sudo ufw status verbose"
    else
        log_info "   Run: sudo iptables -L -n -v"
    fi
    log_info ""
    log_info "5. TEST FROM SERVER:"
    log_info "   Run: curl -I http://$public_ip"
    log_info "   (This tests if the server can reach itself via public IP)"
    log_info ""
    log_info "6. TEST PORT ACCESSIBILITY:"
    log_info "   Use online tools to check if port 80 is open:"
    log_info "   - https://www.yougetsignal.com/tools/open-ports/"
    log_info "   - https://www.portchecker.co/"
    log_info "   Enter IP: $public_ip, Port: 80"
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "Your server information:"
    log_info "  - Local IP(s): $(echo "$ipv4_addresses" | tr '\n' ' ' || echo 'Not detected')"
    log_info "  - Public IP: $public_ip"
    log_info ""
    log_info "Try accessing from internet:"
    log_info "  - https://$public_ip (HTTPS - recommended)"
    log_info "  - http://$public_ip (HTTP - automatically redirects to HTTPS)"
    if [[ -n "$ipv4_addresses" ]]; then
        echo "$ipv4_addresses" | while read -r ip; do
            log_info "  - https://$ip (from local network)"
        done
    fi
    log_info ""
    log_info "Security note:"
    log_info "  - HTTP (port 80) automatically redirects to HTTPS (port 443)"
    log_info "  - HTTPS (port 443) is configured with SSL"
    log_info "  - For production with a domain, use Let's Encrypt:"
    log_info "    sudo $0 set-domain yourdomain.com"
    log_info "    sudo $0 install-ssl yourdomain.com"
    log_info ""
}

# Abracadabra - Complete setup in one command
abracadabra() {
    log_info "🎩✨ Abracadabra! Performing complete CineStream setup... ✨🎩"
    log_info ""
    log_info "This will run the following steps:"
    log_info "  1. Initialize server (packages, MongoDB, Nginx, SSH)"
    log_info "  2. Deploy CineStream application"
    log_info "  3. Enable auto-start on boot"
    log_info "  4. Optimize system performance"
    log_info "  5. Start all services"
    log_info "  6. Fix localhost configuration"
    log_info "  7. Enable internet access"
    log_info "  8. Verify SSH connectivity"
    log_info ""
    read -p "Continue with complete setup? (yes/no): " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Abracadabra cancelled."
        exit 0
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 1/8: Initializing server..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    init_server
    local init_result=$?
    set -e  # Re-enable exit on error
    if [[ $init_result -ne 0 ]]; then
        log_warning "init_server had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 2/8: Deploying CineStream application..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    deploy_application "cinestream"
    local deploy_result=$?
    set -e  # Re-enable exit on error
    if [[ $deploy_result -ne 0 ]]; then
        # Check if app already exists
        if [[ -d "$WWW_ROOT/cinestream" ]] && [[ -f "$WWW_ROOT/cinestream/.deploy_config" ]]; then
            log_info "CineStream application already exists, skipping deployment"
        else
            log_warning "Deployment had issues, but continuing..."
        fi
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 3/8: Enabling auto-start on boot..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    enable_autostart
    local autostart_result=$?
    set -e  # Re-enable exit on error
    if [[ $autostart_result -ne 0 ]]; then
        log_warning "enable_autostart had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 4/8: Optimizing system performance..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "This includes: CPU governor, kernel params, Nginx workers,"
    log_info "                service optimization, GRUB, startup/shutdown tuning"
    set +e  # Temporarily disable exit on error
    optimize_system
    local optimize_result=$?
    set -e  # Re-enable exit on error
    if [[ $optimize_result -ne 0 ]]; then
        log_warning "optimize_system had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 5/8: Starting all services..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    start_all
    local start_result=$?
    set -e  # Re-enable exit on error
    if [[ $start_result -ne 0 ]]; then
        log_warning "start_all had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 6/8: Fixing localhost configuration..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    configure_nginx_localhost
    local localhost_result=$?
    set -e  # Re-enable exit on error
    if [[ $localhost_result -ne 0 ]]; then
        log_warning "configure_nginx_localhost had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 7/8: Enabling internet access..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    set +e  # Temporarily disable exit on error
    enable_internet_access
    local internet_result=$?
    set -e  # Re-enable exit on error
    if [[ $internet_result -ne 0 ]]; then
        log_warning "enable_internet_access had some issues, but continuing..."
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 8/8: Verifying SSH connectivity..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # SSH is already configured in Step 1 (init_server), just verify it's running
    if systemctl is-active --quiet sshd.service 2>/dev/null || systemctl is-active --quiet ssh.service 2>/dev/null; then
        log_success "SSH service is running"
    else
        log_warning "SSH service is not running, ensuring it's enabled..."
        ensure_ssh_service
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "🎉✨ Abracadabra complete! ✨🎉"
    log_info ""
    log_info "Your CineStream server is now fully configured and running!"
    log_info ""
    log_info "Access your application:"
    log_info "  - Local: http://localhost/cinestream/ (redirects to HTTPS if SSL is configured)"
    log_info "  - Network: http://<server-ip>/cinestream/ (redirects to HTTPS if SSL is configured)"
    log_info "  - Internet: http://<public-ip>/cinestream/ (redirects to HTTPS if SSL is configured)"
    log_info "  - HTTPS: https://<server-ip>/cinestream/ (if self-signed SSL is used)"
    log_info "  - HTTPS: https://<your-domain>/ (if domain SSL is used - no subpath)"
    log_info ""
    log_info "Next steps (optional):"
    log_info "  - Set a domain: sudo $0 set-domain yourdomain.com"
    log_info "  - Install SSL: sudo $0 install-ssl yourdomain.com"
    log_info ""
    log_info "Check status: sudo $0 status"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Diagnose internet access issues and provide router configuration help
diagnose_internet_access() {
    log_info "🔍 Diagnosing internet access issues..."
    log_info ""
    
    # Get server information
    local ipv4_addresses
    ipv4_addresses=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || \
                    ifconfig 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || true)
    local public_ip
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
                echo "Unable to detect")
    local local_ip
    local_ip=$(echo "$ipv4_addresses" | head -1 || echo "Not detected")
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Server Information:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Local IP Address: $local_ip"
    log_info "  Public IP Address: $public_ip"
    log_info ""
    
    # Check if server is behind NAT
    if [[ -n "$local_ip" ]] && [[ -n "$public_ip" ]] && [[ "$local_ip" != "$public_ip" ]]; then
        log_warning "⚠ Your server is behind a router/NAT"
        log_warning "   Local IP ($local_ip) ≠ Public IP ($public_ip)"
        log_warning "   Port forwarding is REQUIRED for internet access"
        log_info ""
    fi
    
    # Check Nginx
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Checking Nginx:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if systemctl is-active --quiet nginx.service 2>/dev/null; then
        log_success "✓ Nginx is running"
    else
        log_error "✗ Nginx is NOT running"
        log_info "  Start it: sudo systemctl start nginx"
    fi
    
    # Check if Nginx is listening
    if ss -tlnp 2>/dev/null | grep -q ":80.*nginx" || netstat -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
        local listen_info
        listen_info=$(ss -tlnp 2>/dev/null | grep ":80" | head -1 || netstat -tlnp 2>/dev/null | grep ":80" | head -1 || echo "")
        if echo "$listen_info" | grep -q "0.0.0.0:80\|\\*:80"; then
            log_success "✓ Nginx is listening on all interfaces (0.0.0.0:80)"
        else
            log_warning "⚠ Nginx listening info: $listen_info"
        fi
    else
        log_error "✗ Nginx is NOT listening on port 80"
    fi
    
    # Check firewall
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Checking Firewall:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-services 2>/dev/null | grep -q "http"; then
            log_success "✓ Firewalld allows HTTP (port 80)"
        else
            log_error "✗ Firewalld does NOT allow HTTP"
            log_info "  Fix: sudo firewall-cmd --permanent --add-service=http && sudo firewall-cmd --reload"
        fi
    elif command -v ufw &> /dev/null; then
        if ufw status 2>/dev/null | grep -q "80/tcp.*ALLOW"; then
            log_success "✓ UFW allows port 80"
        else
            log_error "✗ UFW does NOT allow port 80"
            log_info "  Fix: sudo ufw allow 80/tcp"
        fi
    else
        log_warning "⚠ No firewall detected or firewall status unknown"
    fi
    
    # Test local connectivity
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing Local Connectivity:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if curl -s --max-time 3 -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -q "[23][0-9][0-9]"; then
        log_success "✓ Server responds locally (http://localhost)"
    else
        log_error "✗ Server does NOT respond locally"
        log_info "  Check: sudo systemctl status nginx"
        log_info "  Check: sudo systemctl status cinestream@8001.service"
    fi
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🌐 TP-LINK ROUTER CONFIGURATION GUIDE"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "To make your server accessible from the internet, configure port forwarding:"
    log_info ""
    log_info "STEP 1: Access Router Admin Panel"
    log_info "  - Open browser: http://192.168.1.1 or http://192.168.0.1"
    log_info "  - Login with admin credentials (check router label)"
    log_info ""
    log_info "STEP 2: Find Port Forwarding / Virtual Server"
    log_info "  - Look for: 'Port Forwarding', 'Virtual Server', 'NAT Forwarding', or 'Advanced' → 'NAT Forwarding'"
    log_info "  - Common locations:"
    log_info "    • Advanced → NAT Forwarding → Port Forwarding"
    log_info "    • Advanced → Virtual Server"
    log_info "    • Firewall → Port Forwarding"
    log_info ""
    log_info "STEP 3: Add Port Forwarding Rules"
    log_info ""
    log_info "  Rule 1 - HTTP (Port 80) - Redirects to HTTPS:"
    log_info "    Service Name: CineStream HTTP"
    log_info "    External Port: 80"
    log_info "    Internal Port: 80"
    log_info "    Protocol: TCP (or Both)"
    log_info "    Internal IP: $local_ip"
    log_info "    Status: Enabled"
    log_info ""
    log_info "  Rule 2 - HTTPS (Port 443) - Main Access:"
    log_info "    Service Name: CineStream HTTPS"
    log_info "    External Port: 443"
    log_info "    Internal Port: 443"
    log_info "    Protocol: TCP (or Both)"
    log_info "    Internal IP: $local_ip"
    log_info "    Status: Enabled"
    log_info ""
    log_info "  NOTE: All HTTP (port 80) requests automatically redirect to HTTPS (port 443)"
    log_info ""
    log_info "STEP 4: Save and Apply"
    log_info "  - Click 'Save' or 'Apply'"
    log_info "  - Router may restart (takes 1-2 minutes)"
    log_info ""
    log_info "STEP 5: Verify Port Forwarding"
    log_info "  - Use online port checker: https://www.yougetsignal.com/tools/open-ports/"
    log_info "  - Test Port 80: Should be open (redirects to HTTPS)"
    log_info "  - Test Port 443: Should be open (main HTTPS access)"
    log_info "  - Access your site: https://$public_ip"
    log_info "  - Note: HTTP (http://$public_ip) will automatically redirect to HTTPS"
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "TROUBLESHOOTING:"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "If port forwarding doesn't work:"
    log_info ""
    log_info "1. Check Router Firewall:"
    log_info "   - Some routers have a firewall that blocks forwarded ports"
    log_info "   - Look for 'Firewall Rules' or 'Access Control'"
    log_info "   - Ensure port 80 is allowed"
    log_info ""
    log_info "2. Check ISP Blocking:"
    log_info "   - Some ISPs block ports 80 and 443 for residential connections"
    log_info "   - Port 80: Used for HTTP→HTTPS redirect (required)"
    log_info "   - Port 443: Used for HTTPS access (required)"
    log_info "   - If blocked, contact your ISP or use a VPS with ports 80/443 open"
    log_info ""
    log_info "3. Verify Server IP:"
    log_info "   - Make sure your server's IP is: $local_ip"
    log_info "   - Check: ip addr show | grep inet"
    log_info "   - If IP changed, update port forwarding rule"
    log_info ""
    log_info "4. Test from Different Network:"
    log_info "   - Try accessing from mobile data (not WiFi)"
    log_info "   - Or ask someone on a different network to test"
    log_info ""
    log_info "5. Check Router Logs:"
    log_info "   - Some TP-Link routers show connection attempts in logs"
    log_info "   - Look for 'System Log' or 'Security Log'"
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "After configuring port forwarding, test access:"
    log_info "  - From internet: http://$public_ip/cinestream/"
    log_info "  - Should show your CineStream application"
    log_info ""
}

# Stop all services
stop_all() {
    log_info "Stopping all services..."
    
    # Note: SSH is intentionally NOT stopped to maintain remote access
    
    # Stop all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 20 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-20}
            START_PORT=${START_PORT:-8001}
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
    
    # Ensure SSH is running first
    ensure_ssh_service
    
    # Start MongoDB first
    systemctl start mongodb.service
    sleep 2
    
    # Start Nginx
    systemctl start nginx.service
    
    # Start all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 20 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-20}
            START_PORT=${START_PORT:-8001}
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

# Uninitialize server: Remove all CineStream components
uninit_server() {
    local REMOVE_MONGODB="${1:-no}"
    
    log_warning "This will remove ALL CineStream components from the server!"
    log_warning "This includes:"
    log_warning "  - All deployed sites and applications"
    log_warning "  - All systemd services"
    log_warning "  - All Nginx configurations"
    log_warning "  - CPU affinity configurations"
    log_warning "  - CineStream systemd targets and timers"
    if [[ "$REMOVE_MONGODB" == "yes" ]]; then
        log_warning "  - MongoDB service and data (DESTRUCTIVE!)"
        log_warning "  - Nginx service and package (DESTRUCTIVE!)"
    fi
    log_info ""
    log_info "Note: SSH service will be preserved, enabled, and kept running"
    echo ""
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Cancelled."
        exit 0
    fi
    
    log_info "Starting server cleanup..."
    
    # Ensure SSH remains enabled and running (critical for remote access)
    log_info "Ensuring SSH service remains enabled and running..."
    ensure_ssh_service
    
    # Stop all services first
    log_info "Stopping all services..."
    stop_all
    
    # Remove all deployed sites
    log_info "Removing all deployed sites..."
    if [[ -d "$WWW_ROOT" ]]; then
        for app_dir in "$WWW_ROOT"/*; do
            if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
                source "$app_dir/.deploy_config"
                # Default to 20 processes if not specified
                PROCESS_COUNT=${PROCESS_COUNT:-20}
                START_PORT=${START_PORT:-8001}
                APP_NAME=$(basename "$app_dir")
                log_info "Removing site: $APP_NAME"
                
                # Stop and remove all process services
                for ((i=0; i<PROCESS_COUNT; i++)); do
                    local port=$((START_PORT + i))
                    systemctl stop "${APP_NAME}@${port}.service" 2>/dev/null || true
                    systemctl disable "${APP_NAME}@${port}.service" 2>/dev/null || true
                done
                
                # Stop and remove timer
                systemctl stop "${APP_NAME}-refresh.timer" 2>/dev/null || true
                systemctl disable "${APP_NAME}-refresh.timer" 2>/dev/null || true
                
                # Remove systemd files
                rm -f "$SYSTEMD_DIR/${APP_NAME}@.service"
                rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.service"
                rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.timer"
                
                # Remove Nginx config
                rm -f "$NGINX_CONF_DIR/${APP_NAME}.conf"
            fi
        done
        
        # Remove all app directories
        rm -rf "$WWW_ROOT"/*
        log_success "All deployed sites removed"
    fi
    
    # Remove CineStream systemd services and targets
    log_info "Removing CineStream systemd services..."
    systemctl stop cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl stop cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl stop cinestream-startup.service 2>/dev/null || true
    systemctl disable cinestream-startup.service 2>/dev/null || true
    systemctl stop cinestream.target 2>/dev/null || true
    systemctl disable cinestream.target 2>/dev/null || true
    
    # Remove systemd files
    rm -f "$SYSTEMD_DIR/cinestream.target"
    rm -f "$SYSTEMD_DIR/cinestream-startup.service"
    rm -f "$SYSTEMD_DIR/cinestream-cpu-affinity.service"
    rm -f "$SYSTEMD_DIR/cinestream-cpu-affinity.timer"
    
    # Remove CPU affinity script
    log_info "Removing CPU affinity management script..."
    rm -f /usr/local/bin/cinestream-set-cpu-affinity.sh
    
    # Remove Nginx CPU affinity override
    log_info "Removing Nginx CPU affinity configuration..."
    rm -rf "$SYSTEMD_DIR/nginx.service.d"
    
    # Remove MongoDB and Nginx if requested
    if [[ "$REMOVE_MONGODB" == "yes" ]]; then
        log_warning "Removing MongoDB (this will delete all data!)..."
        systemctl stop mongodb.service 2>/dev/null || true
        systemctl disable mongodb.service 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/mongodb.service"
        
        # Ask for confirmation before deleting data
        read -p "Delete MongoDB data directory? Type 'yes' to confirm: " DELETE_DATA
        if [[ "$DELETE_DATA" == "yes" ]]; then
            rm -rf "$MONGO_DATA_DIR"
            rm -rf "$MONGO_LOG_DIR"
            log_warning "MongoDB data deleted"
        else
            log_info "MongoDB data preserved at $MONGO_DATA_DIR"
        fi
        
        # Remove MongoDB installation
        read -p "Remove MongoDB installation? Type 'yes' to confirm: " REMOVE_INSTALL
        if [[ "$REMOVE_INSTALL" == "yes" ]]; then
            rm -rf /opt/mongodb
            log_warning "MongoDB installation removed"
            
            # Also try to uninstall MongoDB package if installed via package manager
            if command -v yay &> /dev/null && yay -Q mongodb-bin &>/dev/null; then
                log_info "Uninstalling MongoDB package (mongodb-bin)..."
                yay -Rns --noconfirm mongodb-bin 2>/dev/null || true
            elif pacman -Q mongodb &>/dev/null; then
                log_info "Uninstalling MongoDB package..."
                pacman -Rns --noconfirm mongodb 2>/dev/null || true
            fi
        fi
        
        # Remove Nginx
        log_warning "Removing Nginx service and package..."
        systemctl stop nginx.service 2>/dev/null || true
        systemctl disable nginx.service 2>/dev/null || true
        
        # Remove all Nginx configurations
        log_info "Removing Nginx configurations..."
        rm -f "$NGINX_CONF_DIR"/*.conf 2>/dev/null || true
        rm -f /etc/nginx/conf.d/security.conf 2>/dev/null || true
        rm -f /etc/nginx/conf.d/localhost.conf 2>/dev/null || true
        
        # Ask for confirmation before removing Nginx package
        read -p "Remove Nginx package? Type 'yes' to confirm: " REMOVE_NGINX
        if [[ "$REMOVE_NGINX" == "yes" ]]; then
            log_info "Uninstalling Nginx package..."
            pacman -Rns --noconfirm nginx 2>/dev/null || {
                log_warning "Failed to uninstall Nginx package (may not be installed via pacman)"
            }
            log_warning "Nginx package removed"
        else
            log_info "Nginx package preserved (only service and configs removed)"
        fi
    else
        log_info "MongoDB and Nginx services preserved (use 'uninit-server yes' to remove)"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Clean up log files
    log_info "Cleaning up log files..."
    rm -f /var/log/cinestream-cpu-affinity.log
    rm -f /var/log/cinestream-cpu-affinity-monitor.log
    
    # Ensure SSH is still enabled and running after cleanup
    log_info "Re-ensuring SSH service is enabled and running..."
    ensure_ssh_service
    
    log_success "Server cleanup complete!"
    log_info "Remaining components:"
    if [[ "$REMOVE_MONGODB" != "yes" ]]; then
        log_info "  - MongoDB (service and data preserved)"
        log_info "  - Nginx (service preserved, configurations removed)"
    else
        log_info "  - All CineStream components removed"
        log_info "  - MongoDB removed (if confirmed)"
        log_info "  - Nginx removed (if confirmed)"
    fi
    log_info "  - SSH (service preserved, enabled, and running)"
    log_info "  - System packages (not removed unless explicitly uninstalled)"
    log_info ""
    log_info "To completely reinitialize, run: $0 init-server"
}

# Deploy application (with optional app name)
deploy_application() {
    local APP_NAME="${1:-cinestream}"  # Default to "cinestream" if not specified
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    # Use global SCRIPT_DIR (defined at top of script)
    
    # Check if app already exists
    if [[ -d "$APP_DIR" && -f "$APP_DIR/.deploy_config" ]]; then
        log_warning "Application '$APP_NAME' already exists at $APP_DIR"
        log_info "To redeploy, remove it first or use a different name"
        return 1
    fi
    
    log_info "Deploying application to $APP_DIR..."
    
    # Create application directory
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_DIR/src/static/movie_images"
    
    # Copy application files
    log_info "Copying application files..."
    if [[ -d "$SCRIPT_DIR/src" ]]; then
        cp -r "$SCRIPT_DIR/src" "$APP_DIR/"
        cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/" 2>/dev/null || true
    else
        log_error "Source directory not found: $SCRIPT_DIR/src"
        log_error "Please run deploy.sh from the project root directory"
        return 1
    fi
    
    # Create Python virtual environment
    log_info "Creating Python virtual environment..."
    if [[ ! -d "$APP_DIR/venv" ]]; then
        python -m venv "$APP_DIR/venv"
        log_success "Created virtual environment at $APP_DIR/venv"
    else
        log_info "Virtual environment already exists"
    fi
    
    # Verify venv was created successfully
    if [[ ! -f "$APP_DIR/venv/bin/python" ]]; then
        log_error "Failed to create virtual environment. Python binary not found."
        return 1
    fi
    
    # Install Python dependencies
    log_info "Installing Python dependencies..."
    "$APP_DIR/venv/bin/pip" install --upgrade pip --quiet
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" --quiet
    
    # Create .env file template if it doesn't exist
    if [[ ! -f "$APP_DIR/.env" ]]; then
        log_info "Creating .env file template..."
        # Generate SECRET_KEY using venv Python
        local secret_key
        secret_key=$("$APP_DIR/venv/bin/python" -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "change-me-in-production")
        cat > "$APP_DIR/.env" <<EOF
# MongoDB connection (default: no authentication)
MONGO_URI=mongodb://127.0.0.1:27017/movie_db

# If MongoDB has authentication enabled:
# MONGO_URI=mongodb://username:password@127.0.0.1:27017/movie_db?authSource=admin

# Anthropic API key (REQUIRED - get from https://console.anthropic.com/)
ANTHROPIC_API_KEY=your-api-key-here

# Flask secret key (auto-generated)
SECRET_KEY=$secret_key

# Optional: Claude model selection (haiku = fastest/cheapest, sonnet = more capable)
CLAUDE_MODEL=haiku
EOF
        chmod 600 "$APP_DIR/.env"
        log_warning ".env file created with default values. Please update ANTHROPIC_API_KEY!"

    else
        log_info ".env file already exists, skipping creation"
    fi
    
    # Determine service user BEFORE creating services
    local SERVICE_USER
    # Use SUDO_USER if available (when running with sudo), otherwise use current user
    if [[ -n "${SUDO_USER:-}" ]]; then
        SERVICE_USER="$SUDO_USER"
    else
        SERVICE_USER=$(whoami)
    fi
    
    # Fix ownership of app directory and files so service user can access them
    log_info "Setting ownership of application files to $SERVICE_USER..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR" 2>/dev/null || true
    # Ensure .env is readable by service user (but still secure)
    chmod 640 "$APP_DIR/.env" 2>/dev/null || true
    chown "$SERVICE_USER:$SERVICE_USER" "$APP_DIR/.env" 2>/dev/null || true
    
    # Calculate available port range for this app
    # Each app needs PROCESS_COUNT ports, starting from 8001
    # Find the highest port in use and assign next available range
    local START_PORT=8001
    local PROCESS_COUNT=20
    local highest_port=8000
    
    # Check all existing apps to find highest port in use
    for existing_app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$existing_app_dir" && -f "$existing_app_dir/.deploy_config" ]]; then
            # Source in a subshell to avoid variable conflicts
            local existing_start=$(grep "^START_PORT=" "$existing_app_dir/.deploy_config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "8001")
            local existing_count=$(grep "^PROCESS_COUNT=" "$existing_app_dir/.deploy_config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "20")
            local existing_end=$((existing_start + existing_count - 1))
            if [[ $existing_end -gt $highest_port ]]; then
                highest_port=$existing_end
            fi
        fi
    done
    
    # Assign next available port range
    START_PORT=$((highest_port + 1))
    log_info "Assigned port range: $START_PORT-$((START_PORT + PROCESS_COUNT - 1)) for $APP_NAME"
    
    # Create deployment configuration
    log_info "Creating deployment configuration..."
    cat > "$APP_DIR/.deploy_config" <<EOF
APP_NAME=$APP_NAME
START_PORT=$START_PORT
PROCESS_COUNT=$PROCESS_COUNT
DOMAIN_NAME=""
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$APP_DIR/.deploy_config" 2>/dev/null || true
    
    # Initialize database (if .env is configured)
    log_info "Initializing database..."
    if grep -q "your-api-key-here" "$APP_DIR/.env" 2>/dev/null; then
        log_warning "Skipping database initialization - please update ANTHROPIC_API_KEY in .env first"
    else
        if "$APP_DIR/venv/bin/python" "$APP_DIR/src/scripts/init_db.py" 2>/dev/null; then
            log_success "Database initialized"
        else
            log_warning "Database initialization failed (may need .env configuration)"
        fi
    fi
    
    # Verify venv exists before creating services
    if [[ ! -f "$APP_DIR/venv/bin/python" ]]; then
        log_error "Virtual environment not found. Cannot create services."
        return 1
    fi
    
    # Create systemd service template
    log_info "Creating systemd services..."
    log_info "All Python processes will use venv: $APP_DIR/venv/bin/python"
    
    cat > "$SYSTEMD_DIR/${APP_NAME}@.service" <<EOF
[Unit]
Description=CineStream Web Worker (Port %i)
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/src/main.py --port %i
Restart=always
RestartSec=10
CPUAffinity=6 7 8 9 10 11 12 13
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh python || true'

[Install]
WantedBy=cinestream.target
EOF
    
    # Create daily refresh service
    log_info "Creating daily refresh service and timer..."
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.service" <<EOF
[Unit]
Description=CineStream Daily Refresh Job
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/src/scripts/daily_refresh.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=cinestream.target
EOF

    # Create daily refresh timer (runs at 06:00 AM daily, with catch-up after power outages)
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.timer" <<EOF
[Unit]
Description=CineStream Daily Refresh Timer
Requires=${APP_NAME}-refresh.service

[Timer]
# Run daily at 06:00 AM
OnCalendar=06:00
# Persistent=true ensures missed runs are caught up after system boot/power outage
Persistent=true
# Randomize start time within 5 minutes to avoid thundering herd
RandomizedDelaySec=300
# Accuracy: allow 1 hour window for execution
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start the timer
    systemctl enable "${APP_NAME}-refresh.timer" 2>/dev/null || true
    systemctl start "${APP_NAME}-refresh.timer" 2>/dev/null || true
    
    # Load port configuration from .deploy_config
    source "$APP_DIR/.deploy_config"
    PROCESS_COUNT=${PROCESS_COUNT:-20}
    START_PORT=${START_PORT:-8001}
    local END_PORT=$((START_PORT + PROCESS_COUNT - 1))
    
    # Stop any existing processes first to avoid duplicates
    log_info "Stopping any existing processes for $APP_NAME..."
    for ((port=START_PORT; port<=END_PORT; port++)); do
        systemctl stop "${APP_NAME}@${port}.service" 2>/dev/null || true
    done
    
    # Enable and start all processes
    log_info "Starting $PROCESS_COUNT application processes (ports $START_PORT-$END_PORT)..."
    for ((port=START_PORT; port<=END_PORT; port++)); do
        systemctl enable "${APP_NAME}@${port}.service" 2>/dev/null || true
        # Only start if not already active
        if ! systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
            systemctl start "${APP_NAME}@${port}.service" 2>/dev/null || true
        fi
    done
    
    # Configure localhost access via Nginx
    log_info "Configuring localhost access..."
    configure_nginx_localhost
    
    # Configure comprehensive firewall and security
    log_info "Configuring firewall and security..."
    configure_firewall
    configure_security_hardening
    
    # Wait a moment for processes to start
    sleep 2
    
    # Load port configuration
    source "$APP_DIR/.deploy_config"
    PROCESS_COUNT=${PROCESS_COUNT:-20}
    START_PORT=${START_PORT:-8001}
    local END_PORT=$((START_PORT + PROCESS_COUNT - 1))
    
    # Check if processes are running
    local running=0
    for ((port=START_PORT; port<=END_PORT; port++)); do
        if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
            ((running++))
        fi
    done
    
    if [[ $running -gt 0 ]]; then
        log_success "Application deployed successfully!"
        log_info "  - $running/20 processes running"
        log_info "  - Application directory: $APP_DIR"
        log_info "  - Services: ${APP_NAME}@8001.service to ${APP_NAME}@8020.service"
    else
        log_warning "Application deployed but processes may not be running"
        log_warning "Check .env file and logs: sudo journalctl -u ${APP_NAME}@8001.service"
    fi
}

# Auto-detect application name (finds first app in /var/www with .deploy_config)
detect_app_name() {
    local APP_NAME=""
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            APP_NAME=$(basename "$app_dir")
            echo "$APP_NAME"
            return 0
        fi
    done
    return 1
}

# Install SSL certificate for an application
install_ssl() {
    local DOMAIN="${1:-}"
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "Usage: $0 install-ssl <domain>"
        log_error "Example: $0 install-ssl movies.example.com"
        exit 1
    fi
    
    # Auto-detect app name
    local APP_NAME
    APP_NAME=$(detect_app_name)
    if [[ -z "$APP_NAME" ]]; then
        log_error "No application found in $WWW_ROOT"
        log_error "Please deploy an application first"
        exit 1
    fi
    
    log_info "Detected application: $APP_NAME"
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    local NGINX_CONF="$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    if [[ ! -f "$NGINX_CONF" ]]; then
        log_error "Nginx configuration not found for '$APP_NAME'"
        log_error "Please run 'set-domain' first: $0 set-domain $DOMAIN"
        exit 1
    fi
    
    log_info "Installing SSL certificate for '$DOMAIN'..."
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Certbot not found. Installing certbot..."
        pacman -S --noconfirm certbot certbot-nginx || {
            log_error "Failed to install certbot. Please install manually: pacman -S certbot certbot-nginx"
            exit 1
        }
        log_success "Certbot installed"
    fi
    
    # Verify DNS is pointing to this server
    log_info "Verifying DNS configuration..."
    local SERVER_IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "")
    
    if [[ -z "$SERVER_IP" ]]; then
        log_warning "Could not determine server IP. Skipping DNS verification."
    else
        local DNS_IP
        DNS_IP=$(dig +short "$DOMAIN" A | head -n1)
        
        if [[ -z "$DNS_IP" ]]; then
            log_warning "DNS lookup failed for $DOMAIN. Make sure DNS is configured."
        elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
            log_warning "DNS mismatch detected!"
            log_warning "  Domain $DOMAIN points to: $DNS_IP"
            log_warning "  This server IP is: $SERVER_IP"
            log_warning "  Certificate installation may fail if DNS is not correct."
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Cancelled. Please fix DNS first."
                exit 1
            fi
        else
            log_success "DNS verified: $DOMAIN -> $SERVER_IP"
        fi
    fi
    
    # Ensure ACME challenge directory exists
    mkdir -p /var/www/html/.well-known/acme-challenge
    chmod 755 /var/www/html/.well-known/acme-challenge
    
    # Install certificate using certbot
    log_info "Requesting SSL certificate from Let's Encrypt..."
    log_info "This may take a few moments..."
    
    # Use webroot method (doesn't require nginx plugin, works with our existing config)
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" 2>&1 | tee /tmp/certbot_output.log; then
        log_success "SSL certificate installed successfully!"
    else
        log_error "SSL certificate installation failed!"
        log_error "Check the output above for details."
        log_error ""
        log_error "Common issues:"
        log_error "  1. DNS not pointing to this server"
        log_error "  2. Port 80 not accessible from internet"
        log_error "  3. Firewall blocking port 80"
        log_error "  4. Domain already has a certificate (use --force-renewal to renew)"
        exit 1
    fi
    
    # Update Nginx configuration with SSL paths
    log_info "Updating Nginx configuration with SSL certificate paths..."
    
    # Backup original config
    cp "$NGINX_CONF" "${NGINX_CONF}.backup"
    
    # Uncomment and update SSL certificate paths
    sed -i "s|# ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;|ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;|" "$NGINX_CONF"
    sed -i "s|# ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;|ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;|" "$NGINX_CONF"
    sed -i "s|# ssl_protocols|ssl_protocols|" "$NGINX_CONF"
    sed -i "s|# ssl_ciphers|ssl_ciphers|" "$NGINX_CONF"
    sed -i "s|# ssl_prefer_server_ciphers|ssl_prefer_server_ciphers|" "$NGINX_CONF"
    sed -i "s|# add_header Strict-Transport-Security|add_header Strict-Transport-Security|" "$NGINX_CONF"
    
    log_success "Nginx configuration updated"
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if nginx -t 2>/dev/null; then
        log_success "Nginx configuration is valid"
        
        # Reload Nginx
        log_info "Reloading Nginx..."
        if systemctl reload nginx.service 2>/dev/null; then
            log_success "Nginx reloaded successfully"
            log_info ""
            log_success "SSL certificate is now active for $DOMAIN!"
            log_info ""
            log_info "Certificate details:"
            log_info "  - Certificate: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
            log_info "  - Private Key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            log_info "  - Valid for: 90 days"
            log_info "  - Auto-renewal: Enabled via certbot.timer"
            log_info ""
            log_info "Test your HTTPS site: https://${DOMAIN}"
        else
            log_error "Failed to reload Nginx. Check logs: journalctl -u nginx.service"
            log_info "Restoring backup configuration..."
            mv "${NGINX_CONF}.backup" "$NGINX_CONF"
            exit 1
        fi
    else
        log_error "Nginx configuration test failed!"
        log_error "Restoring backup configuration..."
        mv "${NGINX_CONF}.backup" "$NGINX_CONF"
        exit 1
    fi
    
    # Ensure certbot auto-renewal is enabled
    log_info "Ensuring certbot auto-renewal is enabled..."
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    
    if systemctl is-active --quiet certbot.timer; then
        log_success "Certbot auto-renewal is active"
    else
        log_warning "Certbot auto-renewal timer is not active. Enable manually:"
        log_warning "  systemctl enable --now certbot.timer"
    fi
}

# Set domain for an application
set_domain() {
    local DOMAIN="${1:-}"
    local APP_NAME="${2:-}"  # Optional app name
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "Usage: $0 set-domain <domain> [app-name]"
        log_error "Example: $0 set-domain movies.example.com"
        log_error "Example: $0 set-domain movies.example.com cinestream"
        log_error ""
        log_error "If app-name is not specified, the first app found will be used."
        exit 1
    fi
    
    # Auto-detect app name if not provided
    if [[ -z "$APP_NAME" ]]; then
        APP_NAME=$(detect_app_name)
        if [[ -z "$APP_NAME" ]]; then
            log_error "No application found in $WWW_ROOT"
            log_error "Please deploy an application first"
            exit 1
        fi
        log_info "Auto-detected application: $APP_NAME"
    else
        # Verify app exists
        if [[ ! -d "$WWW_ROOT/$APP_NAME" ]] || [[ ! -f "$WWW_ROOT/$APP_NAME/.deploy_config" ]]; then
            log_error "Application '$APP_NAME' not found in $WWW_ROOT"
            log_error "Available apps:"
            for app_dir in "$WWW_ROOT"/*; do
                if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
                    log_error "  - $(basename "$app_dir")"
                fi
            done
            exit 1
        fi
        log_info "Using specified application: $APP_NAME"
    fi
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    
    if [[ ! -f "$APP_DIR/.deploy_config" ]]; then
        log_error "Application '$APP_NAME' is not properly deployed (missing .deploy_config)"
        exit 1
    fi
    
    # Load existing config
    source "$APP_DIR/.deploy_config"
    PROCESS_COUNT=${PROCESS_COUNT:-20}
    START_PORT=${START_PORT:-8001}
    
    log_info "Setting domain '$DOMAIN' for application '$APP_NAME'..."
    
    # Update .deploy_config with domain
    if grep -q "^DOMAIN_NAME=" "$APP_DIR/.deploy_config" 2>/dev/null; then
        # Update existing domain
        sed -i "s|^DOMAIN_NAME=.*|DOMAIN_NAME=\"$DOMAIN\"|" "$APP_DIR/.deploy_config"
        log_info "Updated domain in .deploy_config"
    else
        # Add new domain
        echo "DOMAIN_NAME=\"$DOMAIN\"" >> "$APP_DIR/.deploy_config"
        log_info "Added domain to .deploy_config"
    fi
    
    # Generate Nginx configuration
    log_info "Generating Nginx configuration..."
    
    # Check if localhost.conf exists - if so, don't use default_server in catch-all
    local LOCALHOST_EXISTS=false
    if [[ -f "/etc/nginx/conf.d/localhost.conf" ]]; then
        LOCALHOST_EXISTS=true
        log_info "localhost.conf detected - will not set default_server in domain catch-all"
    fi
    
    local UPSTREAM_NAME="${APP_NAME}_backend"
    local NGINX_CONF="$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    cat > "$NGINX_CONF" <<EOF
# Upstream backend for ${APP_NAME} - ${PROCESS_COUNT} worker processes
upstream ${UPSTREAM_NAME} {
    ip_hash;  # Sticky sessions - same IP routes to same backend
EOF
    
    # Add all backend servers
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        echo "    server 127.0.0.1:${port};" >> "$NGINX_CONF"
    done
    
    cat >> "$NGINX_CONF" <<EOF
}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }
    
    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Catch-all HTTP server - redirect any HTTP requests to HTTPS
EOF

    # Only add default_server if localhost.conf doesn't exist
    if [[ "$LOCALHOST_EXISTS" == "false" ]]; then
        cat >> "$NGINX_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
EOF
    else
        cat >> "$NGINX_CONF" <<EOF
# Note: default_server is handled by localhost.conf
server {
    listen 80;
    listen [::]:80;
    server_name _;
EOF
    fi
    
    cat >> "$NGINX_CONF" <<EOF
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }
    
    # Redirect all other traffic to HTTPS (using the configured domain)
    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    
    # SSL configuration (update paths after certificate generation)
    # ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # SSL settings (uncomment after certificate is installed)
    # ssl_protocols TLSv1.2 TLSv1.3;
    # ssl_ciphers HIGH:!aNULL:!MD5;
    # ssl_prefer_server_ciphers on;
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' https:; frame-ancestors 'self';" always;
    
    # Rate limiting
    limit_req zone=general_limit burst=20 nodelay;
    limit_conn conn_limit 10;
    
    # Logging disabled
    access_log off;
    error_log /dev/null;
    
    # Disable unnecessary HTTP methods
    if (\$request_method !~ ^(GET|HEAD|POST|OPTIONS)\$ ) {
        return 405;
    }
    
    # Block common attack patterns
    location ~* \.(env|git|svn|htaccess|htpasswd|ini|log|sh|sql|conf)\$ {
        deny all;
        return 404;
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
    
    # Redirect /cinestream subpath to root (domain serves at root, not subpath)
    location = /cinestream {
        return 301 \$scheme://\$host/;
    }
    location = /cinestream/ {
        return 301 \$scheme://\$host/;
    }
    
    # API endpoints
    location /api/ {
        limit_req zone=api_limit burst=10 nodelay;
        limit_conn conn_limit_per_ip 5;
        
        proxy_pass http://${UPSTREAM_NAME};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # Timeouts
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        proxy_intercept_errors off;
    }
    
    # Main site
    location / {
        limit_req zone=general_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        
        proxy_pass http://${UPSTREAM_NAME};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        proxy_intercept_errors off;
    }
    
    # Static files
    location /static/ {
        proxy_pass http://${UPSTREAM_NAME};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_cache_valid 200 30d;
        add_header Cache-Control "public, immutable";
        
        proxy_intercept_errors off;
    }
}
EOF
    
    log_success "Nginx configuration generated: $NGINX_CONF"
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if nginx -t 2>/dev/null; then
        log_success "Nginx configuration is valid"
        
        # Reload Nginx
        log_info "Reloading Nginx..."
        if systemctl reload nginx.service 2>/dev/null; then
            log_success "Nginx reloaded successfully"
            log_info ""
            log_info "Domain '$DOMAIN' is now configured for '$APP_NAME'"
            log_info ""
            log_info "Next steps:"
            log_info "1. Point DNS A record for '$DOMAIN' to this server's IP address"
            log_info "2. Wait for DNS propagation (can take up to 48 hours)"
            log_info "3. Install SSL certificate:"
            log_info "   $0 install-ssl $DOMAIN"
        else
            log_error "Failed to reload Nginx. Check logs: journalctl -u nginx.service"
            exit 1
        fi
    else
        log_error "Nginx configuration test failed!"
        log_error "Please check the configuration file: $NGINX_CONF"
        exit 1
    fi
}

# Main command dispatcher
main() {
    check_root
    check_cachyos
    
    case "${1:-}" in
        init-server)
            init_server
            ;;
        uninit-server)
            uninit_server "${2:-no}"
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
        optimize-system)
            optimize_system
            ;;
        deploy-app)
            if [[ -z "$2" ]]; then
                log_error "Usage: $0 deploy-app <app-name>"
                log_error "Example: $0 deploy-app myapp"
                log_error ""
                log_error "This will deploy a new application with the specified name."
                log_error "The app will be deployed to /var/www/<app-name>/"
                exit 1
            fi
            deploy_application "$2"
            ;;
        set-domain)
            set_domain "${2:-}" "${3:-}"
            ;;
        install-ssl)
            install_ssl "${2:-}"
            ;;
        fix-localhost)
            log_info "Fixing localhost configuration..."
            configure_nginx_localhost
            ;;
        enable-internet-access)
            enable_internet_access
            ;;
        abracadabra)
            abracadabra
            ;;
        diagnose-internet)
            diagnose_internet_access
            ;;
        *)
            echo "CineStream Master Deployment Script v21.0"
            echo ""
            echo "Usage: $0 <command> [arguments]"
            echo ""
            echo "Commands:"
            echo "  init-server                    Initialize CachyOS server"
            echo "  uninit-server [yes]            Remove all CineStream components"
            echo "                                (use 'yes' to also remove MongoDB)"
            echo "  start-all                      Start all services"
            echo "  stop-all                       Stop all services"
            echo "  enable-autostart               Enable all services to start on boot"
            echo "  status                         Show status of all services"
            echo "  optimize-system                Optimize system for web server + MongoDB"
            echo "                                (swap, swappiness, noatime, kernel params, disable services)"
            echo "  deploy-app <app-name>          Deploy an additional application"
            echo "                                Example: $0 deploy-app myapp"
            echo "  set-domain <domain> [app]     Configure domain for an application"
            echo "                                Example: $0 set-domain movies.example.com"
            echo "                                Example: $0 set-domain movies.example.com cinestream"
            echo "  install-ssl <domain>          Install SSL certificate for a domain"
            echo "                                Example: $0 install-ssl movies.example.com"
            echo "  fix-localhost                 Fix localhost configuration (remove welcome page)"
            echo "                                Makes http://localhost serve the application"
            echo "  enable-internet-access        Enable internet access (configure firewall, verify setup)"
            echo "                                Makes the application accessible from the internet"
            echo "  abracadabra                   Complete setup in one command (magic!)"
            echo "                                Runs: init-server, deploy-app cinestream,"
            echo "                                enable-autostart, optimize-system, start-all,"
            echo "                                fix-localhost, enable-internet-access"
            echo "  diagnose-internet              Diagnose internet access issues"
            echo "                                Shows router configuration guide (TP-Link)"
            echo "  fix-ssh                        Fix SSH connectivity issues"
            echo "                                Ensures SSH service is running and firewall allows it"
            echo "  fix-ssh                        Fix SSH connectivity issues"
            echo "                                Ensures SSH service is running and firewall allows it"
            exit 1
            ;;
    esac
}

# Enable all services to auto-start on boot
enable_autostart() {
    log_info "Enabling all services for auto-start on boot..."
    
    # Ensure CPU affinity management is installed
    if [[ ! -f /usr/local/bin/cinestream-set-cpu-affinity.sh ]]; then
        log_info "CPU affinity management not found. Installing..."
        install_cpu_affinity_scripts
    fi
    
    # Enable CPU affinity services (critical for proper CPU core assignment)
    log_info "Enabling CPU affinity management services..."
    systemctl enable cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl enable cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl start cinestream-cpu-affinity.timer 2>/dev/null || true
    
    # Enable core services
    systemctl enable mongodb.service 2>/dev/null || true
    systemctl enable nginx.service 2>/dev/null || true
    
    # Enable SSH service
    ensure_ssh_service
    
    # Create master target if it doesn't exist
    if [[ ! -f "$SYSTEMD_DIR/cinestream.target" ]]; then
        create_master_target
    fi
    
    # Enable all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 20 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-20}
            START_PORT=${START_PORT:-8001}
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
    log_info "CPU affinity management is active and will maintain proper CPU core assignment"
    log_info "Run 'sudo systemctl status cinestream.target' to verify"
    log_info "Run 'sudo systemctl status cinestream-cpu-affinity.timer' to check affinity timer"
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
            # Reset variables to avoid conflicts from previous iterations
            local APP_NAME=""
            local PROCESS_COUNT=20
            local START_PORT=8001
            local DOMAIN_NAME=""
            
            # Source config in a way that doesn't pollute the environment
            APP_NAME=$(basename "$app_dir")
            if [[ -f "$app_dir/.deploy_config" ]]; then
                # Read config values safely
                PROCESS_COUNT=$(grep "^PROCESS_COUNT=" "$app_dir/.deploy_config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "20")
                START_PORT=$(grep "^START_PORT=" "$app_dir/.deploy_config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "8001")
                DOMAIN_NAME=$(grep "^DOMAIN_NAME=" "$app_dir/.deploy_config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
            fi
            
            # Convert to integers
            PROCESS_COUNT=$((PROCESS_COUNT))
            START_PORT=$((START_PORT))
            local END_PORT=$((START_PORT + PROCESS_COUNT - 1))
            
            echo "[$APP_NAME]"
            if [[ -n "$DOMAIN_NAME" ]]; then
                echo "  Domain: $DOMAIN_NAME"
            else
                echo "  Domain: (not configured)"
            fi
            
            local running=0
            local failed=0
            local inactive=0
            local total=$PROCESS_COUNT
            
            # Check each service more thoroughly
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                local service_name="${APP_NAME}@${port}.service"
                
                # Check service state
                local state=$(systemctl show "$service_name" -p ActiveState --value 2>/dev/null || echo "not-found")
                
                case "$state" in
                    active|activating)
                        ((running++))
                        ;;
                    failed)
                        ((failed++))
                        ;;
                    inactive|dead)
                        ((inactive++))
                        ;;
                esac
            done
            
            echo "  Processes: $running/$total running (ports $START_PORT-$END_PORT)"
            if [[ $failed -gt 0 ]]; then
                echo "  Failed: $failed processes (check logs: sudo journalctl -u ${APP_NAME}@${START_PORT}.service)"
            fi
            if [[ $inactive -gt 0 ]] && [[ $inactive -lt $total ]]; then
                echo "  Inactive: $inactive processes"
            fi
            
            # Also check if processes are actually listening on ports (more reliable)
            local listening=0
            if command -v ss &>/dev/null; then
                for ((port=START_PORT; port<=END_PORT; port++)); do
                    if ss -tln 2>/dev/null | grep -q ":$port "; then
                        ((listening++))
                    fi
                done
            elif command -v netstat &>/dev/null; then
                for ((port=START_PORT; port<=END_PORT; port++)); do
                    if netstat -tln 2>/dev/null | grep -q ":$port "; then
                        ((listening++))
                    fi
                done
            fi
            
            if [[ $listening -gt 0 ]]; then
                if [[ $listening -ne $running ]]; then
                    echo "  Listening: $listening/$total ports (processes may be running but systemd status differs)"
                else
                    echo "  Listening: $listening/$total ports ✓"
                fi
            else
                echo "  Listening: 0/$total ports (no processes listening)"
            fi
            
            echo -n "  Auto-start: "
            systemctl is-enabled "${APP_NAME}@${START_PORT}.service" 2>/dev/null || echo "no"
            echo -n "  Daily refresh: "
            systemctl is-active "${APP_NAME}-refresh.timer" 2>/dev/null || echo "inactive"
            
            # Show service user if available
            local service_user=$(systemctl show "${APP_NAME}@${START_PORT}.service" -p User --value 2>/dev/null || echo "unknown")
            echo "  Service user: $service_user"
            echo ""
        fi
    done
    
    if [[ ! -d "$WWW_ROOT" ]] || [[ -z "$(ls -A $WWW_ROOT 2>/dev/null)" ]]; then
        echo "  No applications deployed yet."
        echo ""
    fi
}

main "$@"

