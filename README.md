# Moodle Statistics Crawler

A simple tool to collect online user counts and latency metrics from Moodle sites. Designed for straightforward data gathering with optional local visualization.

## 🎯 What This Tool Does

- **Collects online user counts** from Moodle sites (guest access)
- **Measures latency** for URL discovery operations
- **Exports metrics** in Prometheus format for monitoring
- **Single Go implementation** — static binary or container, no runtime dependencies

> **Note:** The Python implementation was removed in favor of the Go one.
> The Go version now covers all former Python functionality (duration limit
> via `--duration`, scrape-failure semantics that never write false zeros).
> The crawler never collects individual user data — only aggregate counts.

## 🚀 Quick Start

### Run Locally

```bash
make build
./build/moodle-crawler --url=https://your-moodle-site.com --interval=60
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | `https://example.com` | Base Moodle URL |
| `--interval` | `60` | Seconds between crawls |
| `--duration` | `0` | Stop after N minutes (0 = run forever) |
| `--output-dir` | `data` | Output directory |
| `--prometheus` | `true` | Write Prometheus metrics files |
| `--healthcheck` | `false` | One-off probe of the local `/health` endpoint, then exit |

### Health Endpoint

The crawler serves `GET /health` on port `9100`, returning `200 OK` when the
last scrape succeeded and `500` otherwise — for systemd watchdogs, Docker
`HEALTHCHECK`, and external orchestrators.

## 📊 Metrics

| File | Metric | Meaning |
|------|--------|---------|
| `metrics.prom` | `moodle_online_users_total{site}` | Online user count (only written on successful scrape) |
| `latency.prom` | `moodle_find_online_users_latency_milliseconds{site}` | URL-discovery latency |
| `scrape_success.prom` | `moodle_scrape_success{site}` | 1 = last scrape OK, 0 = fetch failed |

On fetch failure the crawler writes **no** user-count line — a zero would be
indistinguishable from a real "0 users online" in Grafana. Watch
`moodle_scrape_success` for outages.

Files auto-rotate at 10MB (`metrics.prom.YYYYMMDDHHMMSS.backup`).

## 📊 Local Monitoring with Grafana

```bash
docker-compose up -d   # Grafana + node-exporter textfile collector
```

Access Grafana at http://localhost:3000 (admin/admin). The textfile collector
mounts `./data` flat (node-exporter's textfile collector is not recursive).

## 🚢 Remote Deployment

### Deploy Go Binary + systemd (no container runtime required)

```bash
REMOTE_HOST=your-server.com MOODLE_URL=https://your-moodle-site.com ./deploy.sh
```

Creates a `moodle` user, installs the static binary to
`/opt/moodle-crawler/bin/`, and runs it as a hardened systemd service
(`NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths=data`).

### Deploy Container Version

```bash
./deploy-docker.sh --remote-host your-server.com
```

## 🛠 Available Commands

```bash
make help              # Show all commands
make build             # Build Go binary
make test              # Run Go tests
make clean             # Clean build artifacts
make run-go            # Run Go crawler locally
make deploy            # Deploy Go binary to remote server (systemd)
make docker-deploy     # Deploy container to remote server
make sync-data         # Sync data from remote server
make docker-build      # Build container image locally
make container-info    # Show container runtime info
```

## 🏗 Architecture

- `main.go` — crawler: guest login → URL discovery → count extraction → metrics files
- `Dockerfile` — multi-stage build (golang:1.26-alpine → distroless/static:nonroot)
- `deploy.sh` — Go binary + systemd deployment
- `deploy-docker.sh` — container + systemd deployment
- `grafana/` — provisioned datasource + dashboard

Extraction strategies (in priority order): `div.info` text →
`block_online_users` divs → header parents → full-text regex. Guest login
handles English and Indonesian (`akses tamu`) Moodle instances.

## 📄 License

MIT
