package main

import (
	"context"
	"errors"
)

// Implemented in the commits that follow; declared here so `ws --help` and the
// dispatch table are honest about what exists rather than listing commands that
// panic.
var errNotImplemented = errors.New("not implemented yet")

func runCreate(context.Context, []string) error { return errNotImplemented }
func runRemove(context.Context, []string) error { return errNotImplemented }
func runList(context.Context, []string) error   { return errNotImplemented }
func runStatus(context.Context, []string) error { return errNotImplemented }
func runPath(context.Context, []string) error   { return errNotImplemented }
