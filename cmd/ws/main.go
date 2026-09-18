// Command ws assembles a workspace: one named unit of work spanning N git
// worktrees, plus the untracked context they need to run.
//
// Go, and a binary, for three reasons. It is one static file any agent in any
// sandbox can call. It gets correct JSON for free, which is the contract
// paseo.nvim and the skills both consume. And `ws status` across 11 projects by
// 6 repos is ~66 git invocations: concurrently that is ~80ms, serially it is
// 2-3 seconds, and a picker that takes 2-3 seconds to draw reads as broken.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
)

const usage = `ws -- assemble a workspace across N repositories

  ws init   <project> [--dry-run]     generate <project>/.ws/workspace.toml
  ws create <name> [flags]            assemble a workspace
  ws rm     <name> [--force]          remove one, refusing on unsaved work
  ws ls     [--json]                  list workspaces
  ws status [--json]                  per-repo state, concurrently
  ws path   <name>                    print a workspace root

Run a subcommand with --help for its flags.`

type command struct {
	name string
	run  func(context.Context, []string) error
}

func main() {
	commands := []command{
		{"init", runInit},
		{"create", runCreate},
		{"rm", runRemove},
		{"ls", runList},
		{"status", runStatus},
		{"path", runPath},
	}

	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" {
		fmt.Println(usage)
		return
	}

	for _, c := range commands {
		if c.name == os.Args[1] {
			if err := c.run(context.Background(), os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, "ws: "+err.Error())
				os.Exit(1)
			}
			return
		}
	}

	fmt.Fprintf(os.Stderr, "ws: unknown command %q\n\n%s\n", os.Args[1], usage)
	os.Exit(2)
}

// emit writes v as indented JSON. Every command that can produce structured
// output does so through here, so the shape is one decision.
func emit(v any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(v)
}

// listFlag collects a repeatable comma-separated flag.
type listFlag []string

func (l *listFlag) String() string { return strings.Join(*l, ",") }

func (l *listFlag) Set(value string) error {
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			*l = append(*l, part)
		}
	}
	return nil
}

func flags(name string) *flag.FlagSet {
	set := flag.NewFlagSet(name, flag.ExitOnError)
	set.SetOutput(os.Stderr)
	return set
}

// parse handles flags that come AFTER positional arguments.
//
// Go's flag package stops at the first non-flag argument, so
// `ws init ~/Code/openfin --dry-run` -- the form this tool is documented with,
// and the obvious one to type -- left --dry-run unparsed and WROTE the
// manifest it was asked to preview. Positionals are moved to the end before
// parsing, and a literal `--` still ends flag parsing.
func parse(set *flag.FlagSet, args []string) error {
	var options, positionals []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			positionals = append(positionals, args[i+1:]...)
			break
		}
		if strings.HasPrefix(arg, "-") && arg != "-" {
			options = append(options, arg)
			continue
		}
		positionals = append(positionals, arg)
	}
	return set.Parse(append(options, positionals...))
}
