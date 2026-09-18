// Package workspace assembles and dismantles a workspace: N git worktrees plus
// the untracked context they need to run.
package workspace

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/milindmadhukar/paseo.nvim/internal/gitx"
	"github.com/milindmadhukar/paseo.nvim/internal/manifest"
	"github.com/milindmadhukar/paseo.nvim/internal/registry"
)

// CreateOptions configures assembly.
type CreateOptions struct {
	Name  string
	Root  string   // project root
	Only  []string // exactly these repos
	With  []string // these in addition to the defaults
	Setup bool     // run each repo's setup commands
}

// Create assembles a workspace.
func Create(ctx context.Context, m *manifest.Manifest, opts CreateOptions) (*registry.Workspace, error) {
	if opts.Name == "" {
		return nil, fmt.Errorf("a workspace needs a name")
	}
	if strings.ContainsAny(opts.Name, "/\\ ") {
		return nil, fmt.Errorf("workspace names may not contain slashes or spaces: %q", opts.Name)
	}

	names, err := m.Select(opts.Only, opts.With)
	if err != nil {
		return nil, err
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("no repos selected; every repo is default = false, so name some with --repos")
	}

	root := filepath.Join(opts.Root, m.WorkspacesDir, opts.Name)
	if _, err := os.Stat(root); err == nil {
		return nil, fmt.Errorf("%s already exists", root)
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}

	branch := m.BranchPrefix + opts.Name
	ws := registry.Workspace{
		Name:      opts.Name,
		Project:   opts.Root,
		Root:      root,
		Branch:    branch,
		CreatedAt: time.Now().UTC(),
	}

	// Single-repo projects put the worktree AT the workspace root rather than
	// in a subdirectory, so paths stay `app/main.py` instead of
	// `myrepo/app/main.py` for no reason. paseo.nvim's repo detection handles
	// both shapes.
	single := len(names) == 1 && len(m.Repos) == 1

	for _, name := range names {
		repo := m.Repos[name]
		origin := filepath.Join(opts.Root, name)
		dest := root
		if !single {
			dest = filepath.Join(root, name)
		}

		if err := addWorktree(ctx, origin, dest, branch, repo.Base); err != nil {
			// Leave what was assembled: dismantling a partial workspace on
			// failure would throw away the members that DID come up, and
			// `ws rm` can do it deliberately.
			return nil, fmt.Errorf("%s: %w", name, err)
		}

		if repo.Submodules {
			if _, err := gitx.Run(ctx, dest, "submodule", "update", "--init", "--recursive"); err != nil {
				return nil, fmt.Errorf("%s: submodules: %w", name, err)
			}
		}
		if err := materialise(origin, dest, repo); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		if err := excludeManaged(ctx, dest, repo); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		if opts.Setup {
			if err := runSetup(ctx, dest, repo.Setup); err != nil {
				return nil, fmt.Errorf("%s: setup: %w", name, err)
			}
		}

		ws.Repos = append(ws.Repos, registry.Repo{
			Name:   name,
			Path:   dest,
			Origin: origin,
			Branch: branch,
			Base:   repo.Base,
			State:  registry.StateActive,
		})
	}

	// Members named in the manifest but not selected are recorded as declared,
	// so `ws ls` can show what a workspace could still pull in.
	for _, name := range m.Names() {
		if !contains(names, name) {
			ws.Repos = append(ws.Repos, registry.Repo{
				Name:   name,
				Origin: filepath.Join(opts.Root, name),
				State:  registry.StateDeclared,
			})
		}
	}

	if err := linkShared(opts.Root, root, m.Shared); err != nil {
		return nil, err
	}

	return &ws, nil
}

// addWorktree creates the worktree and its branch.
//
// The base is resolved to `origin/<base>` when that ref exists. Branching from
// the LOCAL branch would base the work on whatever happens to be checked out in
// the primary tree, including unpushed commits and a stale position -- and the
// primary checkout being behind is the normal case, not the exception.
func addWorktree(ctx context.Context, origin, dest, branch, base string) error {
	if !gitx.IsRepo(ctx, origin) {
		return fmt.Errorf("%s is not a git work tree", origin)
	}

	start := base
	if _, err := gitx.Run(ctx, origin, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+base); err == nil {
		start = "origin/" + base
	}

	if _, err := gitx.Run(ctx, origin, "worktree", "add", "-b", branch, dest, start); err != nil {
		// An existing branch is the common second run; reuse it rather than
		// failing, which is what -b cannot do.
		if strings.Contains(err.Error(), "already exists") {
			_, retry := gitx.Run(ctx, origin, "worktree", "add", dest, branch)
			return retry
		}
		return err
	}
	return nil
}

// materialise copies, links and clones the untracked context a repo needs.
func materialise(origin, dest string, repo manifest.Repo) error {
	for _, name := range repo.Copy {
		src, dst := filepath.Join(origin, name), filepath.Join(dest, name)
		if _, err := os.Lstat(src); err != nil {
			continue // nothing to copy is not an error
		}
		// COPIED, never linked. An agent editing PORT= in a shared .env breaks
		// the primary checkout and every sibling workspace at once.
		if err := copyFile(src, dst); err != nil {
			return fmt.Errorf("copy %s: %w", name, err)
		}
	}

	for _, name := range repo.Link {
		src, dst := filepath.Join(origin, name), filepath.Join(dest, name)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := replaceSymlink(src, dst); err != nil {
			return fmt.Errorf("link %s: %w", name, err)
		}
	}

	for _, name := range repo.CloneSymlinks {
		src := filepath.Join(origin, name)
		target, err := os.Readlink(src)
		if err != nil {
			continue
		}
		// The link's TARGET, recreated. Linking to the link resolves correctly
		// right up until the primary checkout moves or is removed.
		if err := replaceSymlink(target, filepath.Join(dest, name)); err != nil {
			return fmt.Errorf("clone symlink %s: %w", name, err)
		}
	}

	return nil
}

// excludeBegin and excludeEnd delimit ws's block in a repo's info/exclude.
const (
	excludeBegin = "# >>> ws managed >>>"
	excludeEnd   = "# <<< ws managed <<<"
)

// excludeManaged stops ws's own symlinks showing up as untracked.
//
// A repo that gitignores `node_modules/` -- with the trailing slash, which is
// how everyone writes it -- does NOT ignore a SYMLINK of that name, because the
// slash means "directory". Every linked directory therefore shows as
// `?? node_modules` in the worktree forever, and `ws rm` refuses to remove a
// workspace over files it created itself.
//
// This has to go in the COMMON info/exclude: a per-worktree $GIT_DIR/info/exclude
// is silently ignored -- git reads that file only from the common dir. Verified
// rather than assumed. The cost in the primary checkout is nil: the repo's own
// .gitignore already covers the directory, and this only adds the slash-less
// form. The block is delimited so it is obviously ws's and can be deleted.
func excludeManaged(ctx context.Context, dest string, repo manifest.Repo) error {
	managed := append(append([]string{}, repo.Link...), repo.CloneSymlinks...)
	if len(managed) == 0 {
		return nil
	}

	common, err := gitx.Run(ctx, dest, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return err
	}
	path := filepath.Join(common, "info", "exclude")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	existing, _ := os.ReadFile(path)
	var kept []string
	inBlock := false
	for _, line := range strings.Split(string(existing), "\n") {
		switch {
		case line == excludeBegin:
			inBlock = true
		case line == excludeEnd:
			inBlock = false
		case !inBlock:
			kept = append(kept, line)
		}
	}
	for len(kept) > 0 && strings.TrimSpace(kept[len(kept)-1]) == "" {
		kept = kept[:len(kept)-1]
	}

	block := append([]string{excludeBegin, "# symlinks ws creates in worktrees; delete this block to undo."}, managed...)
	block = append(block, excludeEnd, "")
	return os.WriteFile(path, []byte(strings.Join(append(kept, block...), "\n")), 0o644)
}

// linkShared symlinks project-level siblings into the workspace root.
func linkShared(project, root string, shared []string) error {
	for _, name := range shared {
		src := filepath.Join(project, name)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := replaceSymlink(src, filepath.Join(root, name)); err != nil {
			return fmt.Errorf("shared %s: %w", name, err)
		}
	}
	return nil
}

func runSetup(ctx context.Context, dir string, commands []string) error {
	for _, command := range commands {
		cmd := exec.CommandContext(ctx, "sh", "-c", command)
		cmd.Dir = dir
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("%q: %w", command, err)
		}
	}
	return nil
}

// RemoveOptions configures dismantling.
type RemoveOptions struct {
	Force bool
}

// Remove dismantles a workspace.
//
// Never `rm -rf`. `git worktree remove` is what keeps .git/worktrees consistent
// -- deleting the directory instead is exactly how the two stale prunable
// entries already on disk got there.
func Remove(ctx context.Context, ws *registry.Workspace, opts RemoveOptions) error {
	if !opts.Force {
		if blockers := unsaved(ctx, ws); len(blockers) > 0 {
			return fmt.Errorf("refusing to remove: %s\npass --force to discard", strings.Join(blockers, "; "))
		}
	}

	for _, repo := range ws.Repos {
		if repo.State != registry.StateActive || repo.Path == "" {
			continue
		}
		args := []string{"worktree", "remove"}
		if opts.Force {
			args = append(args, "--force")
		}
		if _, err := gitx.Run(ctx, repo.Origin, append(args, repo.Path)...); err != nil {
			return fmt.Errorf("%s: %w", repo.Name, err)
		}
	}

	// What is left is ours: the workspace directory and the shared symlinks in
	// it. Removing a symlink never touches what it points at.
	if err := os.RemoveAll(ws.Root); err != nil {
		return err
	}

	// Stale administrative entries are the failure this whole function exists
	// to avoid, so prune regardless.
	for _, repo := range ws.Repos {
		if repo.Origin != "" {
			_, _ = gitx.Run(ctx, repo.Origin, "worktree", "prune")
		}
	}
	return nil
}

// unsaved reports work that removing the workspace would destroy.
func unsaved(ctx context.Context, ws *registry.Workspace) []string {
	var blockers []string
	for _, repo := range ws.Repos {
		if repo.State != registry.StateActive || repo.Path == "" {
			continue
		}
		if out, err := gitx.Run(ctx, repo.Path, "status", "--porcelain"); err == nil && out != "" {
			blockers = append(blockers, fmt.Sprintf("%s has uncommitted changes", repo.Name))
		}

		// Work CREATED HERE and nowhere else: reachable from HEAD, not from any
		// remote, and not from the base this branch was cut from.
		//
		// The base term is what makes this correct. `HEAD --not --remotes`
		// alone lists the ENTIRE history in a repo with no remote configured,
		// so every workspace in such a repo was unremovable -- including one
		// with no commits of its own at all.
		args := []string{"log", "--oneline", "HEAD", "--not", "--remotes"}
		if repo.Base != "" {
			args = append(args, repo.Base)
		}
		if out, err := gitx.Run(ctx, repo.Path, args...); err == nil && out != "" {
			count := len(strings.Split(out, "\n"))
			blockers = append(blockers, fmt.Sprintf("%s has %d unpushed commit(s)", repo.Name, count))
		}
	}
	return blockers
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, info.Mode().Perm())
}

// replaceSymlink points dst at target, removing whatever was there.
func replaceSymlink(target, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if _, err := os.Lstat(dst); err == nil {
		if err := os.Remove(dst); err != nil {
			return err
		}
	}
	return os.Symlink(target, dst)
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}
