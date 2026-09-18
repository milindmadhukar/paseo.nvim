// Package discover generates a manifest by looking at a project on disk.
//
// `ws init` is non-negotiable: hand-writing eleven manifests, each with six
// repos and their own base branch and ignored-directory list, is the failure
// mode this whole thing is meant to remove.
package discover

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/milindmadhukar/paseo.nvim/internal/gitx"
	"github.com/milindmadhukar/paseo.nvim/internal/manifest"
)

// MaxDepth is how far below the project root a repository may sit.
//
// Three, not one: ~/Code/grasslabs/kora holds five repositories two levels
// down, so a depth-1 walk finds none of them.
const MaxDepth = 3

// heavyThreshold is the size above which an ignored directory is worth
// linking rather than ignoring.
const heavyThreshold = 20 << 20 // 20 MiB

// optOutThreshold is the COPIED-data size above which a repo leaves the default
// set.
//
// Copied, not total: linked directories are shared with the primary checkout
// and cost nothing per workspace. Counting them excluded clm and fos-pwa over a
// 500MB node_modules that is symlinked -- and those are the two repos most
// workspaces are actually for.
const optOutThreshold = 200 << 20 // 200 MiB

// heavyCount is the number of large ignored directories above which a repo
// leaves the default set regardless of size.
//
// Disk is not the only cost of a member. Each one is a `worktree add`, possibly
// a recursive submodule init, a setup script, and one more tree for the LSP and
// ripgrep to index. hipa-v2 has ten heavy directories; clm and fos-pwa have
// one each. That ratio is the signal, and it picks out exactly the repo the
// plan called out by hand.
const heavyCount = 6

// copyNames are untracked paths that must be COPIED per workspace, never
// shared. An agent editing PORT= in a shared .env breaks the primary checkout
// and every sibling workspace at once.
var copyNames = []string{".env", ".envrc", ".env.local", ".env.development", ".env.production"}

// Result is what a walk found.
type Result struct {
	Root     string
	Manifest *manifest.Manifest
	Notes    []manifest.Note
}

type found struct {
	name   string
	path   string
	branch string
	head   string
}

// Walk builds a manifest for the project rooted at root.
func Walk(ctx context.Context, root string) (*Result, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", root)
	}

	repos, shared, err := scan(ctx, root)
	if err != nil {
		return nil, err
	}
	if len(repos) == 0 {
		return nil, fmt.Errorf("no git repositories under %s (searched %d levels)", root, MaxDepth)
	}

	m := &manifest.Manifest{
		Shared:        shared,
		WorkspacesDir: ".workspaces",
		BranchPrefix:  "ws/",
		Repos:         map[string]manifest.Repo{},
	}

	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		notes []manifest.Note
	)

	for _, repo := range repos {
		wg.Add(1)
		go func(r found) {
			defer wg.Done()
			entry, repoNotes := describe(ctx, r)
			mu.Lock()
			m.Repos[r.name] = entry
			notes = append(notes, repoNotes...)
			mu.Unlock()
		}(repo)
	}
	wg.Wait()

	sort.Slice(notes, func(i, j int) bool { return notes[i].Repo < notes[j].Repo })
	return &Result{Root: root, Manifest: m, Notes: notes}, nil
}

// scan finds repositories and untracked sibling directories.
func scan(ctx context.Context, root string) ([]found, []string, error) {
	var (
		repos      []found
		candidates []string
	)

	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil // an unreadable directory is not fatal
		}
		if !entry.IsDir() || path == root {
			return nil
		}

		rel, _ := filepath.Rel(root, path)
		if depth := len(strings.Split(rel, string(filepath.Separator))); depth > MaxDepth {
			return fs.SkipDir
		}
		name := entry.Name()
		if name == ".git" || name == ".ws" || name == ".workspaces" || name == "node_modules" {
			return fs.SkipDir
		}

		if gitx.IsRepo(ctx, path) {
			repos = append(repos, found{
				name:   rel,
				path:   path,
				branch: gitx.Branch(ctx, path),
				head:   gitx.OriginHead(ctx, path),
			})
			// Do not descend into a repository: submodules are the repo's
			// business, not separate members.
			return fs.SkipDir
		}

		// A top-level directory that is not a repository is a shared sibling
		// candidate: openfin/Docs, kora/graphify-out. Recorded, not accepted --
		// a directory that turns out to CONTAIN a repository is a parent, not a
		// sibling, and symlinking it into every workspace would drag that
		// repository in sideways. ~/Code/openfin/archive is exactly that.
		if filepath.Dir(path) == root && !strings.HasPrefix(name, ".") {
			candidates = append(candidates, path)
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	sort.Slice(repos, func(i, j int) bool { return repos[i].name < repos[j].name })

	// Drop any candidate that an accepted repository lives beneath.
	var shared []string
	for _, candidate := range candidates {
		prefix := candidate + string(filepath.Separator)
		contains := false
		for _, repo := range repos {
			if strings.HasPrefix(repo.path, prefix) {
				contains = true
				break
			}
		}
		if !contains {
			shared = append(shared, filepath.Base(candidate))
		}
	}
	sort.Strings(shared)

	return repos, shared, nil
}

// describe turns one repository into a manifest entry plus the comments a
// reader needs in order to check init's guesses.
func describe(ctx context.Context, r found) (manifest.Repo, []manifest.Note) {
	var notes []manifest.Note
	note := func(format string, args ...any) {
		notes = append(notes, manifest.Note{Repo: r.name, Text: fmt.Sprintf(format, args...)})
	}

	entry := manifest.Repo{Base: r.branch}
	if entry.Base == "" {
		entry.Base = r.head
		note("detached HEAD; base guessed from origin/HEAD. CHECK THIS.")
	}

	// The base comes from what is CHECKED OUT, not from origin/HEAD. All six
	// openfin repos sit on dev while clm_api and fos-pwa report origin/HEAD as
	// main, so origin/HEAD would silently base the work on the wrong history.
	if r.head != "" && r.branch != "" && r.head != r.branch {
		note("origin/HEAD is %q but %q is checked out; base follows the checkout.", r.head, r.branch)
	}

	if gitx.HasSubmodules(ctx, r.path) {
		entry.Submodules = true
		note("has submodules; they are initialised after `worktree add`.")
	}

	ignored, err := gitx.Ignored(ctx, r.path)
	if err != nil {
		note("could not list ignored files: %v", err)
		return entry, notes
	}

	var copied int64
	var heavy int
	for _, name := range ignored {
		full := filepath.Join(r.path, name)
		info, err := os.Lstat(full)
		if err != nil {
			continue
		}

		// A symlink is recreated verbatim, not linked to. hipa-v2 has a `plan`
		// symlink into an Obsidian vault; a link to a link resolves correctly
		// right up until the primary checkout moves.
		if info.Mode()&os.ModeSymlink != 0 {
			entry.CloneSymlinks = append(entry.CloneSymlinks, name)
			note("%s is a symlink; recreated verbatim rather than linked to.", name)
			continue
		}

		if isCopyName(name) {
			entry.Copy = append(entry.Copy, name)
			continue
		}

		if info.IsDir() {
			size := dirSize(full)
			if size >= heavyThreshold {
				entry.Link = append(entry.Link, name)
				heavy++
				note("%s is %s; linked to the primary checkout, not copied.", name, human(size))
			} else {
				// Small enough to be copied per workspace, so it is what a
				// workspace actually costs.
				copied += size
			}
		}
	}

	switch {
	case copied >= optOutThreshold:
		no := false
		entry.Default = &no
		note("%s of per-workspace data; excluded from the default set. Opt in with --with %s.", human(copied), r.name)
	case heavy >= heavyCount:
		no := false
		entry.Default = &no
		note("%d heavy directories to link and a tree this size to index; excluded from the default set. Opt in with --with %s.", heavy, r.name)
	}

	sort.Strings(entry.Copy)
	sort.Strings(entry.Link)
	sort.Strings(entry.CloneSymlinks)
	return entry, notes
}

func isCopyName(name string) bool {
	for _, candidate := range copyNames {
		if name == candidate {
			return true
		}
	}
	return strings.HasPrefix(name, ".env")
}

// dirSize sums a directory, following nothing. Symlinks are not followed: a
// link into an Obsidian vault would otherwise charge the vault's size to the
// repository.
func dirSize(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		info, err := entry.Info()
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return nil
		}
		if !entry.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

func human(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%dB", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.0f%cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
