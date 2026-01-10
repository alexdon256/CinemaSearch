# System Architecture Documentation

This document provides a comprehensive overview of the CineStream system architecture, including design decisions, data flow, and component interactions.

## Table of Contents

1. [High-Level Architecture](#high-level-architecture)
2. [CPU Affinity Configuration](#cpu-affinity-configuration)
3. [Shared-Nothing Parallel Model](#shared-nothing-parallel-model)
4. [Multi-Site Multi-Tenancy](#multi-site-multi-tenancy)
5. [AI Agent Layer](#ai-agent-layer)
6. [Data Flow](#data-flow)
7. [Concurrency Control](#concurrency-control)
8. [Database Schema](#database-schema)
9. [Deployment Architecture](#deployment-architecture)

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ HTTPS (443)
                         │
         ┌───────────────▼────────────────┐
         │         Nginx                  │
         │    (Reverse Proxy + SSL)       │
         │    Sticky Sessions (ip_hash)   │
         │      P-cores (0-5)             │
         └───────────────┬────────────────┘
                         │
         ┌───────────────┴────────────────┐
         │                                 │
    ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
    │Worker 1 │  │Worker 2 │  │Worker 3 │  ...  │Worker 12│
    │:8001    │  │:8002    │  │:8003    │       │:8012    │
    │E-cores  │  │E-cores  │  │E-cores  │       │E-cores  │
    └────┬────┘  └────┬────┘  └────┬────┘       └────┬────┘
         │            │            │                  │
         └────────────┴────────────┴──────────────────┘
                         │
         ┌───────────────▼────────────────┐
         │      MongoDB Database          │
         │  (locations, movies, stats)    │
         │      P-cores (0-5)             │
         └────────────────────────────────┘
                         │
         ┌───────────────▼────────────────┐
         │    Google Gemini API           │
         │    (On-Demand Scraping)        │
         └────────────────────────────────┘
```

## CPU Affinity Configuration

### Overview

The system is optimized for Intel i9-12900HK processors with hybrid architecture (P-cores and E-cores). CPU affinity is configured to maximize performance by assigning workloads to appropriate core types.

### CPU Architecture (Intel i9-12900HK)

- **6 P-cores** (Performance cores): Cores 0-5 (12 threads with hyperthreading)
- **8 E-cores** (Efficiency cores): Cores 6-13 (8 threads, no hyperthreading)
- **Total**: 14 physical cores, 20 logical threads

### Affinity Assignment

```
┌─────────────────────────────────────────────────┐
│  CPU Core Assignment                             │
├─────────────────────────────────────────────────┤
│  P-Cores (0-5):   MongoDB Database               │
│                   - High-performance I/O         │
│                   - Database queries             │
│                   - Data persistence              │
│                   Nginx Web Server               │
│                   - Request routing              │
│                   - SSL/TLS processing           │
│                   - Reverse proxy                │
├─────────────────────────────────────────────────┤
│  E-Cores (6-13):  Python Application Workers     │
│                   - 12 worker processes           │
│                   - HTTP request handling        │
│                   - AI agent spawning            │
│                   - Parallel processing          │
└─────────────────────────────────────────────────┘
```

### Implementation

#### MongoDB (P-cores)

MongoDB is configured to use P-cores for optimal database performance:

```ini
[Service]
CPUAffinity=0 1 2 3 4 5
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'
```

#### Nginx (P-cores)

Nginx is configured to use P-cores for high-performance request handling:

```ini
[Service]
CPUAffinity=0 1 2 3 4 5
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh nginx || true'
```

Configured via systemd override: `/etc/systemd/system/nginx.service.d/cpu-affinity.conf`

#### Python Workers (E-cores)

Each Python worker process is configured to use E-cores:

```ini
[Service]
CPUAffinity=6 7 8 9 10 11 12 13
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh python || true'
```

### Automatic Affinity Management

The system includes automatic CPU affinity management:

1. **Startup Service** (`cinestream-cpu-affinity.service`):
   - Runs at system startup
   - Sets affinity for all processes
   - Re-runs after 10 seconds to catch late-starting processes

2. **Timer Service** (`cinestream-cpu-affinity.timer`):
   - Runs every 5 minutes
   - Ensures affinity is maintained if processes restart
   - Starts 2 minutes after boot

3. **Management Script** (`/usr/local/bin/cinestream-set-cpu-affinity.sh`):
   - Can be run manually to set affinity
   - Supports: `all`, `mongodb`, `python` modes

### Benefits

- **Database Performance**: MongoDB benefits from high-performance P-cores
- **Web Server Performance**: Nginx handles incoming requests efficiently on P-cores
- **Parallel Processing**: Python workers efficiently use E-cores for concurrent requests
- **Resource Isolation**: Database, web server, and application workloads don't compete for the same cores
- **Optimal Utilization**: All CPU cores are utilized according to their strengths
- **Automatic Maintenance**: Timer service ensures affinity is maintained across restarts

### Process Count

- **Default**: 12 Python worker processes per application
- **Rationale**: 8 E-cores can efficiently handle 12 processes (processes share cores efficiently)
- **Configurable**: Process count can be configured during deployment

For detailed CPU affinity configuration and troubleshooting, see [CPU_AFFINITY.md](CPU_AFFINITY.md).

## Shared-Nothing Parallel Model

### Design Rationale

The system uses a **shared-nothing architecture** to maximize CPU utilization and bypass Python's Global Interpreter Lock (GIL).

### Key Characteristics

- **12 Independent Processes**: Each application runs as 12 separate OS processes (default)
- **Unique Port Binding**: Each process binds to a unique port (e.g., 8001-8012)
- **No Shared Memory**: Processes communicate only via MongoDB
- **Stateless Workers**: Each process is independent and can be restarted individually
- **CPU Affinity**: All workers run on E-cores (6-13) for efficient parallel processing

### Process Lifecycle

```
Process Startup:
1. Load .env file
2. Connect to MongoDB
3. Bind to assigned port
4. Start Flask application
5. Listen for requests

Request Handling:
1. Receive request from Nginx
2. Process request (with caching)
3. Query/update MongoDB if needed
4. Return response to Nginx

Process Shutdown:
1. Gracefully close connections
2. Clean up resources
3. Exit
```

### Benefits

- **High Concurrency**: 12 processes can handle 12x more concurrent requests
- **Fault Isolation**: One crashed process doesn't affect others
- **Horizontal Scaling**: Easy to add more processes
- **GIL Bypass**: Each process has its own Python interpreter
- **CPU Optimization**: Workers use E-cores, leaving P-cores for database operations

## Multi-Site Multi-Tenancy

### Deployment

Multiple applications can be deployed on the same server:

```bash
# Deploy first app (automatic during init-server)
sudo ./deploy.sh init-server  # Creates cinestream app

# Deploy additional apps
sudo ./deploy.sh deploy-app blogapp
sudo ./deploy.sh deploy-app shopapp
```

### Isolation Strategy

Each application is completely isolated:

```
/var/www/
├── cinestream/           (First app - ports 8001-8012)
│   ├── .env              (Isolated secrets)
│   ├── .deploy_config    (Port range, domain, etc.)
│   ├── venv/             (Isolated Python environment)
│   ├── src/              (Isolated source code)
│   └── static/           (Isolated static files)
│
├── blogapp/              (Second app - ports 8021-8040)
│   ├── .env
│   ├── .deploy_config
│   ├── venv/
│   └── src/
│
└── shopapp/              (Third app - ports 8041-8060)
    ├── .env
    ├── .deploy_config
    ├── venv/
    └── src/
```

### Automatic Port Assignment

- **First app**: Ports 8001-8012 (12 processes)
- **Second app**: Ports 8013-8024 (12 processes)
- **Third app**: Ports 8025-8036 (12 processes)
- Ports are automatically assigned to avoid conflicts

### Nginx Routing

Nginx routes traffic based on `server_name`. Each app gets its own config file:

```nginx
# /etc/nginx/conf.d/cinestream.conf
server {
    server_name movies.example.com;
    # Routes to movie_app backend
}

server {
    server_name blog.example.com;
    # Routes to blog_app backend
}
```

### Resource Management

- **Port Ranges**: Each app uses non-overlapping port ranges
- **Database**: Each app can use separate database or collections
- **Systemd Services**: Each app has its own service files

## AI Agent Layer

### Distributed Agent Model

Every worker process can spawn its own AI agent:

```
Request → Worker Process → GeminiAgent → Gemini API → Response
```

### Agent Characteristics

- **Ephemeral**: Created per-request, destroyed after completion
- **Stateless**: No history or context retention
- **Independent**: Each agent operates in isolation
- **Parallel**: Multiple agents can run simultaneously

### Scraping Workflow (Step-by-Step Approach)

```
1. User requests showtimes for "Kyiv"
2. Worker checks MongoDB for fresh data
3. If stale/missing:
   a. Determine date range to scrape (incremental scraping)
   b. Acquire lock (atomic MongoDB operation)
   c. Spawn GeminiAgent with date range
   d. Step 1: Agent finds all theaters with websites in the city
   e. Step 2: Agent finds all movies currently playing in those theaters
   f. Step 3: For each movie, scrape showtimes day-by-day across all theaters
      - One query per movie per day
      - Continues until 2 weeks ahead or no movies found
      - Tracks last showtime date to maintain 2-week coverage
   g. Merge all results by movie title
   h. Store results in MongoDB (movie-centric structure)
   i. Release lock
4. Return showtimes to user (flattened for frontend compatibility)
```

**Query Structure**: `movies × days` queries (e.g., 15 movies × 14 days = 210 queries)
- More efficient than theater-by-theater approach
- Better data quality and coverage
- Automatic extension if movies have showtimes beyond initial range

### Incremental Scraping

The system intelligently determines what date range to scrape:
- **If 2 weeks of data exists**: Only scrapes the missing day (day 14)
- **If data is missing**: Scrapes from latest date to 2 weeks ahead
- **If no data**: Scrapes full 2-week range

This optimization significantly reduces API token usage while maintaining complete data coverage.

### Agent Prompt Structure

The agent uses a step-by-step approach with separate prompts:

**Step 1: Find Theaters**
```
Task: Find all cinema/theater websites in [location]
Return: JSON array with name, address, website
```

**Step 2: Find Movies**
```
Task: Find all movies currently playing in cinemas in [location]
Theaters: [list of theaters]
Return: JSON array with movie_title, movie_description, movie_image_url
```

**Step 3: Scrape Movie Day**
```
Task: Find showtimes for "[movie]" on [date] in [location]
Theaters to check: [list of theaters]
Return: JSON with theaters array, each containing showtimes for that day
```

This decomposition allows:
- More focused queries (better accuracy)
- Lower token usage per query
- Better error handling (can retry individual steps)
- Automatic date extension tracking

## Data Flow

### User Request Flow

```
1. User visits https://movies.example.com
   ↓
2. Nginx receives HTTPS request
   ↓
3. Nginx uses ip_hash to select backend (e.g., Worker 5 :8005)
   ↓
4. Worker 5 processes request:
   - Checks session for language preference
   - Queries MongoDB for locations
   - Returns HTML with showtimes
   ↓
5. User clicks "Kyiv" city
   ↓
6. JavaScript sends AJAX request to /api/scrape
   ↓
7. Worker 5 (same worker due to sticky session):
   - Checks MongoDB lock status
   - If not locked, acquires lock
   - Spawns GeminiAgent
   - Agent executes step-by-step scraping:
     * Finds theaters
     * Finds movies
     * Scrapes each movie day-by-day
   - Stores results in MongoDB
   - Releases lock
   ↓
8. Returns success response
   ↓
9. Frontend fetches showtimes from /api/showtimes
   ↓
10. Displays showtimes to user
```

### On-Demand Scraping Flow

```
1. User requests showtimes for a city
   ↓
2. Worker checks MongoDB for data freshness
   ↓
3. If data is stale or missing:
   a. Determine date range to scrape (incremental)
   b. Acquire lock (prevents duplicate scraping)
   c. Spawn GeminiAgent with date range
   d. Agent executes step-by-step scraping:
      - Finds theaters
      - Finds movies
      - Scrapes each movie day-by-day
   e. Merge new data with existing movies/theaters
   f. Update MongoDB
   g. Release lock
   ↓
4. Return showtimes to user
```

**Incremental Scraping Benefits**:
- If city has 2 weeks of data: Only scrapes missing days (saves API tokens)
- If city missing data: Scrapes from latest date to 2 weeks ahead
- Prevents duplicate scraping of existing data
- Automatic date extension: If last showtime is 5 days out, next search extends to maintain 2-week coverage

## Concurrency Control

### Locking Mechanism

Uses MongoDB atomic operations to prevent duplicate scraping:

```python
# Atomic lock acquisition
db.locations.update_one(
    {
        'city_name': 'Kyiv',
        'status': {'$ne': 'processing'}
    },
    {
        '$set': {'status': 'processing'}
    }
)
```

### Lock States

- **`fresh`**: Data is current, no scraping needed
- **`processing`**: Scraping in progress, other requests wait
- **`stale`**: Data is old, needs refresh

### Lock Timeout

Locks automatically expire after 5 minutes to prevent deadlocks:

```python
LOCK_TIMEOUT = 300  # 5 minutes
```

### Request Queuing

If a city is being scraped:

1. First request: Acquires lock, starts scraping
2. Concurrent requests: Receive `202 Accepted` status
3. Frontend polls: Checks status every 5 seconds
4. When complete: Lock released, data available

## Database Schema

### Collections Overview

#### `locations` Collection

```javascript
{
  _id: ObjectId("..."),
  city_name: {
    en: "Kyiv",
    ua: "Київ",
    ru: "Киев"
  },
  geo: {
    type: "Point",
    coordinates: [30.5234, 50.4501]  // [longitude, latitude]
  },
  status: "fresh" | "processing" | "stale",
  last_updated: ISODate("2025-12-19T10:00:00Z")
}
```

**Indexes**:
- `geo` (2dsphere) - For distance queries
- `status` - For filtering by status
- `city_name` (unique) - For lookups

#### `movies` Collection

```javascript
{
  _id: ObjectId("..."),
  city_id: "Kyiv, Ukraine",
  city: "Kyiv",
  state: "",
  country: "Ukraine",
  movie: {
    en: "Avatar 2",
    local: "Аватар 2",
    ua: "Аватар 2"
  },
  movie_image_url: "https://example.com/poster.jpg",
  movie_image_path: "/static/movie_images/abc123.jpg",
  theaters: [
    {
      name: "Multiplex",
      address: "123 Main Street, Kyiv",
      website: "https://multiplex.ua",
      showtimes: [
        {
          start_time: ISODate("2025-12-20T18:00:00Z"),
          format: "3D",
          language: "Ukrainian dubbing",
          hall: "Hall 5"
        },
        {
          start_time: ISODate("2025-12-20T21:00:00Z"),
          format: "2D",
          language: "Original",
          hall: "Hall 3"
        }
      ]
    },
    {
      name: "Planeta Kino",
      address: "456 Cinema Avenue, Kyiv",
      website: "https://planetakino.ua",
      showtimes: [
        {
          start_time: ISODate("2025-12-20T19:30:00Z"),
          format: "IMAX",
          language: "Ukrainian subtitles"
        }
      ]
    }
  ],
  created_at: ISODate("2025-12-19T10:00:00Z"),
  updated_at: ISODate("2025-12-19T10:00:00Z")
}
```

**Indexes**:
- `city_id` - For city-based queries
- `movie.en` - For movie title lookups
- `movie.local` - For local language lookups
- `{city_id: 1, movie.en: 1}` - Compound index for upserts
- `created_at` (TTL: 90 days) - Auto-delete old data

**Benefits of Movie-Centric Structure**:
- Movie images stored once per movie (not per showtime)
- Reduces API token usage in responses
- More efficient data structure
- Easier to merge new data with existing movies

#### `stats` Collection

```javascript
{
  _id: "visitor_counter",
  count: 12345,
  created_at: ISODate("2025-12-19T10:00:00Z")
}
```

## Deployment Architecture

### Systemd Services

Each process runs as a systemd service with CPU affinity configured:

**Python Worker Service:**
```ini
[Unit]
Description=Movie App Web Worker (Port 8001)
After=network.target mongodb.service

[Service]
Type=simple
# CPU Affinity: E-cores (6-13) for Intel i9-12900HK
CPUAffinity=6 7 8 9 10 11 12 13
ExecStart=/var/www/movie_app/venv/bin/python /var/www/movie_app/src/main.py --port 8001
Restart=always
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh python || true'
```

**MongoDB Service:**
```ini
[Unit]
Description=MongoDB Database Server
After=network.target

[Service]
Type=forking
# CPU Affinity: P-cores (0-5) for Intel i9-12900HK
CPUAffinity=0 1 2 3 4 5
ExecStart=/opt/mongodb/bin/mongod --dbpath=/opt/mongodb/data --logpath=/opt/mongodb/logs/mongod.log --logappend --fork
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'
Restart=on-failure
```

**CPU Affinity Management:**
```ini
[Unit]
Description=CineStream CPU Affinity Manager
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cinestream-set-cpu-affinity.sh all
ExecStartPost=/bin/bash -c 'sleep 10 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'
```

### Nginx Configuration

```nginx
upstream movie_app_backend {
    ip_hash;  # Sticky sessions
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
    # ... up to 8012 (12 workers, E-cores 6-13)
}

server {
    listen 443 ssl;
    server_name movies.example.com;
    
    location / {
        proxy_pass http://movie_app_backend;
    }
}
```

### SSL/TLS

- **Certificate**: Let's Encrypt (auto-renewed)
- **Protocols**: TLS 1.2, TLS 1.3
- **Ciphers**: High-security ciphers only
- **HSTS**: Enabled with 1-year max-age

## Performance Characteristics

### Scalability

- **Vertical**: Add more processes per app (configure during deployment)
- **Horizontal**: Deploy multiple apps (configure during deployment)
- **Database**: MongoDB sharding (future enhancement)

### Caching Strategy

- **In-Memory**: Each worker caches frequently accessed data
- **Sticky Sessions**: Same user → same worker (cache hit)
- **TTL**: Movies expire after 90 days
- **Incremental Scraping**: Only scrapes missing date ranges, reducing API calls

### Resource Usage

- **Memory**: ~50-100 MB per worker process
- **CPU**: 
  - **MongoDB**: Uses P-cores (0-5) for high-performance database operations
  - **Nginx**: Uses P-cores (0-5) for efficient request routing and SSL processing
  - **Python Workers**: Use E-cores (6-13) for efficient parallel request handling
  - Minimal when idle, spikes during AI scraping
- **Network**: Moderate (API calls to Gemini)
- **CPU Affinity**: Automatically maintained via systemd services and timer

## Security Considerations

### Isolation

- **Process Isolation**: Each worker runs in separate process
- **File Permissions**: `.env` files are 600 (owner read/write only)
- **Network**: Workers listen on localhost only

### Authentication

- **MongoDB**: Supports authentication (configured via MONGO_URI)
- **API Keys**: Stored in `.env`, never committed to git
- **Sessions**: Signed with SECRET_KEY

### SSL/TLS

- **End-to-End Encryption**: HTTPS for all external traffic
- **Certificate Management**: Automatic renewal via certbot
- **Security Headers**: HSTS, X-Frame-Options, etc.

## Monitoring and Observability

### Logs

- **Application**: `journalctl -u movie_app@*.service`
- **Nginx**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- **MongoDB**: `/opt/mongodb/logs/mongod.log`

### Metrics

Key metrics to monitor:

- **Request Rate**: Requests per second per worker
- **Response Time**: P50, P95, P99 latencies
- **Error Rate**: 5xx errors per minute
- **Lock Contention**: How often locks are acquired
- **AI API Usage**: Gemini API calls per hour

## Future Enhancements

### Potential Improvements

1. **Redis Caching**: Add Redis for shared cache
2. **Load Balancing**: Replace ip_hash with more sophisticated LB
3. **Database Sharding**: Shard MongoDB for scale
4. **CDN Integration**: Serve static assets via CDN
5. **Monitoring**: Add Prometheus/Grafana
6. **Auto-Scaling**: Dynamic process scaling based on load

## Conclusion

The CineStream architecture is designed for:

- **High Concurrency**: 12 processes handle thousands of requests
- **CPU Optimization**: P-cores for database, E-cores for application workers
- **Reliability**: Process isolation prevents cascading failures
- **Scalability**: Easy to add more apps or processes
- **Maintainability**: Clear separation of concerns
- **Automatic Management**: CPU affinity maintained automatically on startup and across restarts

For deployment instructions, see:
- [SETUP.md](SETUP.md) - Server initialization
- [SITES.md](SITES.md) - Site management
- [DOMAINS.md](DOMAINS.md) - Domain configuration
- [CPU_AFFINITY.md](CPU_AFFINITY.md) - CPU affinity configuration and troubleshooting

