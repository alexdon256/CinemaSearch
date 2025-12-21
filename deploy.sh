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
    
    # Create CineStream master target for coordinated startup
    create_master_target
    
    # Install CPU affinity management scripts (needed before configuring services)
    install_cpu_affinity_scripts
    
    # Configure Nginx CPU affinity (P-cores)
    configure_nginx_affinity
    
    # Start and enable Nginx
    systemctl daemon-reload
    systemctl enable nginx.service
    systemctl start nginx.service
    
    log_success "Server initialization complete!"
    log_info "MongoDB is running on 127.0.0.1:27017"
    log_info "Nginx is configured and running"
    log_info "All services configured to auto-start on boot"
    log_info "CPU affinity: MongoDB & Nginx -> P-cores (0-5), Python apps -> E-cores (6-13)"
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
ExecStart=/bin/bash -c 'sleep 5 && for conf in /var/www/*/.deploy_config; do [ -f "\$conf" ] && source "\$conf" && for i in \$(seq 0 \$((PROCESS_COUNT-1))); do systemctl start "\${APP_NAME}@\$((START_PORT+i)).service" 2>/dev/null || true; done; done'
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
    
    # Create systemd service file with CPU affinity for P-cores (0-5)
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
ExecStart=$MONGO_DIR/bin/mongod --dbpath=$MONGO_DATA_DIR --logpath=$MONGO_LOG_DIR/mongod.log --logappend --fork
ExecStop=$MONGO_DIR/bin/mongod --shutdown --dbpath=$MONGO_DATA_DIR
PIDFile=$MONGO_DATA_DIR/mongod.lock
Restart=on-failure
RestartSec=10
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
EOF
    
    log_success "Nginx CPU affinity configured"
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
    fi
    echo ""
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Cancelled."
        exit 0
    fi
    
    log_info "Starting server cleanup..."
    
    # Stop all services first
    log_info "Stopping all services..."
    stop_all
    
    # Remove all deployed sites
    log_info "Removing all deployed sites..."
    if [[ -d "$WWW_ROOT" ]]; then
        for app_dir in "$WWW_ROOT"/*; do
            if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
                source "$app_dir/.deploy_config"
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
    
    # Remove MongoDB if requested
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
        fi
    else
        log_info "MongoDB service and data preserved (use 'uninit-server yes' to remove)"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Clean up log files
    log_info "Cleaning up log files..."
    rm -f /var/log/cinestream-cpu-affinity.log
    rm -f /var/log/cinestream-cpu-affinity-monitor.log
    
    log_success "Server cleanup complete!"
    log_info "Remaining components:"
    if [[ "$REMOVE_MONGODB" != "yes" ]]; then
        log_info "  - MongoDB (service and data preserved)"
    fi
    log_info "  - Nginx (service preserved, configurations removed)"
    log_info "  - System packages (not removed)"
    log_info ""
    log_info "To completely reinitialize, run: $0 init-server"
}

# Main command dispatcher
main() {
    check_root
    check_clear_linux
    
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
        *)
            echo "CineStream Master Deployment Script v21.0"
            echo ""
            echo "Usage: $0 <command> [arguments]"
            echo ""
            echo "Commands:"
            echo "  init-server                    Initialize Clear Linux server"
            echo "  uninit-server [yes]            Remove all CineStream components"
            echo "                                (use 'yes' to also remove MongoDB)"
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

