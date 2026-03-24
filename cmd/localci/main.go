// localci — local CI tool that runs commands on Nix platforms and posts
// GitHub commit statuses. Two modes: single-step (-- <cmd>) runs one
// command; multi-step (-f config.json) orchestrates parallel steps via
// process-compose. When --system differs from the current host, commands
// run on a remote machine over SSH.
package main

import (
	"os"

	flag "github.com/spf13/pflag"
)

func main() {
	args := parseArgs()

	if !isInGitRepo() {
		logErr("Not inside a git repository.")
		os.Exit(1)
	}

	// --sha pins to an explicit commit and skips the clean-tree check.
	// This is used internally by multi-step mode when self-invoking for
	// each step, since the repo is already extracted to a temp dir.
	var sha string
	if args.shaPin != "" {
		// Resolve symbolic refs (e.g. "HEAD") to full SHA for GitHub API
		resolved, err := resolveRef(args.shaPin)
		if err != nil {
			sha = args.shaPin // fall back to literal if resolution fails
		} else {
			sha = resolved
		}
	} else {
		if !isTreeClean() {
			logErr("Working tree is dirty. Commit or stash changes first.")
			os.Exit(1)
		}
		var err error
		sha, err = resolveHEAD()
		if err != nil {
			logErr("Could not resolve HEAD: %v", err)
			os.Exit(1)
		}
	}

	if args.configFile != "" {
		os.Exit(runMultiStep(args, sha))
	}

	if len(args.cmd) == 0 {
		logErr("A command after -- is required (or use -f for multi-step mode).")
		flag.Usage()
		os.Exit(1)
	}

	os.Exit(runSingleStep(args, sha))
}

type cliArgs struct {
	system         string
	systemExplicit bool // true when -s/--system was passed (even for local system)
	name           string
	cmd            []string // everything after --
	shaPin         string
	configFile     string
	tui            bool
	mcp            bool
	noSignoff      bool
	workdir        string // pre-extracted dir, set by multi-step self-invocation
}

func parseArgs() cliArgs {
	var a cliArgs

	flag.StringVarP(&a.system, "system", "s", "", "Nix system string (if omitted, runs on current system)")
	flag.StringVarP(&a.name, "name", "n", "", "Check name for GitHub status context (default: command name)")
	flag.StringVar(&a.shaPin, "sha", "", "Pin to a specific commit SHA (skips clean-tree check)")
	flag.StringVarP(&a.configFile, "file", "f", "", "JSON config file defining steps, systems, and dependencies")
	flag.BoolVar(&a.tui, "tui", false, "Enable process-compose TUI (multi-step mode only)")
	flag.BoolVar(&a.mcp, "mcp", false, "Expose steps as MCP tools via process-compose (multi-step mode only)")
	flag.BoolVar(&a.noSignoff, "no-signoff", false, "Skip GitHub status posting (test locally before pushing)")
	flag.StringVar(&a.workdir, "workdir", "", "Pre-extracted working directory (internal, used by multi-step mode)")

	flag.Usage = func() {
		logErr("Usage: localci [options] -- <command...>")
		logErr("       localci -f <config.json>")
		logErr("")
		flag.PrintDefaults()
	}

	flag.Parse()

	a.systemExplicit = flag.CommandLine.Changed("system")
	// Everything after -- is the command
	a.cmd = flag.Args()

	return a
}
