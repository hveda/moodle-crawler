# Multi-stage build with security hardening
FROM golang:1.25.1-alpine3.22 AS builder
# Install security updates and required packages
RUN apk update && apk upgrade && apk add --no-cache ca-certificates git tzdata

# Create unprivileged user for build
RUN adduser -D -g '' appuser

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY main.go .
# Build with security flags and optimizations
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build -ldflags="-w -s -extldflags '-static'" -a -installsuffix cgo -o /app/moodle-crawler

# Security scanning stage (optional, can be enabled in CI)
FROM alpine:3.22 AS security-scan
RUN apk add --no-cache curl
COPY --from=builder /app/moodle-crawler /tmp/binary
# RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
# RUN grype /tmp/binary

# Final minimal image
FROM gcr.io/distroless/static:nonroot
LABEL maintainer="mail@heri.life"
LABEL version="2.0"
LABEL description="Secure Moodle Statistics Crawler"
LABEL org.opencontainers.image.source="https://github.com/hveda/moodle-crawler"
LABEL org.opencontainers.image.vendor="heri.life"
LABEL org.opencontainers.image.licenses="MIT"

# Copy timezone data and CA certificates
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /etc/passwd /etc/passwd

# Copy binary with secure ownership
COPY --from=builder --chown=65534:65534 /app/moodle-crawler /usr/local/bin/moodle-crawler

# Set up secure environment
USER 65534:65534
WORKDIR /app

# Create volume with proper permissions
VOLUME ["/app/data"]

# Health endpoint (restricted access recommended)
EXPOSE 9100

# Security: Use exec form and specific binary path
ENTRYPOINT ["/usr/local/bin/moodle-crawler"]

# Enhanced health check with timeout
# Probes the internal HTTP health endpoint via the binary's --healthcheck mode
# Increased start-period to allow for initial guest login and scrape
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/moodle-crawler", "--healthcheck"]
