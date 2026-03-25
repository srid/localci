package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// runMCPServer starts an MCP server over stdio, exposing each step as a
// tool and the dependency graph as a resource. Agents read the graph to
// determine which tools can be called in parallel.
func runMCPServer(args cliArgs) int {
	config, err := loadConfig(args.configFile)
	if err != nil {
		logErr("%v", err)
		return 1
	}

	cwd, _ := os.Getwd()

	// Resolve and warm SSH connections upfront — tool handlers can't prompt.
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

	s := server.NewMCPServer("localci", "0.1.0")

	// "run-all" tool: runs the entire DAG with parallelization
	runAllTool := mcp.NewTool("run-all",
		mcp.WithDescription("Run all CI steps in parallel (respecting dependencies)"),
		mcp.WithString("sha",
			mcp.Description("Git ref to test (default: HEAD)"),
		),
	)
	s.AddTool(runAllTool, makeRunAllHandler(self, cwd, args.configFile, args.noSignoff))

	// Individual step tools for targeted runs
	for _, p := range procs {
		step := config.Steps[p.step]
		tool := mcp.NewTool(p.key,
			mcp.WithDescription(fmt.Sprintf("Run single CI step: %s", step.Command)),
			mcp.WithString("sha",
				mcp.Description("Git ref to test (default: HEAD)"),
			),
		)
		s.AddTool(tool, makeStepHandler(p, step, self, cwd, args.noSignoff))
	}

	// Register dependency graph resource
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

func makeRunAllHandler(self, cwd, configFile string, noSignoff bool) server.ToolHandlerFunc {
	return func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		sha := request.GetString("sha", "HEAD")

		resolved, err := resolveRef(sha)
		if err == nil {
			sha = resolved
		}

		cmdParts := []string{self, "--sha", sha, "-f", configFile}
		if noSignoff {
			cmdParts = append(cmdParts, "--no-signoff")
		}

		// Use os.Pipe so we can stream progress notifications to the client
		pr, pw, err := os.Pipe()
		if err != nil {
			return mcp.NewToolResultError("failed to create pipe"), nil
		}

		cmd := exec.CommandContext(ctx, cmdParts[0], cmdParts[1:]...)
		cmd.Dir = cwd
		cmd.Stdout = pw
		cmd.Stderr = pw

		if err := cmd.Start(); err != nil {
			pw.Close()
			pr.Close()
			return mcp.NewToolResultError(fmt.Sprintf("failed to start: %v", err)), nil
		}
		pw.Close()

		srv := server.ServerFromContext(ctx)
		var output strings.Builder
		scanner := bufio.NewScanner(pr)
		scanner.Buffer(make([]byte, 0, 256*1024), 256*1024)
		for scanner.Scan() {
			line := scanner.Text()
			output.WriteString(line)
			output.WriteByte('\n')

			// Send progress notifications for key events
			if srv != nil && (strings.Contains(line, "passed") ||
				strings.Contains(line, "failed") ||
				strings.Contains(line, "Running") ||
				strings.Contains(line, "Skipped") ||
				strings.Contains(line, "All steps")) {
				srv.SendNotificationToClient(ctx, "notifications/message", map[string]any{
					"level": "info",
					"data":  line,
				})
			}
		}
		pr.Close()

		rc := exitCode(cmd.Wait())
		result := truncateOutput(output.String(), 200)

		if rc != 0 {
			return mcp.NewToolResultText(fmt.Sprintf("FAILED (exit %d)\n\n%s", rc, result)), nil
		}
		return mcp.NewToolResultText(result), nil
	}
}

func makeStepHandler(
	p processEntry, step StepConfig,
	self, cwd string,
	noSignoff bool,
) server.ToolHandlerFunc {
	return func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		sha := request.GetString("sha", "HEAD")

		// Resolve ref to full SHA
		resolved, err := resolveRef(sha)
		if err == nil {
			sha = resolved
		}

		cmdParts := []string{self, "--sha", sha}
		if noSignoff {
			cmdParts = append(cmdParts, "--no-signoff")
		}
		if p.sys != "" {
			cmdParts = append(cmdParts, "-s", p.sys)
		}
		cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

		cmd := exec.CommandContext(ctx, cmdParts[0], cmdParts[1:]...)
		cmd.Dir = cwd
		var buf bytes.Buffer
		cmd.Stdout = &buf
		cmd.Stderr = &buf
		rc := exitCode(cmd.Run())

		output := truncateOutput(buf.String(), 200)

		if rc != 0 {
			return mcp.NewToolResultText(fmt.Sprintf("FAILED (exit %d)\n\n%s", rc, output)), nil
		}
		return mcp.NewToolResultText(output), nil
	}
}

// truncateOutput keeps the last maxLines of output, prepending a truncation notice.
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
