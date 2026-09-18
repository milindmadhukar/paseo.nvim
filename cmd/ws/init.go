package main

import (
	"context"
	"fmt"
	"os"

	"github.com/milindmadhukar/paseo.nvim/internal/discover"
	"github.com/milindmadhukar/paseo.nvim/internal/manifest"
)

func runInit(ctx context.Context, args []string) error {
	set := flags("init")
	dryRun := set.Bool("dry-run", false, "print the manifest instead of writing it")
	asJSON := set.Bool("json", false, "emit the manifest as JSON")
	force := set.Bool("force", false, "overwrite an existing manifest")
	if err := parse(set, args); err != nil {
		return err
	}

	root := set.Arg(0)
	if root == "" {
		var err error
		if root, err = os.Getwd(); err != nil {
			return err
		}
	}

	result, err := discover.Walk(ctx, root)
	if err != nil {
		return err
	}

	if *asJSON {
		return emit(map[string]any{
			"root":  result.Root,
			"repos": result.Manifest.Repos,
			"notes": result.Notes,
		})
	}

	if *dryRun {
		fmt.Print(result.Manifest.Render(result.Notes))
		return nil
	}

	path := manifest.Path(result.Root)
	if _, err := os.Stat(path); err == nil && !*force {
		return fmt.Errorf("%s already exists; pass --force to overwrite", path)
	}
	if err := result.Manifest.Save(result.Root, result.Notes); err != nil {
		return err
	}

	fmt.Printf("wrote %s (%d repos)\n", path, len(result.Manifest.Repos))
	if len(result.Notes) > 0 {
		fmt.Printf("%d note(s) in the file -- they are what init could not decide for you\n", len(result.Notes))
	}
	return nil
}
