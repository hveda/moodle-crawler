package main

import "testing"

func TestSanitizeSiteLabel(t *testing.T) {
    cases := map[string]string{
        "https://example.com/": "example.com_",
        "http://foo.bar/baz": "foo.bar_baz",
        "https://site": "site",
    }
    for in, want := range cases {
        got := sanitizeSiteLabel(in)
        if got != want {
            t.Fatalf("sanitizeSiteLabel(%q) = %q, want %q", in, got, want)
        }
    }
}

func TestExtractOnlineUsers(t *testing.T) {
    html := "<div>There are 42 users online</div>"
    if got := extractOnlineUsers(html); got != 42 {
        t.Fatalf("expected 42 got %d", got)
    }

    html2 := "No users here"
    if got := extractOnlineUsers(html2); got != 0 {
        t.Fatalf("expected 0 got %d", got)
    }
}
