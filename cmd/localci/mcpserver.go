package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"sync"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// jobResult holds the outcome of an async step execution.
type jobResult struct {
	output string
	rc     int
}

// jobTracker manages async step executions. Steps are kicked off
// immediately and results are polled via the status-all tool.
type jobTracker struct {
	mu      sync.Mutex
	running map[string]chan jobResult
	done    map[string]jobResult
}

func newJobTracker() *jobTracker {
	return &jobTracker{
		running: make(map[string]chan jobResult),
		done:    make(map[string]jobResult),
	}
}

func (jt *jobTracker) start(key string, run func() jobResult) string {
	jt.mu.Lock()
	defer jt.mu.Unlock()

	if _, ok := jt.running[key]; ok {
		return "already running"
	}
	if _, ok := jt.done[key]; ok {
		return "already completed"
	}

	ch := make(chan jobResult, 1)
	jt.running[key] = ch
	go func() {
		ch <- run()
	}()
	return "started"
}

// pollAll returns the status of all tracked steps, draining any
// completed results. Returns a summary string and per-step details.
func (jt *jobTracker) pollAll(keys []string) string {
	jt.mu.Lock()
	defer jt.mu.Unlock()

	// Drain completed channels
	for key, ch := range jt.running {
		select {
		case r := <-ch:
			delete(jt.running, key)
			jt.done[key] = r
		default:
		}
	}

	var lines []string
	allDone := true
	anyFailed := false

	for _, key := range keys {
		if r, ok := jt.done[key]; ok {
			if r.rc != 0 {
				anyFailed = true
				lines = append(lines, fmt.Sprintf("✗ %s: FAILED (exit %d)", key, r.rc))
			} else {
				lines = append(lines, fmt.Sprintf("✓ %s: passed", key))
			}
		} else if _, ok := jt.running[key]; ok {
			allDone = false
			lines = append(lines, fmt.Sprintf("● %s: running", key))
		} else {
			allDone = false
			lines = append(lines, fmt.Sprintf("· %s: not started", key))
		}
	}

	// Summary line
	if allDone {
		if anyFailed {
			lines = append([]string{"STATUS: DONE (some steps failed)\n"}, lines...)
		} else {
			lines = append([]string{"STATUS: ALL PASSED\n"}, lines...)
		}
	} else {
		lines = append([]string{"STATUS: IN PROGRESS\n"}, lines...)
	}

	// Append full output for completed failed steps
	for _, key := range keys {
		if r, ok := jt.done[key]; ok && r.rc != 0 {
			lines = append(lines, fmt.Sprintf("\n--- %s output ---\n%s", key, r.output))
		}
	}

	return strings.Join(lines, "\n")
}

// runMCPServer starts an MCP server over stdio. Steps are async: the step
// tool kicks off execution and returns immediately, then agents poll
// status-all for batch results.
func runMCPServer(args cliArgs) int {
	config, err := loadConfig(args.configFile)
	if err != nil {
		logErr("%v", err)
		return 1
	}

	if _, _, err := resolveHosts(config); err != nil {
		logErr("%v", err)
		return 1
	}

	self, err := selfPathResolved()
	if err != nil {
		logErr("Could not resolve self path: %v", err)
		return 1
	}

	procs := buildProcessEntries(config)
	depMap := buildDepMap(procs, config)
	tracker := newJobTracker()

	s := server.NewMCPServer("localci", "0.1.0")

	// Compute parallel peers
	allDeps := transitiveDeps(depMap)
	peers := make(map[string][]string)
	for _, a := range procs {
		for _, b := range procs {
			if a.key == b.key {
				continue
			}
			if !allDeps[a.key][b.key] && !allDeps[b.key][a.key] {
				peers[a.key] = append(peers[a.key], b.key)
			}
		}
	}

	// Register step tools (async — returns immediately)
	for _, p := range procs {
		step := config.Steps[p.step]
		desc := fmt.Sprintf("Start CI step: %s. Returns immediately — poll status-all for results.", step.Command)
		deps := depMap[p.key]
		if len(deps) == 0 {
			desc += " No dependencies — can start immediately."
		} else {
			desc += fmt.Sprintf(" Depends on: %s.", strings.Join(deps, ", "))
		}
		if peerList := peers[p.key]; len(peerList) > 0 {
			desc += fmt.Sprintf(" Run in parallel with: %s.", strings.Join(peerList, ", "))
		}

		tool := mcp.NewTool(p.key,
			mcp.WithDescription(desc),
			mcp.WithString("sha",
				mcp.Description("Git ref to test (default: HEAD)"),
			),
		)
		s.AddTool(tool, makeAsyncStepHandler(p, step, self, tracker))
	}

	// status-all tool — batch poll all steps in one call
	var stepKeys []string
	for _, p := range procs {
		stepKeys = append(stepKeys, p.key)
	}
	statusAllTool := mcp.NewTool("status-all",
		mcp.WithDescription("Poll all step statuses in one call. Returns summary with pass/fail/running for each step, plus full logs for failures. Call this instead of polling individual steps."),
	)
	s.AddTool(statusAllTool, func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return mcp.NewToolResultText(tracker.pollAll(stepKeys)), nil
	})

	// Dependency graph resource
	graphResource := mcp.NewResource(
		"localci://graph",
		"Dependency Graph",
		mcp.WithResourceDescription("Step dependency graph — shows which steps can run in parallel"),
		mcp.WithMIMEType("application/json"),
	)
	s.AddResource(graphResource, makeGraphHandler(procs, config))

	if err := server.ServeStdio(s); err != nil {
		logErr("MCP server error: %v", err)
		return 1
	}
	return 0
}

func makeAsyncStepHandler(
	p processEntry, step StepConfig,
	self string,
	tracker *jobTracker,
) server.ToolHandlerFunc {
	return func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		sha := request.GetString("sha", "HEAD")

		resolved, err := resolveRef(sha)
		if err == nil {
			sha = resolved
		}

		// Validate workdir each invocation — prevents stale cwd errors
		cwd := validWorkdir()

		cmdParts := []string{self, "--sha", sha}
		if !isCommitPushed(sha) {
			cmdParts = append(cmdParts, "--no-signoff")
		}
		if p.sys != "" {
			cmdParts = append(cmdParts, "-s", p.sys)
		}
		cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

		status := tracker.start(p.key, func() jobResult {
			cmd := exec.Command(cmdParts[0], cmdParts[1:]...)
			cmd.Dir = cwd
			var buf bytes.Buffer
			cmd.Stdout = &buf
			cmd.Stderr = &buf
			rc := exitCode(cmd.Run())
			output := buf.String()
			if rc == 0 {
				output = truncateOutput(output, 200)
			}
			return jobResult{output: output, rc: rc}
		})

		return mcp.NewToolResultText(fmt.Sprintf("%s: %s", p.key, status)), nil
	}
}

// transitiveDeps computes the transitive closure of the dependency graph.
func transitiveDeps(depMap map[string][]string) map[string]map[string]bool {
	result := make(map[string]map[string]bool)
	var visit func(key string) map[string]bool
	visit = func(key string) map[string]bool {
		if cached, ok := result[key]; ok {
			return cached
		}
		deps := make(map[string]bool)
		result[key] = deps
		for _, d := range depMap[key] {
			deps[d] = true
			for td := range visit(d) {
				deps[td] = true
			}
		}
		return deps
	}
	for key := range depMap {
		visit(key)
	}
	return result
}

func truncateOutput(output string, maxLines int) string {
	lines := strings.Split(output, "\n")
	if len(lines) <= maxLines {
		return output
	}
	return fmt.Sprintf("... (%d lines truncated)\n", len(lines)-maxLines) +
		strings.Join(lines[len(lines)-maxLines:], "\n")
}

func makeGraphHandler(procs []processEntry, config MultiStepConfig) server.ResourceHandlerFunc {
	return func(ctx context.Context, request mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
		graph := buildDependencyGraph(procs, config)
		data, _ := json.MarshalIndent(graph, "", "  ")
		return []mcp.ResourceContents{
			mcp.TextResourceContents{
				URI:      "localci://graph",
				MIMEType: "application/json",
				Text:     string(data),
			},
		}, nil
	}
}
