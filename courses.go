package main

// courses.go — course/section latency collection mode.
//
// Reimplements the metrics the pre-Go Python crawler emitted, with identical
// metric names and label schemes so historical and new series join cleanly:
//
//	moodle_course_page_load_latency_ms{course,site}
//	moodle_section_page_avg_load_latency_ms{course,section}
//	moodle_section_page_max_load_latency_ms{course,section}
//	moodle_section_page_min_load_latency_ms{course,section}
//
// Intentional differences vs legacy data:
//   - section labels trimmed (legacy label values contain raw \n + indent —
//     invalid text format, escaped during historical import)
//   - each section fetched twice per cycle; avg is float64 (legacy half
//     integer avgs come from the same 2-fetch mean)

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/PuerkitoBio/goquery"
)

// courseEntry is one discovered course.
type courseEntry struct {
	ID   int
	Name string
}

// sectionRef is a section anchor: number (for &section=M) + display name.
type sectionRef struct {
	Number int
	Name   string
}

// sectionStat carries per-section timing across the two fetches.
type sectionStat struct {
	Course  string
	Section string
	Avg     float64
	Max     int
	Min     int
}

var (
	courseHeaders = []string{
		`# HELP moodle_course_page_load_latency_ms Course page load latency (ms)`,
		`# TYPE moodle_course_page_load_latency_ms gauge`,
	}
	sectionAvgHeaders = []string{
		`# HELP moodle_section_page_avg_load_latency_ms Average section page load latency (ms)`,
		`# TYPE moodle_section_page_avg_load_latency_ms gauge`,
	}
	sectionDetailsHeaders = []string{
		`# HELP moodle_section_page_max_load_latency_ms Max section page load latency (ms)`,
		`# TYPE moodle_section_page_max_load_latency_ms gauge`,
		`# HELP moodle_section_page_min_load_latency_ms Min section page load latency (ms)`,
		`# TYPE moodle_section_page_min_load_latency_ms gauge`,
	}
)

// escapeLabel escapes a label value per Prometheus text format.
func escapeLabel(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	v = strings.ReplaceAll(v, `"`, `\"`)
	v = strings.ReplaceAll(v, "\n", `\n`)
	return v
}

// fetchBody GETs a URL with the guest session and returns the body.
func fetchBody(ctx context.Context, client *http.Client, u string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("GET %s: status %d", u, resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// fetchCourses walks /course/index.php (+ one category level) and returns
// discovered courses.
func fetchCourses(ctx context.Context, client *http.Client, base string) ([]courseEntry, error) {
	indexURL := strings.TrimRight(base, "/") + "/course/index.php"
	html, err := fetchBody(ctx, client, indexURL)
	if err != nil {
		return nil, fmt.Errorf("course index: %w", err)
	}
	courses := parseCourseList(html)

	// descend one category level (legacy behavior)
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err == nil {
		var catIDs []string
		doc.Find("a[href]").Each(func(_ int, s *goquery.Selection) {
			href, _ := s.Attr("href")
			if i := strings.Index(href, "categoryid="); i >= 0 {
				id := href[i+len("categoryid="):]
				if j := strings.IndexAny(id, "&#"); j >= 0 {
					id = id[:j]
				}
				if id != "" {
					catIDs = append(catIDs, id)
				}
			}
		})
		sort.Strings(catIDs)
		seen := map[string]bool{}
		for _, id := range catIDs {
			if seen[id] {
				continue
			}
			seen[id] = true
			subCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
			sub, err := fetchBody(subCtx, client, indexURL+"?categoryid="+id)
			cancel()
			if err != nil {
				continue
			}
			courses = append(courses, parseCourseList(sub)...)
		}
	}

	byID := map[int]bool{}
	out := []courseEntry{}
	for _, c := range courses {
		if !byID[c.ID] {
			byID[c.ID] = true
			out = append(out, c)
		}
	}
	return out, nil
}

// parseCourseList extracts course id+name pairs from a course index page.
func parseCourseList(html string) []courseEntry {
	var out []courseEntry
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err != nil {
		return nil
	}
	seen := map[int]bool{}
	doc.Find("h3.coursename a[href], .coursename a[href]").Each(func(_ int, s *goquery.Selection) {
		href, _ := s.Attr("href")
		i := strings.Index(href, "id=")
		if i < 0 {
			return
		}
		idStr := href[i+3:]
		if j := strings.IndexAny(idStr, "&#"); j >= 0 {
			idStr = idStr[:j]
		}
		id, err := strconv.Atoi(idStr)
		if err != nil || seen[id] {
			return
		}
		seen[id] = true
		out = append(out, courseEntry{ID: id, Name: strings.TrimSpace(s.Text())})
	})
	return out
}

// looksLikeLoginPage detects Moodle's login page (course redirected because
// guest access is not allowed). Moodle embeds a logintoken input on it.
func looksLikeLoginPage(html string) bool {
	return strings.Contains(html, "logintoken")
}

// looksLikeCourseView reports whether the page is a real course view page
// (has section markup). Moodle always renders at least li#section-0, so a
// page without it is an interstitial ("cannot enrol", preview prompt, …).
func looksLikeCourseView(html string) bool {
	return strings.Contains(html, `id="section-`)
}

// fetchCoursePage fetches a course page and returns (html, latencyMs).
// Pages that are not real course views (login redirect, enrolment required)
// are reported as errors so they never contribute bogus latency samples.
func fetchCoursePage(ctx context.Context, client *http.Client, base string, courseID int) (string, int, error) {
	u := fmt.Sprintf("%s/course/view.php?id=%d", strings.TrimRight(base, "/"), courseID)
	start := time.Now()
	html, err := fetchBody(ctx, client, u)
	ms := int(time.Since(start).Milliseconds())
	if err != nil {
		return "", ms, err
	}
	if looksLikeLoginPage(html) {
		return "", ms, fmt.Errorf("course %d: guest access denied (login redirect)", courseID)
	}
	if !looksLikeCourseView(html) {
		return "", ms, fmt.Errorf("course %d: not a course view (enrolment required?)", courseID)
	}
	return html, ms, nil
}

// parseSections extracts section anchors from a course page.
func parseSections(html string) []sectionRef {
	var out []sectionRef
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err != nil {
		return nil
	}
	seen := map[int]bool{}
	// Moodle course formats: li#section-N with .sectionname title (or
	// .course-section-header in 4.x). RemUI themes prepend a "Select section"
	// dropdown option to the title text — strip it.
	doc.Find("li[id^=section-]").Each(func(_ int, s *goquery.Selection) {
		idAttr, _ := s.Attr("id")
		numStr := strings.TrimPrefix(idAttr, "section-")
		num, err := strconv.Atoi(numStr)
		if err != nil || num == 0 || seen[num] { // section 0 = "General"/news, skip
			return
		}
		title := ""
		s.Find(".sectionname, .course-section-header").Each(func(_ int, t *goquery.Selection) {
			if title == "" {
				title = strings.TrimSpace(t.Text())
			}
		})
		if title == "" {
			return
		}
		title = strings.TrimPrefix(title, "Select section ")
		title = strings.TrimSpace(title)
		if title == "" {
			return
		}
		seen[num] = true
		out = append(out, sectionRef{Number: num, Name: title})
	})
	return out
}

// fetchSectionPage times one section page fetch.
func fetchSectionPage(ctx context.Context, client *http.Client, base string, courseID, sectionNum int) (int, error) {
	u := fmt.Sprintf("%s/course/view.php?id=%d&section=%d", strings.TrimRight(base, "/"), courseID, sectionNum)
	start := time.Now()
	_, err := fetchBody(ctx, client, u)
	return int(time.Since(start).Milliseconds()), err
}

// collectSectionStats fetches each section twice, returning avg/max/min.
func collectSectionStats(ctx context.Context, client *http.Client, base string, courseName string, courseID int, sections []sectionRef) []sectionStat {
	var stats []sectionStat
	for _, sec := range sections {
		var times []int
		for i := 0; i < 2; i++ {
			ms, err := fetchSectionPage(ctx, client, base, courseID, sec.Number)
			if err == nil {
				times = append(times, ms)
			}
		}
		if len(times) == 0 {
			continue
		}
		st := sectionStat{Course: courseName, Section: sec.Name, Max: times[0], Min: times[0]}
		sum := 0
		for _, t := range times {
			sum += t
			if t > st.Max {
				st.Max = t
			}
			if t < st.Min {
				st.Min = t
			}
		}
		st.Avg = float64(sum) / float64(len(times))
		stats = append(stats, st)
	}
	return stats
}

// writeCourseMetrics appends one cycle of course/section metrics.
func writeCourseMetrics(outdir, siteLabel string, courses []courseEntry, courseLatencies map[int]int, sectionStats []sectionStat, ts int64) error {
	coursePath := fmt.Sprintf("%s/course_page_latency.prom", outdir)
	sectionAvgPath := fmt.Sprintf("%s/section_page_avg_latency.prom", outdir)
	sectionDetailsPath := fmt.Sprintf("%s/section_page_details_latency.prom", outdir)

	for _, c := range courses {
		ms, ok := courseLatencies[c.ID]
		if !ok {
			continue
		}
		line := fmt.Sprintf("moodle_course_page_load_latency_ms{course=\"%s\",site=\"%s\"} %d %d",
			escapeLabel(c.Name), siteLabel, ms, ts)
		if err := appendLine(coursePath, line, courseHeaders); err != nil {
			return err
		}
	}
	for _, st := range sectionStats {
		avgLine := fmt.Sprintf("moodle_section_page_avg_load_latency_ms{course=\"%s\",section=\"%s\"} %s %d",
			escapeLabel(st.Course), escapeLabel(st.Section), trimFloat(st.Avg), ts)
		if err := appendLine(sectionAvgPath, avgLine, sectionAvgHeaders); err != nil {
			return err
		}
	}
	for _, st := range sectionStats {
		maxLine := fmt.Sprintf("moodle_section_page_max_load_latency_ms{course=\"%s\",section=\"%s\"} %d %d",
			escapeLabel(st.Course), escapeLabel(st.Section), st.Max, ts)
		minLine := fmt.Sprintf("moodle_section_page_min_load_latency_ms{course=\"%s\",section=\"%s\"} %d %d",
			escapeLabel(st.Course), escapeLabel(st.Section), st.Min, ts)
		if err := appendLine(sectionDetailsPath, maxLine, sectionDetailsHeaders); err != nil {
			return err
		}
		if err := appendLine(sectionDetailsPath, minLine, sectionDetailsHeaders); err != nil {
			return err
		}
	}
	return nil
}

// trimFloat renders a float without trailing zeros (584.5 not 584.500000).
func trimFloat(f float64) string {
	s := strconv.FormatFloat(f, 'f', -1, 64)
	return s
}
