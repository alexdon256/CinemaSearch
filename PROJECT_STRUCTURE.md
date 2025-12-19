# Project Structure Overview

This document provides a complete overview of the CineStream project structure.

## Root Directory

```
Cinemasearch/
├── deploy.sh                    # Master deployment script (Clear Linux)
├── README.md                    # Main project documentation
├── PROJECT_STRUCTURE.md         # This file
├── .gitignore                   # Git ignore rules
├── requirements.txt             # Python dependencies
│
├── src/                         # Application source code (deployable)
│   ├── main.py                 # Flask web application
│   ├── core/                   # Core modules
│   │   ├── __init__.py
│   │   ├── agent.py           # Claude AI agent wrapper
│   │   └── lock.py            # Concurrency locking mechanism
│   ├── scripts/                # Utility scripts
│   │   ├── __init__.py
│   │   ├── init_db.py         # Database schema initialization
│   │   └── daily_refresh.py   # Daily background job
│   └── templates/              # HTML templates
│       └── index.html         # Main frontend template
│
└── docs/                       # Documentation suite
    ├── SETUP.md               # Server initialization guide
    ├── SITES.md               # Site management guide
    ├── DOMAINS.md             # Domain configuration guide
    └── ARCHITECTURE.md        # System architecture documentation
```

## Deployment Structure (on Clear Linux Server)

After running `deploy.sh add-site`, the following structure is created:

```
/var/www/
└── <app_name>/                 # Application root
    ├── .env                    # Environment variables (secrets)
    ├── .deploy_config          # Deployment metadata
    ├── venv/                   # Python virtual environment
    ├── src/                    # Cloned source code
    │   ├── main.py
    │   ├── core/
    │   ├── scripts/
    │   └── templates/
    └── static/                 # Static assets (if any)

/etc/nginx/conf.d/
└── <app_name>.conf            # Nginx configuration

/etc/systemd/system/
├── <app_name>@.service        # Service template (for ports 8001-8024)
├── <app_name>-refresh.service # Daily refresh service
└── <app_name>-refresh.timer  # Daily refresh timer

/opt/mongodb/                  # MongoDB installation
├── bin/
├── data/                      # Database files
└── logs/                      # MongoDB logs
```

## Key Files Explained

### deploy.sh
Master deployment script that handles:
- Server initialization (`init-server`)
- Site deployment (`add-site`)
- Site modification (`edit-site`)
- Site removal (`remove-site`)
- Global service control (`start-all`, `stop-all`)

### app_skeleton/src/main.py
Flask web application that:
- Serves the frontend interface
- Handles API requests for showtimes
- Manages on-demand scraping via AI agents
- Implements visitor counter
- Supports trilingual localization (UA/EN/RU)

### app_skeleton/src/core/agent.py
Claude AI agent wrapper that:
- Communicates with Anthropic API
- Scrapes cinema websites
- Extracts showtime data
- Validates purchase links

### app_skeleton/src/core/lock.py
Concurrency control mechanism that:
- Prevents duplicate scraping requests
- Uses MongoDB atomic operations
- Implements lock timeout (5 minutes)
- Manages lock states (fresh/processing/stale)

### app_skeleton/src/scripts/init_db.py
Database initialization script that:
- Creates MongoDB collections
- Sets up indexes (including TTL)
- Initializes visitor counter
- Can be run multiple times safely

### app_skeleton/src/scripts/daily_refresh.py
Daily background job that:
- Runs at 06:00 AM via systemd timer
- Refreshes data for all cities
- Uses AI agents to scrape fresh showtimes
- Updates MongoDB with new data

## Environment Variables

Each deployed application requires a `.env` file with:

```bash
MONGO_URI=mongodb://user:pass@127.0.0.1:27017/movie_db?authSource=admin
ANTHROPIC_API_KEY=sk-ant-api03-...
SECRET_KEY=your-secret-key-here
```

## Database Collections

### locations
Stores city information and scraping status.

### showtimes
Stores movie showtimes with automatic expiration (90 days TTL).

### stats
Stores visitor counter and other statistics.

## Process Architecture

Each application runs as **24 independent processes**:
- Ports: 8001, 8002, 8003, ..., 8024
- Each process is a separate systemd service
- Nginx uses sticky sessions (ip_hash) for routing
- Processes communicate only via MongoDB

## Documentation Files

- **SETUP.md**: Complete server initialization guide
- **SITES.md**: How to add, edit, and remove sites
- **DOMAINS.md**: DNS configuration and SSL setup
- **ARCHITECTURE.md**: System design and data flow

## Next Steps

1. Review [README.md](README.md) for quick start
2. Follow [docs/SETUP.md](docs/SETUP.md) to initialize server
3. Configure domain per [docs/DOMAINS.md](docs/DOMAINS.md)
4. Deploy first site using [docs/SITES.md](docs/SITES.md)
5. Understand system via [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

