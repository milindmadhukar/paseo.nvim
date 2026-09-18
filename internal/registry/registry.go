// Package registry records what ws has assembled.
//
// It holds only CHEAP DURABLE FACTS -- names, paths, branches, the Paseo
// workspace id. Live state (dirty, ahead, behind) is deliberately absent: a
// picker has to open instantly and fill its status column afterwards, and a
// registry that stores status is a registry that is always slightly wrong.
package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// RepoState is a member's condition.
type RepoState string

const (
	// StateDeclared is a member with no worktree yet -- the lazy-worktree
	// answer, so a workspace can name six repos and materialise two.
	StateDeclared RepoState = "declared"
	StateActive   RepoState = "active"
	StateShared   RepoState = "shared"
	StateBroken   RepoState = "broken"
)

// Repo is one member of a workspace.
type Repo struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Origin string `json:"origin"`
	Branch string `json:"branch"`
	// Base is the ref the branch was cut from. Needed to tell work created in
	// this workspace from history it merely inherited -- without it, every
	// commit in a repo with no remote reads as unpushed.
	Base  string    `json:"base,omitempty"`
	State RepoState `json:"state"`
}

// Workspace is one assembled unit of work.
type Workspace struct {
	Name    string `json:"name"`
	Project string `json:"project"`
	Root    string `json:"root"`
	Branch  string `json:"branch"`
	Repos   []Repo `json:"repos"`
	// PaseoID is filled in by paseo.nvim, not by ws.
	//
	// Registering the assembled directory with the daemon is THE SEAM that
	// makes multi-repo work -- Paseo sees a plain local workspace and never
	// learns it is six worktrees. But it happens over the daemon's WebSocket
	// from the sidecar, never from here: the `paseo` CLI is the Electron
	// desktop binary, so every invocation opens a window on the user's desktop
	// and writes startup logs to stdout, mixed into its own --json output.
	PaseoID   string    `json:"paseoWorkspaceId,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
}

// Registry is the whole file.
type Registry struct {
	Version    int         `json:"version"`
	Workspaces []Workspace `json:"workspaces"`
}

// Path is where the registry lives. $XDG_STATE_HOME, then ~/.local/state.
func Path() string {
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return filepath.Join(os.TempDir(), "ws", "registry.json")
		}
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "ws", "registry.json")
}

// Load reads the registry, returning an empty one when the file is absent.
func Load() (*Registry, error) {
	data, err := os.ReadFile(Path())
	if errors.Is(err, os.ErrNotExist) {
		return &Registry{Version: 1}, nil
	}
	if err != nil {
		return nil, err
	}

	var r Registry
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s is not valid JSON: %w", Path(), err)
	}
	if r.Version == 0 {
		r.Version = 1
	}
	return &r, nil
}

// Save writes the registry ATOMICALLY.
//
// Through a temp file and a rename: ws runs from a picker and from agents, so
// two processes writing at once is ordinary rather than exceptional, and a
// half-written registry loses every workspace rather than one.
func (r *Registry) Save() error {
	path := Path()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	sort.Slice(r.Workspaces, func(i, j int) bool {
		if r.Workspaces[i].Project != r.Workspaces[j].Project {
			return r.Workspaces[i].Project < r.Workspaces[j].Project
		}
		return r.Workspaces[i].Name < r.Workspaces[j].Name
	})

	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}

	temp, err := os.CreateTemp(filepath.Dir(path), ".registry-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())

	if _, err := temp.Write(append(data, '\n')); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

// Find returns the workspace with this name, and whether it exists. A project
// scopes the search when given, since two projects may both have a "main".
func (r *Registry) Find(name, project string) (*Workspace, bool) {
	for i := range r.Workspaces {
		if r.Workspaces[i].Name != name {
			continue
		}
		if project == "" || r.Workspaces[i].Project == project {
			return &r.Workspaces[i], true
		}
	}
	return nil, false
}

// Add records a workspace, replacing any entry with the same name and project.
func (r *Registry) Add(ws Workspace) {
	for i := range r.Workspaces {
		if r.Workspaces[i].Name == ws.Name && r.Workspaces[i].Project == ws.Project {
			r.Workspaces[i] = ws
			return
		}
	}
	r.Workspaces = append(r.Workspaces, ws)
}

// Remove drops a workspace. It reports whether one was removed.
func (r *Registry) Remove(name, project string) bool {
	for i := range r.Workspaces {
		if r.Workspaces[i].Name == name && (project == "" || r.Workspaces[i].Project == project) {
			r.Workspaces = append(r.Workspaces[:i], r.Workspaces[i+1:]...)
			return true
		}
	}
	return false
}
