package workspace_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/milindmadhukar/paseo.nvim/internal/discover"
	"github.com/milindmadhukar/paseo.nvim/internal/manifest"
	"github.com/milindmadhukar/paseo.nvim/internal/registry"
	"github.com/milindmadhukar/paseo.nvim/internal/workspace"
)

// project builds a two-repo project with a non-git parent -- the shape the
// whole tool exists for, and the one Paseo cannot isolate on its own.
func project(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	for _, name := range []string{"clm", "clm_api"} {
		dir := filepath.Join(root, name)
		mkdir(t, dir)
		git(t, dir, "init", "-q", "-b", "dev", ".")
		git(t, dir, "config", "user.email", "test@example.com")
		git(t, dir, "config", "user.name", "test")
		write(t, filepath.Join(dir, "f.txt"), "base\n")
		write(t, filepath.Join(dir, ".env"), "PORT=3000\n")
		write(t, filepath.Join(dir, ".gitignore"), "node_modules/\n.env\n")
		mkdir(t, filepath.Join(dir, "node_modules"))
		write(t, filepath.Join(dir, "node_modules", "pkg.txt"), strings.Repeat("x", 1024))
		git(t, dir, "add", "-A")
		git(t, dir, "-c", "commit.gpgsign=false", "commit", "-qm", "init")
	}

	mkdir(t, filepath.Join(root, "Docs"))
	write(t, filepath.Join(root, "Docs", "readme.md"), "shared\n")
	return root
}

func TestCreateCopiesEnvAndLinksHeavyDirs(t *testing.T) {
	root := project(t)
	m := manifestFor(t, root)

	ws, err := workspace.Create(context.Background(), m, workspace.CreateOptions{Name: "otp", Root: root})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	for _, name := range []string{"clm", "clm_api"} {
		dir := filepath.Join(ws.Root, name)

		// .env is COPIED. Editing it in a workspace must not reach the primary
		// checkout: an agent changing PORT= in a shared file breaks every
		// sibling workspace at once.
		env := filepath.Join(dir, ".env")
		info, err := os.Lstat(env)
		if err != nil {
			t.Fatalf("%s/.env: %v", name, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			t.Errorf("%s/.env is a symlink; it must be a copy", name)
		}
		write(t, env, "PORT=9999\n")
		if got := read(t, filepath.Join(root, name, ".env")); got != "PORT=3000\n" {
			t.Errorf("editing the workspace .env changed the primary: %q", got)
		}

		// node_modules is LINKED, because sharing it is the point.
		link, err := os.Lstat(filepath.Join(dir, "node_modules"))
		if err != nil {
			t.Fatalf("%s/node_modules: %v", name, err)
		}
		if link.Mode()&os.ModeSymlink == 0 {
			t.Errorf("%s/node_modules is not a symlink", name)
		}
	}

	// The shared sibling lands at the workspace root, once, not per repo.
	if info, err := os.Lstat(filepath.Join(ws.Root, "Docs")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Errorf("Docs is not symlinked into the workspace root")
	}

	// The primary checkouts are untouched -- the whole point of isolation.
	for _, name := range []string{"clm", "clm_api"} {
		if out := gitOut(t, filepath.Join(root, name), "status", "--porcelain"); out != "" {
			t.Errorf("primary %s is dirty after create: %q", name, out)
		}
		if branch := gitOut(t, filepath.Join(root, name), "branch", "--show-current"); branch != "dev" {
			t.Errorf("primary %s moved to %q", name, branch)
		}
	}
}

// A repo that gitignores `node_modules/` does NOT ignore a SYMLINK of that
// name -- the trailing slash means "directory". Without the exclude block every
// linked directory shows as untracked forever and ws rm refuses to remove a
// workspace over files ws itself created.
func TestLinkedDirsDoNotShowAsUntracked(t *testing.T) {
	root := project(t)
	m := manifestFor(t, root)

	ws, err := workspace.Create(context.Background(), m, workspace.CreateOptions{Name: "otp", Root: root})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	for _, name := range []string{"clm", "clm_api"} {
		if out := gitOut(t, filepath.Join(ws.Root, name), "status", "--porcelain"); out != "" {
			t.Errorf("%s worktree is not clean: %q", name, out)
		}
	}
}

func TestRemoveRefusesRealWorkAndLeavesNoStaleEntries(t *testing.T) {
	root := project(t)
	m := manifestFor(t, root)
	ctx := context.Background()

	ws, err := workspace.Create(ctx, m, workspace.CreateOptions{Name: "otp", Root: root})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// A workspace with no commits of its own removes cleanly. The regression:
	// `HEAD --not --remotes` with no remote configured lists the ENTIRE
	// history, so every workspace in such a repo was unremovable.
	if err := workspace.Remove(ctx, ws, workspace.RemoveOptions{}); err != nil {
		t.Fatalf("remove of an untouched workspace was refused: %v", err)
	}
	for _, name := range []string{"clm", "clm_api"} {
		// `git worktree remove`, never rm -rf: deleting the directory is how
		// stale .git/worktrees entries get left behind.
		if out := gitOut(t, filepath.Join(root, name), "worktree", "list"); strings.Count(out, "\n") != 0 {
			t.Errorf("%s has stale worktree entries:\n%s", name, out)
		}
	}

	ws2, err := workspace.Create(ctx, m, workspace.CreateOptions{Name: "feature", Root: root})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	dir := filepath.Join(ws2.Root, "clm")
	write(t, filepath.Join(dir, "f.txt"), "real work\n")
	git(t, dir, "add", "f.txt")
	git(t, dir, "-c", "commit.gpgsign=false", "commit", "-qm", "real work")

	err = workspace.Remove(ctx, ws2, workspace.RemoveOptions{})
	if err == nil {
		t.Fatal("remove did not refuse a workspace holding an unpushed commit")
	}
	if !strings.Contains(err.Error(), "unpushed") {
		t.Errorf("refusal did not mention unpushed work: %v", err)
	}

	if err := workspace.Remove(ctx, ws2, workspace.RemoveOptions{Force: true}); err != nil {
		t.Fatalf("--force was refused: %v", err)
	}
}

func TestSelectRespectsDefaultAndWith(t *testing.T) {
	no := false
	m := &manifest.Manifest{Repos: map[string]manifest.Repo{
		"clm":     {Base: "dev"},
		"clm_api": {Base: "dev"},
		"hipa-v2": {Base: "dev", Default: &no},
	}}

	got, err := m.Select(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"clm", "clm_api"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("defaults: got %v, want %v", got, want)
	}

	got, _ = m.Select(nil, []string{"hipa-v2"})
	if len(got) != 3 {
		t.Errorf("--with hipa-v2: got %v", got)
	}

	got, _ = m.Select([]string{"clm"}, []string{"hipa-v2"})
	if strings.Join(got, ",") != "clm" {
		t.Errorf("--repos must win over --with: got %v", got)
	}

	if _, err := m.Select([]string{"nope"}, nil); err == nil {
		t.Error("selecting an unknown repo did not fail")
	}
}

func manifestFor(t *testing.T, root string) *manifest.Manifest {
	t.Helper()
	result, err := discover.Walk(context.Background(), root)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	// The fixture's node_modules is deliberately tiny, so init classifies it as
	// copyable. The behaviour under test is link handling, so declare it.
	for name, repo := range result.Manifest.Repos {
		repo.Link = []string{"node_modules"}
		result.Manifest.Repos[name] = repo
	}
	return result.Manifest
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out))
}

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

var _ = registry.Workspace{}
