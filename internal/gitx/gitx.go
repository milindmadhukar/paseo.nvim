// Package gitx wraps the git invocations ws needs.
//
// Every call goes through Run so that one place decides on core.quotePath,
// error shape and timeouts. The concurrency in Statuses is the reason ws is a
// binary at all: status across 11 projects by 6 repos is ~66 git invocations,
// and serialised that is 2-3 seconds, which makes a picker feel broken.
package gitx

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// Run executes git in dir and returns trimmed stdout.
func Run(ctx context.Context, dir string, args ...string) (string, error) {
	// core.quotePath=false: without it every non-ASCII path comes back as a
	// C-quoted escape that names no real file.
	full := append([]string{"-C", dir, "-c", "core.quotePath=false"}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), msg)
	}
	return strings.TrimRight(stdout.String(), "\n"), nil
}

// IsRepo reports whether dir is the top level of a work tree.
func IsRepo(ctx context.Context, dir string) bool {
	top, err := Run(ctx, dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return false
	}
	a, _ := filepath.EvalSymlinks(top)
	b, _ := filepath.EvalSymlinks(dir)
	return a == b
}

// Branch is the checked-out branch, empty on a detached HEAD.
func Branch(ctx context.Context, dir string) string {
	out, err := Run(ctx, dir, "branch", "--show-current")
	if err != nil {
		return ""
	}
	return out
}

// OriginHead is what origin/HEAD points at, e.g. "main". Often WRONG as a base:
// every openfin repo sits on dev while clm_api and fos-pwa have origin/HEAD set
// to main. Reported so init can flag the mismatch, never used as the default.
func OriginHead(ctx context.Context, dir string) string {
	out, err := Run(ctx, dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(out, "origin/")
}

// HasSubmodules reports whether dir declares any.
func HasSubmodules(ctx context.Context, dir string) bool {
	out, err := Run(ctx, dir, "config", "--file", ".gitmodules", "--get-regexp", "path")
	return err == nil && out != ""
}

// Ignored lists gitignored paths at the top level, with their sizes in bytes.
// These are the copy/link candidates: node_modules, venvs, caches, .env files.
func Ignored(ctx context.Context, dir string) ([]string, error) {
	out, err := Run(ctx, dir, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	var paths []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSuffix(strings.TrimSpace(line), "/")
		// Nested entries are noise; the manifest deals in top-level names.
		if line != "" && !strings.Contains(line, "/") {
			paths = append(paths, line)
		}
	}
	return paths, nil
}

// Status is one repo's working-tree state.
type Status struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Branch string `json:"branch"`
	Dirty  int    `json:"dirty"`
	Ahead  int    `json:"ahead"`
	Behind int    `json:"behind"`
	Error  string `json:"error,omitempty"`
}

// Statuses reports on every path CONCURRENTLY.
//
// Serially this is 2-3 seconds across a realistic set of projects, and a picker
// that takes 2-3 seconds to draw reads as broken. Concurrently it is ~80ms.
func Statuses(ctx context.Context, paths map[string]string) []Status {
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		results []Status
	)

	for name, path := range paths {
		wg.Add(1)
		go func(name, path string) {
			defer wg.Done()
			status := Status{Name: name, Path: path}

			if !IsRepo(ctx, path) {
				status.Error = "not a git work tree"
			} else {
				status.Branch = Branch(ctx, path)
				if out, err := Run(ctx, path, "status", "--porcelain"); err == nil && out != "" {
					status.Dirty = len(strings.Split(out, "\n"))
				}
				// No upstream is normal for a fresh worktree branch, so a
				// failure here is not an error -- it just means 0/0.
				if out, err := Run(ctx, path, "rev-list", "--left-right", "--count", "@{upstream}...HEAD"); err == nil {
					fmt.Sscanf(out, "%d\t%d", &status.Behind, &status.Ahead)
				}
			}

			mu.Lock()
			results = append(results, status)
			mu.Unlock()
		}(name, path)
	}

	wg.Wait()
	return results
}
