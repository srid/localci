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

// jobTracker manages async step executions with dependency ordering.
// Steps whose dependencies haven't passed yet wait internally —
// the agent can fire all tools at once and the tracker handles ordering.
type jobTracker struct {
	mu      sync.Mutex
	queued  map[string]bool         // waiting for deps
	running map[string]chan jobResult
	done    map[string]jobResult
	shas    map[string]string // key → short SHA used
	depMap  map[string][]string
	doneCh  map[string]chan struct{} // closed when step completes (pass or fail)
}

func newJobTracker(depMap map[string][]string, keys []string) *jobTracker {
	doneCh := make(map[string]chan struct{})
	for _, k := range keys {
		doneCh[k] = make(chan struct{})
	}
	return &jobTracker{
		queued:  make(map[string]bool),
		running: make(map[string]chan jobResult),
		done:    make(map[string]jobResult),
		shas:    make(map[string]string),
		depMap:  depMap,
		doneCh:  doneCh,
	}
}

func (jt *jobTracker) start(key, sha string, run func() jobResult) string {
	jt.mu.Lock()
	defer jt.mu.Unlock()

	if _, ok := jt.running[key]; ok {
		return "already running"
	}
	if prev, ok := jt.done[key]; ok && prev.rc == 0 {
		return "already passed"
	}
	// Allow re-running failed steps — reset done channel
	if _, ok := jt.done[key]; ok {
		delete(jt.done, key)
		jt.doneCh[key] = make(chan struct{})
	}

	jt.shas[key] = sha
	ch := make(chan jobResult, 1)
	jt.running[key] = ch

	deps := jt.depMap[key]
	hasDeps := len(deps) > 0
	if hasDeps {
		jt.queued[key] = true
	}

	go func() {
		// Wait for dependencies to complete successfully
		for _, dep := range deps {
			jt.mu.Lock()
			depCh := jt.doneCh[dep]
			jt.mu.Unlock()
			<-depCh

			// Check if dep passed
			jt.mu.Lock()
			depResult, ok := jt.done[dep]
			jt.mu.Unlock()
			if ok && depResult.rc != 0 {
				ch <- jobResult{output: fmt.Sprintf("skipped: dependency %s failed", dep), rc: 1}
				return
			}
		}
		// Transition from queued → running
		if hasDeps {
			jt.mu.Lock()
			delete(jt.queued, key)
			jt.mu.Unlock()
		}
		ch <- run()
	}()

	if hasDeps {
		return fmt.Sprintf("queued (waiting for %s)", strings.Join(deps, ", "))
	}
	return "started"
}

// complete drains a result and marks the step done, closing its doneCh.
func (jt *jobTracker) complete(key string, r jobResult) {
	jt.done[key] = r
	// Close doneCh to unblock dependents
	if ch, ok := jt.doneCh[key]; ok {
		select {
		case <-ch: // already closed
		default:
			close(ch)
		}
	}
}

// pollAll returns a compact single-line status string.
func (jt *jobTracker) pollAll(keys []string) string {
	jt.mu.Lock()
	defer jt.mu.Unlock()

	// If nothing has been started, nudge the agent
	if len(jt.running) == 0 && len(jt.done) == 0 {
		return "NO STEPS STARTED — call individual step tools first, then poll status-all"
	}

	// Drain completed channels
	for key, ch := range jt.running {
		select {
		case r := <-ch:
			delete(jt.running, key)
			jt.complete(key, r)
		default:
		}
	}

	// Collect SHA
	var sha string
	for _, key := range keys {
		if s, ok := jt.shas[key]; ok {
			sha = s
			break
		}
	}

	var parts []string
	allDone := true
	anyFailed := false
	var failedKeys []string

	for _, key := range keys {
		if r, ok := jt.done[key]; ok {
			if r.rc != 0 {
				anyFailed = true
				failedKeys = append(failedKeys, key)
				parts = append(parts, fmt.Sprintf("✗ %s", key))
			} else {
				parts = append(parts, fmt.Sprintf("✓ %s", key))
			}
		} else if jt.queued[key] {
			allDone = false
			parts = append(parts, fmt.Sprintf("◌ %s", key))
		} else if _, ok := jt.running[key]; ok {
			allDone = false
			parts = append(parts, fmt.Sprintf("● %s", key))
		} else {
			allDone = false
			parts = append(parts, fmt.Sprintf("· %s", key))
		}
	}

	var status string
	if allDone {
		if anyFailed {
			status = "FAILED"
		} else {
			status = "ALL PASSED"
		}
	} else {
		status = "IN PROGRESS"
	}

	shaLabel := ""
	if sha != "" {
		shaLabel = " @" + sha
	}

	summary := fmt.Sprintf("%s%s | %s", status, shaLabel, strings.Join(parts, " | "))

	// Append truncated output only for failed steps
	if anyFailed {
		for _, key := range failedKeys {
			if r, ok := jt.done[key]; ok {
				tail := truncateOutput(r.output, 30)
				summary += fmt.Sprintf("\n\n--- %s (exit %d) ---\n%s", key, r.rc, tail)
			}
		}
	}

	return summary
}

// buildMCPServer constructs the MCP server with all tools and resources.
func buildMCPServer() (*server.MCPServer, error) {
	config, err := loadFromJustfile()
	if err != nil {
		return nil, err
	}

	if _, _, err := resolveHosts(config, false); err != nil {
		return nil, err
	}

	self, err := selfPathResolved()
	if err != nil {
		return nil, fmt.Errorf("could not resolve self path: %w", err)
	}

	procs := buildProcessEntries(config)
	depMap := buildDepMap(procs, config)

	var stepKeys []string
	for _, p := range procs {
		stepKeys = append(stepKeys, p.key)
	}
	tracker := newJobTracker(depMap, stepKeys)

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

	// status-all tool
	statusAllTool := mcp.NewTool("status-all",
		mcp.WithDescription("Poll all step statuses. Returns a single-line summary like: IN PROGRESS @sha | ✓ build | ● test | · e2e"),
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

	return s, nil
}

func runMCPServer() int {
	s, err := buildMCPServer()
	if err != nil {
		logErr("%v", err)
		return 1
	}
	if err := server.ServeStdio(s); err != nil {
		logErr("MCP server error: %v", err)
		return 1
	}
	return 0
}

func runMCPHTTPServer(port int) int {
	s, err := buildMCPServer()
	if err != nil {
		logErr("%v", err)
		return 1
	}

	addr := fmt.Sprintf(":%d", port)
	httpServer := server.NewStreamableHTTPServer(s,
		server.WithEndpointPath("/mcp"),
	)

	logMsg("MCP server listening on http://localhost%s/mcp", addr)
	if err := httpServer.Start(addr); err != nil {
		logErr("HTTP server error: %v", err)
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

		short := shortSHA(sha)

		cmdParts := []string{self, "--sha", sha}
		if !isCommitPushed(sha) {
			cmdParts = append(cmdParts, "--no-signoff")
		}
		if p.sys != "" {
			cmdParts = append(cmdParts, "-s", p.sys)
		}
		cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

		status := tracker.start(p.key, short, func() jobResult {
			// Resolve workdir at execution time, not invocation time —
			// queued steps may wait minutes for deps, and the original
			// cwd could be deleted by nix build in the meantime.
			cmd := exec.Command(cmdParts[0], cmdParts[1:]...)
			cmd.Dir = validWorkdir()
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

		return mcp.NewToolResultText(fmt.Sprintf("%s: %s @%s", p.key, status, short)), nil
	}
}

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
