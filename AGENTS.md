# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Go-only Moodle crawler. Single binary, guest access, Prometheus metrics:
online users, URL-discovery latency, optional per-course/section page load
latencies (`--courses`). Python implementation was removed; Go covers all
former functionality.

## Commands

```bash
make build        # go build -o build/moodle-crawler .
make test         # go test -v ./...
make vet          # go vet ./...
make fmt          # gofmt -l -w .
```

CI (`.github/workflows/ci.yml`): go mod verify, vet, test, gofmt check,
Docker build.

## Layout

- `main.go` — crawler core, flags, textfile snapshot, health server
- `courses.go` / `courses_test.go` — course+section collection (`--courses`)
- `main_test.go` — sanitizeSiteLabel, extractOnlineUsers tests
- `deploy.sh` — remote binary + systemd deploy
- `Dockerfile` / `docker-compose.yml` — container build, local dev stack
- `grafana/` — dashboard + provisioning

## Invariants (do not break)

1. **Never write a false zero.** On scrape failure, `moodle_online_users_total`
   is not written. Gap + `moodle_scrape_success=0` signals outage.
2. **Label compatibility with imported history.** Course/section metric labels
   must stay byte-identical to the normalizer output (`course`, `section`,
   `site` labels; `&` entity handling). Grafana panels and 8.5M imported
   samples depend on it.
3. **Snapshot write discipline.** In `--courses` mode only the course pass
   writes the textfile snapshot — base scrape must not clobber it (regression
   fixed in 834fa32).
4. **Atomic snapshot.** Textfile written to `.tmp` then renamed —
   node_exporter must never read a partial file.
5. **Static build.** `CGO_ENABLED=0`, distroless container, deploy via
   `deploy.sh`/systemd. No runtime deps.

## Conventions

- Commit style: `fix(scope): ...`, `feat(scope): ...`
- gofmt clean required (CI enforces)
- History files rotate at 10MB; textfile snapshot is current-values only
