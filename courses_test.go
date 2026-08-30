package main

import (
	"testing"
)

// TestEscapeLabel covers Prometheus text-format label escaping.
func TestEscapeLabel(t *testing.T) {
	cases := []struct{ in, want string }{
		{"plain", "plain"},
		{`back\slash`, `back\\slash`},
		{`quo"te`, `quo\"te`},
		{"new\nline", `new\nline`},
		{"  Pengenalan (Pendaftaran)  ", "  Pengenalan (Pendaftaran)  "},
	}
	for _, c := range cases {
		if got := escapeLabel(c.in); got != c.want {
			t.Errorf("escapeLabel(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestParseCourseList verifies course id+name extraction from a category page.
func TestParseCourseList(t *testing.T) {
	html := `
	<div class="coursebox">
	  <div class="info">
	    <h3 class="coursename"><a href="https://m.example/course/view.php?id=3446">Simulasi Perkuliahan di SiberMu</a></h3>
	  </div>
	</div>
	<div class="coursebox">
	  <div class="info">
	    <h3 class="coursename"><a href="https://m.example/course/view.php?id=3799&amp;something=1">Sample - User Interface Experience</a></h3>
	  </div>
	</div>`
	got := parseCourseList(html)
	if len(got) != 2 {
		t.Fatalf("parseCourseList returned %d courses, want 2: %+v", len(got), got)
	}
	if got[0].ID != 3446 || got[0].Name != "Simulasi Perkuliahan di SiberMu" {
		t.Errorf("course[0] = %+v", got[0])
	}
	if got[1].ID != 3799 || got[1].Name != "Sample - User Interface Experience" {
		t.Errorf("course[1] = %+v", got[1])
	}
}

// TestParseSections verifies section anchor extraction.
func TestParseSections(t *testing.T) {
	html := `
	<ul class="sections">
	  <li id="section-0" class="section"><span class="sectionname">General</span></li>
	  <li id="section-1" class="section"><h3 class="sectionname">Pengenalan (Pendaftaran)</h3></li>
	  <li id="section-2" class="section"><span class="sectionname">Materi Minggu 1</span></li>
	</ul>`
	got := parseSections(html)
	if len(got) != 2 { // section-0 skipped
		t.Fatalf("parseSections returned %d, want 2: %+v", len(got), got)
	}
	if got[0].Number != 1 || got[0].Name != "Pengenalan (Pendaftaran)" {
		t.Errorf("section[0] = %+v", got[0])
	}
	if got[1].Number != 2 || got[1].Name != "Materi Minggu 1" {
		t.Errorf("section[1] = %+v", got[1])
	}
}

// TestTrimFloat verifies avg rendering without trailing zeros.
func TestTrimFloat(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{{584.5, "584.5"}, {428, "428"}, {1073, "1073"}, {946.5, "946.5"}}
	for _, c := range cases {
		if got := trimFloat(c.in); got != c.want {
			t.Errorf("trimFloat(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}
