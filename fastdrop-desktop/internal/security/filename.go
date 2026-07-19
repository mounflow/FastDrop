package security

import (
	"path/filepath"
	"strings"
)

// Windows-illegal characters per spec §17.
const windowsIllegalChars = `\/:*?"<>|`

// windowsReservedNames is the closed set from spec §17.
var windowsReserved = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

// SanitizeFilename returns a safe basename for storing an uploaded file.
// It strips path separators (../, ..\, /etc/passwd, C:\Windows\),
// Windows-illegal chars, NUL bytes, and Windows reserved names.
// It never returns an empty string — falls back to "file" if sanitization
// removes everything.
func SanitizeFilename(name string) string {
	if name == "" {
		return "file"
	}
	// 1. Always basename: strip any path. filepath.Base handles / and \ on
	//    Windows but we want cross-platform safety, so do both manually.
	name = stripPathSeparators(name)
	// 2. Remove NUL and other control characters.
	name = stripControlChars(name)
	// 3. Replace Windows-illegal chars with underscore.
	var b strings.Builder
	for _, r := range name {
		if strings.ContainsRune(windowsIllegalChars, r) {
			b.WriteByte('_')
		} else {
			b.WriteRune(r)
		}
	}
	name = b.String()
	// 4. Strip trailing dots and spaces (Windows drops them silently).
	name = strings.TrimRight(name, ". ")
	// 5. Reserved name check (case-insensitive, ignore extension for the test).
	if isReservedName(name) {
		name = "_" + name
	}
	if name == "" || name == "." {
		return "file"
	}
	return name
}

func stripPathSeparators(name string) string {
	// Replace both kinds of separators with a sentinel, then take the last
	// segment. This defeats `..\..\..` and `/etc/passwd` style escapes.
	name = strings.ReplaceAll(name, "\\", "/")
	parts := strings.Split(name, "/")
	// Drop trailing empty (from trailing slash) and "." / ".." segments.
	for i := len(parts) - 1; i >= 0; i-- {
		p := parts[i]
		if p == "" || p == "." || p == ".." {
			continue
		}
		return p
	}
	return ""
}

func stripControlChars(name string) string {
	var b strings.Builder
	for _, r := range name {
		if r == 0 || r < 0x20 {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func isReservedName(name string) bool {
	if name == "" {
		return false
	}
	// Strip extension for the test: "CON.txt" is still reserved.
	stem := name
	if dot := strings.LastIndex(stem, "."); dot >= 0 {
		stem = stem[:dot]
	}
	return windowsReserved[strings.ToUpper(stem)]
}

// ResolveConflict returns a non-conflicting basename in the directory dir
// given the desired name. Policy "rename" produces "photo (1).jpg".
// If a file with the proposed name already exists, an incrementing counter
// is inserted before the extension, starting at 1.
// If policy is "overwrite" the original name is returned unchanged.
// If policy is "skip" and the name exists, "" is returned.
//
// The caller is responsible for the actual atomic rename; this function only
// computes the name and does NOT create the file.
func ResolveConflict(dir, name, policy string, exists func(path string) bool) string {
	full := filepath.Join(dir, name)
	if policy == "overwrite" || !exists(full) {
		return name
	}
	if policy == "skip" {
		return ""
	}
	// Default: rename.
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 1; ; i++ {
		candidate := stem + " (" + itoa(i) + ")" + ext
		if !exists(filepath.Join(dir, candidate)) {
			return candidate
		}
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var buf [20]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}
