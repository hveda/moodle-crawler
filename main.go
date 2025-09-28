package main

import (
    "context"
    "flag"
    "fmt"
    "log"
    "io"
    "net/http"
    "net/http/cookiejar"
    "os"
    "path/filepath"
    "regexp"
    "strings"
    "time"
    "strconv"
    "net/url"
    "sync/atomic"
    "github.com/PuerkitoBio/goquery"
)

const (
    maxFileSize = 10 * 1024 * 1024 // 10MB
)

func ensureDir(dir string) error {
    return os.MkdirAll(dir, 0o755)
}

func sanitizeSiteLabel(u string) string {
    s := strings.ReplaceAll(u, "http://", "")
    s = strings.ReplaceAll(s, "https://", "")
    s = strings.ReplaceAll(s, "/", "_")
    return s
}

func rotateIfNeeded(path string, headers []string) error {
    info, err := os.Stat(path)
    if err == nil && info.Size() >= maxFileSize {
        ts := time.Now().Format("20060102150405")
        backup := fmt.Sprintf("%s.%s.backup", path, ts)
        if err := os.Rename(path, backup); err != nil {
            return err
        }
        f, err := os.Create(path)
        if err != nil {
            return err
        }
        defer f.Close()
        for _, h := range headers {
            f.WriteString(h + "\n")
        }
    }
    return nil
}

func appendLine(path, line string, headers []string) error {
    if err := rotateIfNeeded(path, headers); err != nil {
        return err
    }
    // Ensure headers exist before appending so tools can parse files
    if err := ensureHeaders(path, headers); err != nil {
        return err
    }
    f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
    if err != nil {
        return err
    }
    defer f.Close()
    _, err = f.WriteString(line + "\n")
    return err
}

func ensureHeaders(path string, headers []string) error {
    // If file doesn't exist or is empty, write headers
    info, err := os.Stat(path)
    if err != nil {
        // file likely doesn't exist; create with headers
        f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
        if err != nil {
            return err
        }
        defer f.Close()
        for _, h := range headers {
            if _, err := f.WriteString(h + "\n"); err != nil {
                return err
            }
        }
        return nil
    }
    if info.Size() == 0 {
        f, err := os.OpenFile(path, os.O_WRONLY, 0o644)
        if err != nil {
            return err
        }
        defer f.Close()
        for _, h := range headers {
            if _, err := f.WriteString(h + "\n"); err != nil {
                return err
            }
        }
    }
    return nil
}

func extractOnlineUsers(html string) int {
    doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
    if err != nil {
        return 0
    }

    // Pattern for phrases like "X online users" or "users online"
    re := regexp.MustCompile(`(?i)([0-9]+)\s+(?:users?\s+online|online\s+users?)`)

    // 1) Look for div.info elements (highest priority)
    var found int
    doc.Find("div.info").EachWithBreak(func(i int, s *goquery.Selection) bool {
        text := strings.TrimSpace(s.Text())
        m := re.FindStringSubmatch(text)
        if len(m) >= 2 {
            if v, err := strconv.Atoi(m[1]); err == nil {
                found = v
                return false
            }
        }
        return true
    })
    if found > 0 {
        return found
    }

    // 2) Look for online users block (class containing block_online_users)
    doc.Find("div").EachWithBreak(func(i int, s *goquery.Selection) bool {
        if class, ok := s.Attr("class"); ok && strings.Contains(class, "block_online_users") {
            text := strings.TrimSpace(s.Text())
            m := re.FindStringSubmatch(text)
            if len(m) >= 2 {
                if v, err := strconv.Atoi(m[1]); err == nil {
                    found = v
                    return false
                }
            }
        }
        return true
    })
    if found > 0 {
        return found
    }

    // 3) Look for headers (h4 or similar) that contain 'online users' and examine the parent
    doc.Find("h1,h2,h3,h4,h5,h6").EachWithBreak(func(i int, s *goquery.Selection) bool {
        if strings.Contains(strings.ToLower(s.Text()), "online users") {
            parent := s.Parent()
            if parent != nil {
                text := strings.TrimSpace(parent.Text())
                m := re.FindStringSubmatch(text)
                if len(m) >= 2 {
                    if v, err := strconv.Atoi(m[1]); err == nil {
                        found = v
                        return false
                    }
                }
            }
        }
        return true
    })
    if found > 0 {
        return found
    }

    // 4) Fallback: search all text nodes for "X online users" pattern
    var allText strings.Builder
    doc.Find("*").Each(func(i int, s *goquery.Selection) {
        t := strings.TrimSpace(s.Text())
        if t != "" {
            allText.WriteString(" ")
            allText.WriteString(t)
        }
    })
    m := re.FindStringSubmatch(allText.String())
    if len(m) >= 2 {
        if v, err := strconv.Atoi(m[1]); err == nil {
            return v
        }
    }
    return 0
}

func findOnlineUsersURL(ctx context.Context, client *http.Client, base string) (string, error) {
    // Try dashboard then base then common paths
    tryList := []string{strings.TrimRight(base, "/") + "/my/", base}
    common := []string{"/user/index.php", "/blocks/online_users/index.php", "/user/online.php", "/course/view.php?id=1"}
    tryList = append(tryList, func() []string { r := []string{}; for _, p := range common { r = append(r, base+p) }; return r }()...)

    for _, u := range tryList {
        req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
        resp, err := client.Do(req)
        if err != nil { continue }
        b, _ := io.ReadAll(resp.Body)
        resp.Body.Close()
        if strings.Contains(strings.ToLower(string(b)), "online users") || strings.Contains(strings.ToLower(string(b)), "online") {
            return u, nil
        }
    }
    return base, nil
}

// loginAsGuest attempts to access the site as a guest by visiting the login
// page and following a guest link or submitting a guest form if present.
func loginAsGuest(ctx context.Context, client *http.Client, base string) error {
    // Use loginredirect=1 so the 'Access as guest' control is present and redirects to /my/
    loginURL := strings.TrimRight(base, "/") + "/login/index.php?loginredirect=1"
    req, _ := http.NewRequestWithContext(ctx, "GET", loginURL, nil)
    resp, err := client.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    if resp.StatusCode >= 400 {
        return fmt.Errorf("login page returned status %d", resp.StatusCode)
    }
    body, _ := io.ReadAll(resp.Body)
    doc, err := goquery.NewDocumentFromReader(strings.NewReader(string(body)))
    if err != nil {
        return err
    }

    // Look for forms that explicitly contain a guest access input/button
    guestRe := regexp.MustCompile(`(?i)guest|access.*guest|akses.*tamu|akses.*guest`)
    found := false
    doc.Find("form").EachWithBreak(func(i int, s *goquery.Selection) bool {
        action, _ := s.Attr("action")
        // only consider login forms
        if strings.Contains(action, "login/index.php") || strings.Contains(action, "login") {
            // look for an input whose value or name indicates guest access
            var guestInputName string
            s.Find("input").EachWithBreak(func(_ int, in *goquery.Selection) bool {
                if name, ok := in.Attr("name"); ok {
                    if val, ok2 := in.Attr("value"); ok2 {
                        if guestRe.MatchString(val) || guestRe.MatchString(name) {
                            guestInputName = name
                            return false
                        }
                    } else {
                        if guestRe.MatchString(name) {
                            guestInputName = name
                            return false
                        }
                    }
                }
                return true
            })

            if guestInputName != "" {
                // build form values from inputs but prefer the guest input existence
                inputs := url.Values{}
                s.Find("input").Each(func(_ int, in *goquery.Selection) {
                    if name, ok := in.Attr("name"); ok {
                        if val, ok2 := in.Attr("value"); ok2 {
                            inputs.Set(name, val)
                        } else {
                            inputs.Set(name, "")
                        }
                    }
                })

                dest := action
                if !strings.HasPrefix(action, "http") {
                    baseURL, _ := url.Parse(loginURL)
                    rel, _ := url.Parse(action)
                    dest = baseURL.ResolveReference(rel).String()
                }

                req2, _ := http.NewRequestWithContext(ctx, "POST", dest, strings.NewReader(inputs.Encode()))
                req2.Header.Set("Content-Type", "application/x-www-form-urlencoded")
                resp2, err := client.Do(req2)
                if err == nil {
                    resp2.Body.Close()
                    found = true
                    return false
                }
            }
        }
        return true
    })

    if found {
        return nil
    }

    // Fallback: look for an anchor whose text suggests guest access (or button)
    doc.Find("a,button").EachWithBreak(func(i int, s *goquery.Selection) bool {
        txt := strings.ToLower(strings.TrimSpace(s.Text()))
        if txt == "" {
            // sometimes the control is an input or has aria-label
            if aria, ok := s.Attr("aria-label"); ok {
                txt = strings.ToLower(aria)
            }
        }
        if guestRe.MatchString(txt) {
            if href, ok := s.Attr("href"); ok && href != "" {
                dest := href
                if !strings.HasPrefix(href, "http") {
                    baseURL, _ := url.Parse(loginURL)
                    rel, _ := url.Parse(href)
                    dest = baseURL.ResolveReference(rel).String()
                }
                req2, _ := http.NewRequestWithContext(ctx, "GET", dest, nil)
                resp2, err := client.Do(req2)
                if err == nil {
                    resp2.Body.Close()
                    found = true
                    return false
                }
            }
        }
        return true
    })

    // After attempting guest access, try to fetch /my/ to ensure we're in the guest dashboard
    if !found {
        // still attempt to follow the loginredirect to /my/
        myURL := strings.TrimRight(base, "/") + "/my/"
        req3, _ := http.NewRequestWithContext(ctx, "GET", myURL, nil)
        resp3, err := client.Do(req3)
        if err == nil {
            resp3.Body.Close()
            // we won't fail here — caller can still continue
        }
    } else {
        // if found, fetch /my/ to complete the redirect sequence and populate session
        myURL := strings.TrimRight(base, "/") + "/my/"
        req3, _ := http.NewRequestWithContext(ctx, "GET", myURL, nil)
        resp3, err := client.Do(req3)
        if err == nil {
            resp3.Body.Close()
        }
    }

    return nil
}

func main() {
    url := flag.String("url", "https://example.com", "Base Moodle URL")
    interval := flag.Int("interval", 60, "Interval between crawls in seconds")
    outdir := flag.String("output-dir", "data", "Output directory")
    prometheus := flag.Bool("prometheus", true, "Write Prometheus metrics")
    healthcheck := flag.Bool("healthcheck", false, "Run a single health probe against the local /health endpoint and exit")
    flag.Parse()

    ensureDir(*outdir)
    // Create an HTTP client with cookie jar so guest login sessions persist
    jar, _ := cookiejar.New(nil)
    client := &http.Client{Jar: jar, Timeout: 15 * time.Second}

    metricsPath := filepath.Join(*outdir, "metrics.prom")
    latencyPath := filepath.Join(*outdir, "latency.prom")
    metricHeaders := []string{`# HELP moodle_online_users_total Total number of online users on the Moodle site`, `# TYPE moodle_online_users_total gauge`}
    latencyHeaders := []string{`# HELP moodle_find_online_users_latency_milliseconds Latency (milliseconds) to locate the online users URL`, `# TYPE moodle_find_online_users_latency_milliseconds gauge`}

    siteLabel := sanitizeSiteLabel(*url)
    log.Printf("Starting crawler for %s (label=%s), output=%s, interval=%ds\n", *url, siteLabel, *outdir, *interval)

    // lastStatus==1 when last scrape succeeded (able to fetch page), 0 otherwise
    var lastStatus int32 = 0

    // If invoked as a one-off healthcheck, probe the local HTTP health endpoint and exit
    if *healthcheck {
        probeURL := "http://127.0.0.1:9100/health"
        hc := &http.Client{Timeout: 5 * time.Second}
        resp, err := hc.Get(probeURL)
        if err != nil {
            log.Printf("health probe failed: %v\n", err)
            os.Exit(1)
        }
        defer resp.Body.Close()
        if resp.StatusCode == 200 {
            os.Exit(0)
        }
        os.Exit(1)
    }

    // Start a small HTTP server to serve a health endpoint used by external orchestrators.
    go func() {
        http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
            if atomic.LoadInt32(&lastStatus) == 1 {
                w.WriteHeader(200)
                _, _ = w.Write([]byte("OK"))
                return
            }
            http.Error(w, "unhealthy", http.StatusInternalServerError)
        })
        // listen on 9100 (matches Dockerfile EXPOSE)
        if err := http.ListenAndServe(":9100", nil); err != nil {
            log.Fatalf("health server failed: %v", err)
        }
    }()

    for {
    // Ensure we can access site as guest if required
    ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
    _ = loginAsGuest(ctx, client, *url)

    // Time findOnlineUsersURL
    start := time.Now()
    u, _ := findOnlineUsersURL(ctx, client, *url)
    cancel()
        dur := time.Since(start)
        latencyMs := int(dur.Milliseconds())
        ts := time.Now().UnixMilli()
        latLine := fmt.Sprintf("moodle_find_online_users_latency_milliseconds{site=\"%s\"} %d %d", siteLabel, latencyMs, ts)
        if err := appendLine(latencyPath, latLine, latencyHeaders); err != nil {
            log.Printf("error writing latency: %v\n", err)
        } else {
            log.Printf("latency recorded: %dms -> %s\n", latencyMs, latencyPath)
        }

        // Fetch page and extract users
        req, _ := http.NewRequest("GET", u, nil)
        resp, err := client.Do(req)
        html := ""
        success := false
        if err == nil {
            b, _ := io.ReadAll(resp.Body)
            resp.Body.Close()
            html = string(b)
            success = true
        } else {
            log.Printf("error fetching page %s: %v\n", u, err)
            success = false
        }
        // Update health status based on whether we could fetch the page
        if success {
            atomic.StoreInt32(&lastStatus, 1)
        } else {
            atomic.StoreInt32(&lastStatus, 0)
        }
        count := extractOnlineUsers(html)
        log.Printf("extracted online users: %d from %s\n", count, u)
        metricLine := fmt.Sprintf("moodle_online_users_total{site=\"%s\"} %d %d", siteLabel, count, ts)
        if *prometheus {
            if err := appendLine(metricsPath, metricLine, metricHeaders); err != nil {
                log.Printf("error writing metric: %v\n", err)
            }
        }

        time.Sleep(time.Duration(*interval) * time.Second)
    }
}
