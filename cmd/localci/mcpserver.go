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

// jobTracker manages async step executions.
type jobTracker struct {
	mu      sync.Mutex
	running map[string]chan jobResult
	done    map[string]jobResult
	shas    map[string]string // key → short SHA used
}

func newJobTracker() *jobTracker {
	return &jobTracker{
		running: make(map[string]chan jobResult),
		done:    make(map[string]jobResult),
		shas:    make(map[string]string),
	}
}

func (jt *jobTracker) start(key, sha string, run func() jobResult) string {
	jt.mu.Lock()
	defer jt.mu.Unlock()

	if _, ok := jt.running[key]; ok {
		return "already running"
	}
	if _, ok := jt.done[key]; ok {
		return "already completed"
	}

	jt.shas[key] = sha
	ch := make(chan jobResult, 1)
	jt.running[key] = ch
	go func() {
		ch <- run()
	}()
	return "started"
}

// pollAll returns a compact single-line status string.
// Format: "IN PROGRESS @abc123 | ✓ build | ● test | · e2e"
// When done with failures, appends failure output after the summary line.
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

	// If nothing has been started, nudge the agent
	if len(jt.running) == 0 && len(jt.done) == 0 {
		return "NO STEPS STARTED — call individual step tools first, then poll status-all"
	}

	// Collect SHA (all steps should use the same one, pick first available)
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

	if _, _, err := resolveHosts(config); err != nil {
		return nil, err
	}

	self, err := selfPathResolved()
	if err != nil {
		return nil, fmt.Errorf("could not resolve self path: %w", err)
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

	// status-all tool
	var stepKeys []string
	for _, p := range procs {
		stepKeys = append(stepKeys, p.key)
	}
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
		cwd := validWorkdir()

		cmdParts := []string{self, "--sha", sha}
		if !isCommitPushed(sha) {
			cmdParts = append(cmdParts, "--no-signoff")
		}
		if p.sys != "" {
			cmdParts = append(cmdParts, "-s", p.sys)
		}
		cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

		status := tracker.start(p.key, short, func() jobResult {
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
