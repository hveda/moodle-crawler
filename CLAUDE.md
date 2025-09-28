# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Moodle online user statistics crawler with dual language implementations:
- **Python version** (`moodle-crawler.py`) - Original implementation with virtual environment
- **Go version** (`main.go`) - Performance-optimized rewrite with health monitoring

The crawler accesses Moodle sites as a guest to extract online user counts and exports metrics in Prometheus format for monitoring and visualization.

## Common Development Commands

### Running the Crawler
```bash
# Python version (recommended for development)
./run-crawler.sh <MOODLE_URL> -p -i 60

# Go version (for testing/production)
cd src/go && go run main.go --url=<MOODLE_URL> --prometheus=true --interval=60

# Using Makefile
make run-python  # Python with verification
make run-go      # Go version
```

### Testing
```bash
# All tests
make test

# Go tests only
make test-go

# Python tests only
make test-python

# Setup verification
./scripts/deployment/verify_setup.sh
```

### Building and Deployment
```bash
# Build Go binary
make build

# Clean build artifacts
make clean

# REMOTE DEPLOYMENT: Deploy Python version to remote server via SSH
make deploy
# Equivalent to: ./scripts/deployment/deploy.sh

# REMOTE DEPLOYMENT: Deploy container to remote server via SSH
make docker-deploy
# Equivalent to: ./scripts/deployment/deploy-docker.sh --remote-host <server>

# Local service installation (run ON the remote server after deployment)
sudo ./scripts/deployment/install_service.sh
```

## Architecture

### Project Structure
- **src/python/**: Python implementation with full logging and virtual environment
- **src/go/**: Go implementation optimized for production with health monitoring
- **scripts/run/**: Runtime wrapper scripts for both implementations
- **scripts/deployment/**: Production deployment and service installation scripts
- **config/**: Systemd services, Docker configs, and other configuration files
- **docs/**: Comprehensive documentation and setup guides
- **build/**: Compiled binaries and build artifacts

### Dual Implementation Design
- **Python crawler** (`src/python/`): Full-featured with extensive logging, virtual environment isolation
- **Go crawler** (`src/go/`): Optimized for production with health endpoint (port 9100), smaller memory footprint
- Both versions maintain feature parity for guest login, HTML parsing, and metrics generation

### Metrics System
- **metrics.prom**: Main Prometheus metrics file with online user counts
- **latency.prom**: Separate file tracking URL discovery performance (Go version only)
- **File rotation**: Automatic rotation at 10MB with dated backups (format: `metrics.prom.YYYYMMDD.N`)
- **Headers**: Each metrics file includes proper Prometheus HELP and TYPE comments

### Guest Access Logic
Both implementations handle Moodle guest authentication automatically:
1. Visit login page (`/login/index.php?loginredirect=1`)
2. Detect and submit guest access forms or follow guest links
3. Navigate to dashboard (`/my/`) to establish session
4. Search for online users data in common locations

### Health Monitoring
The Go version includes:
- HTTP health endpoint at `/health` on port 9100
- Container healthcheck support via `--healthcheck` flag
- Status tracking based on successful page fetches

## Deployment Methods

### Local Development
- Python: Uses virtual environment (`venv/`) with `run-crawler.sh` wrapper
- Dependencies installed from `requirements.txt`

### Remote Production Deployment (Primary Method)
- **`deploy.sh`**: Deploys Python version to remote Ubuntu/Debian server via SSH
  - Copies project files via rsync
  - Sets up Python virtual environment on remote server
  - Creates `moodle` user and proper permissions
  - Installs and starts systemd service
- **`deploy-docker.sh`**: Deploys containerized version to remote server via SSH
  - Installs Podman/Docker on remote server
  - Pulls image from registry
  - Creates and starts systemd service for container

### Systemd Services (Post-Deployment)
- **moodle-crawler.service**: Python version service (created by `deploy.sh`)
- **moodle-crawler-docker.service**: Container-based service (created by `deploy-docker.sh`)
- Services run as `moodle` user with data in `/opt/moodle-crawler*/data`

### Container Deployment Details
- Multi-stage Dockerfile building statically-linked Go binary
- Distroless base image for security
- Volume mount for `/app/data` persistence
- Health checks using internal binary probe

**Important**: Both deployment scripts are designed for **remote server deployment**, not local installation.

## Key Dependencies

### Python
- `requests` - HTTP client for Moodle API calls
- `beautifulsoup4` + `lxml` - HTML parsing for online user extraction
- Built-in logging with rotation support

### Go
- `github.com/PuerkitoBio/goquery` - jQuery-like HTML parsing
- Standard library HTTP client with cookie jar for session management
- Built-in file rotation and metrics handling

## File Structure Notes

- **Helper scripts**: All `.sh` files are deployment/wrapper scripts
- **Service files**: `*.service` files for systemd integration
- **Config**: `docker-config.json` for container deployment settings
- **Docs**: `*.md` files contain deployment and troubleshooting guides
- **Data output**: Default to `data/` directory (configurable via `--output-dir`)

## Development Tips

- Use `./run-crawler.sh` for Python development - it handles virtual environment automatically
- Go version is preferred for production due to better resource usage and health monitoring
- Both versions support the same command-line arguments for consistency
- Test with example.html file when Moodle site is unavailable
- Monitor logs in `crawler.log` (rotated at 10MB)
- always use make docker-deploy to deploy docker to remote for this project