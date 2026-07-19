package security

import (
	"bytes"
	"strings"
	"testing"
)

func TestGenerateTokenLength(t *testing.T) {
	tok, err := GenerateToken()
	if err != nil {
		t.Fatal(err)
	}
	// 32 bytes -> 43 chars Base64URL no padding.
	if len(tok) != 43 {
		t.Errorf("token length = %d, want 43", len(tok))
	}
	// Must be URL-safe.
	if strings.ContainsAny(tok, "+/=") {
		t.Errorf("token contains non-URL-safe chars: %q", tok)
	}
}

func TestGenerateTokenUniqueness(t *testing.T) {
	seen := make(map[string]bool, 100)
	for i := 0; i < 100; i++ {
		tok, err := GenerateToken()
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatalf("token collision at i=%d", i)
		}
		seen[tok] = true
	}
}

func TestHashTokenStable(t *testing.T) {
	if HashToken("abc") != HashToken("abc") {
		t.Error("hash not deterministic")
	}
	if HashToken("abc") == HashToken("abd") {
		t.Error("hash collision on different inputs")
	}
}

func TestHashReader(t *testing.T) {
	h, err := HashReader(bytes.NewReader([]byte("hello")))
	if err != nil {
		t.Fatal(err)
	}
	if h != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" {
		t.Errorf("wrong sha: %s", h)
	}
}

func TestSanitizeFilename(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"photo.jpg", "photo.jpg"},
		{"../etc/passwd", "passwd"},
		{"..\\..\\windows\\system32\\evil.dll", "evil.dll"},
		{"C:\\Windows\\system.ini", "system.ini"},
		{"/etc/passwd", "passwd"},
		{"CON.txt", "_CON.txt"},
		{"nul", "_nul"},
		{"COM1", "_COM1"},
		{"lpt9.log", "_lpt9.log"},
		{"bad:name?.txt", "bad_name_.txt"},
		{"trailing.", "trailing"},
		{"trailing   ", "trailing"},
		{"name\x00null", "namenull"},
		{"", "file"},
		{"....", "file"},
	}
	for _, c := range cases {
		got := SanitizeFilename(c.in)
		if got != c.want {
			t.Errorf("SanitizeFilename(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSanitizeFilenameNoPathSep(t *testing.T) {
	for _, in := range []string{"../x", "..\\x", "/x", "\\x"} {
		got := SanitizeFilename(in)
		if strings.ContainsAny(got, "/\\") {
			t.Errorf("output contains path separator: %q -> %q", in, got)
		}
	}
}

func TestResolveConflictRename(t *testing.T) {
	exists := func(p string) bool {
		return strings.HasSuffix(p, "photo.jpg")
	}
	got := ResolveConflict("/dir", "photo.jpg", "rename", exists)
	if got != "photo (1).jpg" {
		t.Errorf("first conflict = %q", got)
	}
	exists2 := func(p string) bool {
		return strings.HasSuffix(p, "photo.jpg") || strings.HasSuffix(p, "photo (1).jpg")
	}
	got2 := ResolveConflict("/dir", "photo.jpg", "rename", exists2)
	if got2 != "photo (2).jpg" {
		t.Errorf("second conflict = %q", got2)
	}
}

func TestResolveConflictNoConflict(t *testing.T) {
	got := ResolveConflict("/dir", "photo.jpg", "rename", func(string) bool { return false })
	if got != "photo.jpg" {
		t.Errorf("no-conflict path returned %q", got)
	}
}

func TestResolveConflictSkip(t *testing.T) {
	got := ResolveConflict("/dir", "photo.jpg", "skip", func(string) bool { return true })
	if got != "" {
		t.Errorf("skip should return empty, got %q", got)
	}
}

func TestResolveConflictOverwrite(t *testing.T) {
	got := ResolveConflict("/dir", "photo.jpg", "overwrite", func(string) bool { return true })
	if got != "photo.jpg" {
		t.Errorf("overwrite returned %q", got)
	}
}
