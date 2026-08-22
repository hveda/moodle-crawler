# Moodle Statistics Crawler

A simple tool to collect online user counts and latency metrics from Moodle sites. Designed for straightforward data gathering with optional local visualization.

## 🎯 What This Tool Does

- **Collects online user counts** from Moodle sites (guest access)
- **Measures latency** for URL discovery operations
- **Exports metrics** in Prometheus format for monitoring
- **Supports dual implementations**: Python (development) and Go (production)

## 🚀 Quick Start

### Run Python Version (Recommended for Testing)
```bash
./run-crawler.sh https://your-moodle-site.com --prometheus --interval 60
```

### Run Go Version (Production)
```bash
cd . && go run main.go --url=https://your-moodle-site.com --prometheus=true --interval=60
```

## 📊 Local Monitoring with Grafana

### Start Local Grafana Stack
```bash
make sync-data        # Sync data from remote server
docker-compose up -d  # Start Grafana + metrics collector
```

Access Grafana at http://localhost:3000 (admin/admin)

### Stop Monitoring
```bash
docker-compose down
```

## 🚢 Remote Deployment

### Deploy Python Version (Primary Method)
```bash
REMOTE_HOST=your-server.com ./deploy.sh
```

### Deploy Container Version (Advanced)
```bash
./deploy-docker.sh --remote-host your-server.com
```

Both methods:
- Create `moodle` user with proper permissions
- Set up systemd service for automatic startup
- Configure data persistence in `/opt/moodle-crawler*/data`

## 📁 Output Files

### Metrics Files (Prometheus Format)
- **`data/metrics.prom`** - Online user counts with timestamps
- **`data/latency.prom`** - URL discovery latency measurements

### File Rotation
- Files auto-rotate at 10MB
- Backup format: `metrics.prom.YYYYMMDD.N`

### Example Metrics
```prometheus
# HELP moodle_online_users_total Current count of online users
# TYPE moodle_online_users_total gauge
moodle_online_users_total{site="your-site"} 42 1703123456789

# HELP moodle_find_online_users_latency_milliseconds Latency to discover online users URL
# TYPE moodle_find_online_users_latency_milliseconds gauge
moodle_find_online_users_latency_milliseconds{site="your-site"} 234 1703123456789
```

## 🛠 Available Commands

### Make Commands
```bash
make help              # Show all available commands
make setup             # Setup Python virtual environment
make test              # Run all tests (Go + Python)
make build             # Build Go binary
make clean             # Clean build artifacts
make run-python        # Run Python crawler locally
make run-go            # Run Go crawler locally
make deploy            # Deploy Python version to remote server
make docker-deploy     # Deploy container to remote server
make sync-data         # Sync data from remote server
make docker-build      # Build container locally
make container-info    # Show container runtime info
```

### Direct Usage
```bash
# Python version (via wrapper script)
./run-crawler.sh <URL> [options]

# Python version (direct)
python3 moodle-crawler.py <URL> [options]

# Go version
go run main.go --url=<URL> [options]

# Options for both versions:
#   --interval SECONDS    Crawl interval (default: 60)
#   --output-dir DIR      Output directory (default: data/)
#   --prometheus         Generate Prometheus metrics
#   --duration MINUTES   Run duration (default: indefinite)
```

## 🔧 Configuration

### Environment Variables (.env.production)
```bash
# Remote deployment
REMOTE_HOST=your-server.com
REMOTE_USER=root
SSH_KEY_PATH=~/.ssh/id_rsa

# Application settings
MOODLE_URL=https://your-moodle-site.com
LOG_LEVEL=INFO
INTERVAL=60

# Container registry (for docker deployment)
REGISTRY_URL=registry.digitalocean.com/your-org/moodle-crawler
IMAGE=registry.digitalocean.com/your-org/moodle-crawler:latest

# Data directories (on remote server)
PYTHON_DATA_DIR=/opt/moodle-crawler/data
DOCKER_DATA_DIR=/opt/moodle-crawler-docker/data

# Grafana (for local monitoring)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=your-secure-password
```

## 🏗 Project Structure

```
moodle-statistic/
├── moodle-crawler.py          # Main Python implementation
├── main.go                    # Main Go implementation
├── requirements.txt           # Python dependencies
├── run-crawler.sh            # Python runner script
├── deploy.sh                 # Remote deployment (Python)
├── deploy-docker.sh          # Remote deployment (Container)
├── Dockerfile                # Container definition
├── docker-compose.yml        # Local Grafana stack
├── Makefile                  # Build automation
├── README.md                 # This file
├── CLAUDE.md                 # Development instructions
├── data/                     # Output directory
├── venv/                     # Python virtual environment
└── grafana/                  # Local Grafana configuration
    ├── dashboards/           # Dashboard definitions
    └── provisioning/         # Auto-configuration
```

## 🔍 Troubleshooting

### Python Issues
```bash
# Check virtual environment
ls -la venv/

# Recreate environment
rm -rf venv/
make setup

# Test Python installation
python3 --version
python3 -m pip --version
```

### Go Issues
```bash
# Check Go installation
go version

# Build manually
go build -o build/moodle-crawler main.go

# Test with verbose output
go run main.go --url=https://example.com --interval=10
```

### Remote Deployment Issues
```bash
# Test SSH connection
ssh user@your-server.com "echo connected"

# Check remote service
ssh user@your-server.com "systemctl status moodle-crawler"

# View remote logs
ssh user@your-server.com "journalctl -u moodle-crawler -f"
```

### Local Grafana Issues
```bash
# Check containers
docker-compose ps

# View logs
docker-compose logs grafana

# Reset Grafana data
docker-compose down -v
docker-compose up -d
```

## 📋 Requirements

### Local Development
- Python 3.14+ with pip and venv
- Go 1.19+ (for Go version)
- Docker/Podman (for local Grafana)

### Remote Deployment
- Ubuntu/Debian server with SSH access
- Passwordless SSH key authentication
- User with sudo privileges

### Data Sync
- rsync installed locally
- SSH access to remote server with data

## 🤝 Support

This tool is designed for simplicity. For issues:
1. Check the troubleshooting section above
2. Verify your Moodle site allows guest access
3. Ensure proper network connectivity
4. Check file permissions in data directory

---

**Simple data collection for Moodle online user statistics** 📊