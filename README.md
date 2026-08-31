# Moodle Statistics Crawler

Single Go binary. Scrapes Moodle sites as a guest, exports Prometheus metrics:
online user counts, URL-discovery latency, and (with `--courses`) per-course and
per-section page load latencies. Static binary, zero runtime dependencies.

Production deployment: systemd service on LXC, 60s interval, metrics flow
crawler → node_exporter textfile collector → Prometheus → Grafana.

## Quick Start

```bash
make build
./build/moodle-crawler --url=https://your-moodle-site.com --interval=60
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | `https://example.com` | Base Moodle URL |
| `--interval` | `60` | Seconds between crawls |
| `--textfile-dir` | *(empty)* | Directory for node_exporter textfile snapshot. Required for live Prometheus scraping |
| `--courses` | `false` | Discover courses, measure course/section page load latencies |
| `--duration` | `0` | Stop after N minutes (0 = run forever) |
| `--output-dir` | `data` | Directory for history `.prom` files |
| `--prometheus` | `true` | Write history `.prom` files |
| `--healthcheck` | `false` | One-off probe of the local `/health` endpoint, then exit |

Health endpoint: `GET :9100/health` → 200 when last scrape succeeded, 500
otherwise. For systemd watchdogs and container HEALTHCHECKs.

## Metrics

| Metric | Labels | Meaning |
|--------|--------|---------|
| `moodle_online_users_total` | `site` | Online user count. **Only written on successful scrape** — never a false zero |
| `moodle_find_online_users_latency_milliseconds` | `site` | URL discovery latency |
| `moodle_scrape_success` | `site` | 1 = last scrape OK, 0 = failed |
| `moodle_course_page_load_latency_ms` | `site,course` | Course page load time (`--courses`) |
| `moodle_section_page_avg_load_latency_ms` | `site,course,section` | Section page avg load (`--courses`) |
| `moodle_section_page_max_load_latency_ms` | `site,course,section` | Section page max load (`--courses`) |
| `moodle_section_page_min_load_latency_ms` | `site,course,section` | Section page min load (`--courses`) |

On fetch failure no user-count line is written — a zero would be
indistinguishable from a real "0 users online". Watch `moodle_scrape_success`
for outages.

History files auto-rotate at 10MB. Textfile snapshot (`--textfile-dir`) is
rewritten atomically each cycle with current values (no timestamps — let
Prometheus stamp ingestion time). In `--courses` mode only the course pass
writes the snapshot, so all families appear consistently.

Only courses with guest access are measured; ~10 courses appear/disappear
over time as guest access is toggled by admins. This is expected.

## Local Monitoring with Grafana

```bash
docker compose up -d   # Grafana + node_exporter textfile collector
```

Grafana at http://localhost:3000 (admin/admin). Datasource points at the
textfile collector container. `data/` is mounted flat — node_exporter's
textfile collector is not recursive.

## Remote Deployment (binary + systemd)

```bash
REMOTE_HOST=your-server.com MOODLE_URL=https://your-moodle-site.com ./deploy.sh
```

Creates `moodle` user, installs static binary to `/opt/moodle-crawler/bin/`,
hardened systemd service (`NoNewPrivileges`, `ProtectSystem=strict`,
`ReadWritePaths`). No container runtime needed.

For a full stack (crawler + node_exporter + Prometheus + Grafana as native
services), see deploy.sh — it covers the crawler; broker/exporter stack is
installed separately per host.

## Commands

```bash
make build    # compile to build/moodle-crawler
make test     # go test
make vet      # go vet
make fmt      # gofmt (write)
make clean    # remove build/
make run      # run locally against example.com
make deploy   # deploy via deploy.sh
```

## Architecture

- `main.go` — crawler core: guest login → URL discovery → count extraction →
  metrics files + textfile snapshot + health server
- `courses.go` — course discovery, section parsing, section latency stats
- `Dockerfile` — multi-stage (golang:1.26-alpine → distroless/static:nonroot)
- `deploy.sh` — binary + systemd deployment
- `docker-compose.yml` — local dev stack (Grafana + textfile collector)
- `grafana/` — provisioned datasource + 8-panel dashboard

Extraction priority: `div.info` text → `block_online_users` divs → header
parents → full-text regex. Guest login handles English and Indonesian
(`akses tamu`) Moodle instances.

## License

MIT
