package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/milindmadhukar/paseo.nvim/internal/gitx"
	"github.com/milindmadhukar/paseo.nvim/internal/manifest"
	"github.com/milindmadhukar/paseo.nvim/internal/registry"
	"github.com/milindmadhukar/paseo.nvim/internal/workspace"
)

// projectRoot finds the nearest ancestor holding a manifest.
//
// Walking up rather than requiring a path means `ws create` works from inside
// any member repo, which is where you are when you decide you want one.
func projectRoot(start string) (string, error) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(manifest.Path(dir)); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no %s found here or above; run `ws init` first", filepath.Join(manifest.Dir, manifest.File))
		}
		dir = parent
	}
}

func loadProject(explicit string) (string, *manifest.Manifest, error) {
	start := explicit
	if start == "" {
		var err error
		if start, err = os.Getwd(); err != nil {
			return "", nil, err
		}
	}
	root, err := projectRoot(start)
	if err != nil {
		return "", nil, err
	}
	m, err := manifest.Load(root)
	if err != nil {
		return "", nil, err
	}
	return root, m, nil
}

func runCreate(ctx context.Context, args []string) error {
	set := flags("create")
	var only, with listFlag
	set.Var(&only, "repos", "exactly these repos (comma-separated)")
	set.Var(&with, "with", "these repos in addition to the defaults")
	project := set.String("project", "", "project root (default: nearest ancestor with a manifest)")
	setup := set.Bool("setup", false, "run each repo's setup commands")
	asJSON := set.Bool("json", false, "emit the workspace as JSON")
	if err := parse(set, args); err != nil {
		return err
	}

	name := set.Arg(0)
	if name == "" {
		return fmt.Errorf("usage: ws create <name> [--repos a,b] [--with c]")
	}

	root, m, err := loadProject(*project)
	if err != nil {
		return err
	}

	reg, err := registry.Load()
	if err != nil {
		return err
	}
	if _, exists := reg.Find(name, root); exists {
		return fmt.Errorf("workspace %q already exists in %s", name, root)
	}

	ws, err := workspace.Create(ctx, m, workspace.CreateOptions{
		Name:  name,
		Root:  root,
		Only:  only,
		With:  with,
		Setup: *setup,
	})
	if err != nil {
		return err
	}

	reg.Add(*ws)
	if err := reg.Save(); err != nil {
		return err
	}

	if *asJSON {
		return emit(ws)
	}
	fmt.Println(ws.Root)
	for _, repo := range ws.Repos {
		if repo.State == registry.StateActive {
			fmt.Printf("  %-24s %s\n", repo.Name, repo.Branch)
		}
	}
	return nil
}

func runRemove(ctx context.Context, args []string) error {
	set := flags("rm")
	force := set.Bool("force", false, "discard uncommitted and unpushed work")
	project := set.String("project", "", "project root")
	if err := parse(set, args); err != nil {
		return err
	}

	name := set.Arg(0)
	if name == "" {
		return fmt.Errorf("usage: ws rm <name> [--force]")
	}

	root, _, err := loadProject(*project)
	if err != nil {
		return err
	}
	reg, err := registry.Load()
	if err != nil {
		return err
	}
	ws, ok := reg.Find(name, root)
	if !ok {
		return fmt.Errorf("no workspace %q in %s", name, root)
	}

	if err := workspace.Remove(ctx, ws, workspace.RemoveOptions{Force: *force}); err != nil {
		return err
	}
	reg.Remove(name, root)
	if err := reg.Save(); err != nil {
		return err
	}

	fmt.Printf("removed %s\n", name)
	return nil
}

func runList(ctx context.Context, args []string) error {
	set := flags("ls")
	asJSON := set.Bool("json", false, "emit JSON")
	all := set.Bool("all", false, "every project, not just this one")
	project := set.String("project", "", "project root")
	if err := parse(set, args); err != nil {
		return err
	}

	reg, err := registry.Load()
	if err != nil {
		return err
	}

	entries := reg.Workspaces
	if !*all {
		root, _, err := loadProject(*project)
		if err == nil {
			var scoped []registry.Workspace
			for _, ws := range reg.Workspaces {
				if ws.Project == root {
					scoped = append(scoped, ws)
				}
			}
			entries = scoped
		}
	}

	if *asJSON {
		return emit(map[string]any{"workspaces": entries})
	}
	for _, ws := range entries {
		active := 0
		for _, repo := range ws.Repos {
			if repo.State == registry.StateActive {
				active++
			}
		}
		fmt.Printf("%-24s %d repo(s)  %s\n", ws.Name, active, ws.Root)
	}
	return nil
}

func runStatus(ctx context.Context, args []string) error {
	set := flags("status")
	asJSON := set.Bool("json", false, "emit JSON")
	all := set.Bool("all", false, "every project")
	project := set.String("project", "", "project root")
	if err := parse(set, args); err != nil {
		return err
	}

	reg, err := registry.Load()
	if err != nil {
		return err
	}

	root, _, projectErr := loadProject(*project)
	type entry struct {
		Workspace string        `json:"workspace"`
		Project   string        `json:"project"`
		Repos     []gitx.Status `json:"repos"`
	}
	var out []entry

	for _, ws := range reg.Workspaces {
		if !*all && projectErr == nil && ws.Project != root {
			continue
		}
		if name := set.Arg(0); name != "" && ws.Name != name {
			continue
		}

		paths := map[string]string{}
		for _, repo := range ws.Repos {
			if repo.State == registry.StateActive && repo.Path != "" {
				paths[repo.Name] = repo.Path
			}
		}
		// Concurrently, per workspace. This is the call the whole binary
		// exists for.
		out = append(out, entry{Workspace: ws.Name, Project: ws.Project, Repos: gitx.Statuses(ctx, paths)})
	}

	if *asJSON {
		return emit(map[string]any{"workspaces": out})
	}
	for _, e := range out {
		fmt.Println(e.Workspace)
		for _, repo := range e.Repos {
			flagsText := []string{}
			if repo.Dirty > 0 {
				flagsText = append(flagsText, fmt.Sprintf("%d dirty", repo.Dirty))
			}
			if repo.Ahead > 0 {
				flagsText = append(flagsText, fmt.Sprintf("+%d", repo.Ahead))
			}
			if repo.Behind > 0 {
				flagsText = append(flagsText, fmt.Sprintf("-%d", repo.Behind))
			}
			if repo.Error != "" {
				flagsText = append(flagsText, repo.Error)
			}
			fmt.Printf("  %-24s %-28s %s\n", repo.Name, repo.Branch, strings.Join(flagsText, " "))
		}
	}
	return nil
}

func runPath(_ context.Context, args []string) error {
	set := flags("path")
	project := set.String("project", "", "project root")
	if err := parse(set, args); err != nil {
		return err
	}

	name := set.Arg(0)
	if name == "" {
		return fmt.Errorf("usage: ws path <name>")
	}

	reg, err := registry.Load()
	if err != nil {
		return err
	}
	root, _, _ := loadProject(*project)
	ws, ok := reg.Find(name, root)
	if !ok {
		if ws, ok = reg.Find(name, ""); !ok {
			return fmt.Errorf("no workspace %q", name)
		}
	}
	fmt.Println(ws.Root)
	return nil
}
