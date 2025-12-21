# CPU Affinity Configuration

This document describes the CPU affinity setup for CineStream on Intel i9-12900HK processors.

## Overview

The system is configured to optimize CPU usage by assigning different workloads to different CPU core types:

- **MongoDB**: Runs on P-cores (Performance cores) - cores 0-5
- **Nginx**: Runs on P-cores (Performance cores) - cores 0-5
- **Python Applications**: Run on E-cores (Efficiency cores) - cores 6-13

## Intel i9-12900HK CPU Architecture

The Intel i9-12900HK features:
- **6 P-cores** (Performance cores): Cores 0-5 (12 threads with hyperthreading)
- **8 E-cores** (Efficiency cores): Cores 6-13 (8 threads, no hyperthreading)
- **Total**: 14 physical cores, 20 logical threads

## Configuration Details

### MongoDB (P-cores)

MongoDB is configured to use P-cores (0-5) for optimal database performance:

- Systemd service: `/etc/systemd/system/mongodb.service`
- CPU Affinity: `CPUAffinity=0 1 2 3 4 5`
- Post-start script ensures all MongoDB processes use P-cores

### Nginx (P-cores)

Nginx is configured to use P-cores (0-5) for high-performance request handling:

- Systemd override: `/etc/systemd/system/nginx.service.d/cpu-affinity.conf`
- CPU Affinity: `CPUAffinity=0 1 2 3 4 5`
- Post-start script ensures all Nginx worker processes use P-cores

### Python Applications (E-cores)

Each Python application worker is configured to use E-cores (6-13):

- Systemd service template: `/etc/systemd/system/{APP_NAME}@.service`
- CPU Affinity: `CPUAffinity=6 7 8 9 10 11 12 13`
- Default: 10 worker processes per application
- Each worker runs on E-cores for efficient parallel processing

## Automatic Affinity Management

### Startup Script

The system includes an automatic CPU affinity management script:

- **Location**: `/usr/local/bin/cinestream-set-cpu-affinity.sh`
- **Purpose**: Sets CPU affinity for all CineStream processes
- **Usage**:
  ```bash
  # Set affinity for all processes
  sudo cinestream-set-cpu-affinity.sh all
  
  # Set affinity for MongoDB only
  sudo cinestream-set-cpu-affinity.sh mongodb
  
  # Set affinity for Nginx only
  sudo cinestream-set-cpu-affinity.sh nginx
  
  # Set affinity for Python apps only
  sudo cinestream-set-cpu-affinity.sh python
  ```

### Systemd Services

Two systemd services ensure CPU affinity is maintained:

1. **cinestream-cpu-affinity.service**
   - Runs once at startup
   - Sets affinity for all processes
   - Runs again after 10 seconds to catch late-starting processes

2. **cinestream-cpu-affinity.timer**
   - Runs every 5 minutes
   - Ensures affinity is maintained if processes restart
   - Starts 2 minutes after boot

### Service Dependencies

The CPU affinity service is integrated into the CineStream startup sequence:

```
cinestream.target
├── mongodb.service (P-cores)
├── nginx.service
├── cinestream-cpu-affinity.service
└── cinestream-startup.service
    └── {APP_NAME}@*.service (E-cores)
```

## Verification

### Check CPU Affinity

To verify CPU affinity is set correctly:

```bash
# Check MongoDB processes
ps -eo pid,cmd,psr | grep mongod

# Check Nginx processes
ps -eo pid,cmd,psr | grep nginx

# Check Python app processes
ps -eo pid,cmd,psr | grep "main.py.*--port"

# Check affinity for a specific process
taskset -p <PID>
```

### Check Systemd Services

```bash
# Check CPU affinity service status
systemctl status cinestream-cpu-affinity.service
systemctl status cinestream-cpu-affinity.timer

# View logs
journalctl -u cinestream-cpu-affinity.service -f
tail -f /var/log/cinestream-cpu-affinity.log
```

## Manual Configuration

If you need to manually set CPU affinity:

```bash
# Set MongoDB to P-cores
sudo taskset -pc 0-5 $(pgrep mongod)

# Set Nginx to P-cores
sudo taskset -pc 0-5 $(pgrep nginx)

# Set Python apps to E-cores
sudo taskset -pc 6-13 $(pgrep -f "main.py.*--port")
```

## Troubleshooting

### Processes Not Using Correct Cores

1. Check if the affinity script is running:
   ```bash
   systemctl status cinestream-cpu-affinity.timer
   ```

2. Manually run the affinity script:
   ```bash
   sudo /usr/local/bin/cinestream-set-cpu-affinity.sh all
   ```

3. Check systemd service CPU affinity settings:
   ```bash
   systemctl show mongodb.service | grep CPUAffinity
   systemctl show nginx.service | grep CPUAffinity
   systemctl show {APP_NAME}@8001.service | grep CPUAffinity
   ```

### Changing Core Assignment

To change which cores are used, edit:

1. `/etc/systemd/system/mongodb.service` - Change `CPUAffinity` line
2. `/etc/systemd/system/nginx.service.d/cpu-affinity.conf` - Change `CPUAffinity` line
3. `/etc/systemd/system/{APP_NAME}@.service` - Change `CPUAffinity` line
4. `/usr/local/bin/cinestream-set-cpu-affinity.sh` - Update `P_CORES` and `E_CORES` variables

Then reload systemd:
```bash
sudo systemctl daemon-reload
sudo systemctl restart mongodb.service
sudo systemctl restart nginx.service
sudo systemctl restart {APP_NAME}@*.service
```

## Performance Benefits

This configuration provides:

1. **Database Performance**: MongoDB benefits from high-performance P-cores
2. **Web Server Performance**: Nginx handles incoming requests efficiently on P-cores
3. **Parallel Processing**: Python workers efficiently use E-cores for concurrent requests
4. **Resource Isolation**: Database, web server, and application workloads don't compete for the same cores
5. **Optimal Utilization**: All CPU cores are utilized according to their strengths

## Notes

- CPU affinity is set both via systemd `CPUAffinity` directive and post-start scripts
- The timer service ensures affinity is maintained even if processes restart
- Clear Linux OS handles CPU topology detection automatically
- Hyperthreading is enabled on P-cores but not on E-cores

