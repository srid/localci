package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/fatih/color"
	"github.com/rodaine/table"
)

// StepConfig represents a step in the multi-step config file (localci.json).
// Each step has a command and optionally targets specific Nix systems.
type StepConfig struct {
	Command   string   `json:"command"`
	Systems   []string `json:"systems,omitempty"`
	DependsOn []string `json:"depends_on,omitempty"`
}

// MultiStepConfig is the top-level config file structure.
type MultiStepConfig struct {
	Steps map[string]StepConfig `json:"steps"`
}

// loadConfig reads and parses a localci JSON config file.
func loadConfig(path string) (MultiStepConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return MultiStepConfig{}, fmt.Errorf("config file not found: %s", path)
		}
		return MultiStepConfig{}, err
	}
	var config MultiStepConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return MultiStepConfig{}, fmt.Errorf("failed to parse config: %w", err)
	}
	return config, nil
}

// Process-compose config types. We generate a JSON config file and hand it
// to process-compose for parallel step orchestration with dependency ordering.
type pcConfig struct {
	Version          string               `json:"version"`
	LogConfiguration pcLogConfig          `json:"log_configuration"`
	MCPServer        *pcMCPServer         `json:"mcp_server,omitempty"`
	Processes        map[string]pcProcess `json:"processes"`
}

type pcMCPServer struct {
	Transport string `json:"transport"`
}

type pcLogConfig struct {
	FlushEachLine bool `json:"flush_each_line"`
}

type pcProcess struct {
	Command      string                    `json:"command"`
	WorkingDir   string                    `json:"working_dir"`
	LogLocation  string                    `json:"log_location"`
	Namespace    string                    `json:"namespace,omitempty"`
	Availability *pcAvailability           `json:"availability,omitempty"`
	Shutdown     *pcShutdown               `json:"shutdown,omitempty"`
	DependsOn    map[string]pcDependency   `json:"depends_on,omitempty"`
	Disabled     bool                      `json:"disabled,omitempty"`
	MCP          *pcMCP                    `json:"mcp,omitempty"`
}

// pcShutdown configures how process-compose terminates a process.
// signal 9 (SIGKILL) ensures immediate termination — nix build and
// similar tools often ignore SIGTERM, causing the TUI to hang on
// "Terminating".
type pcShutdown struct {
	Signal int `json:"signal"`
}

type pcMCP struct {
	Type string `json:"type"`
}

type pcAvailability struct {
	Restart string `json:"restart"`
}

type pcDependency struct {
	Condition string `json:"condition"`
}

// processEntry tracks a step×system combination and its process-compose key.
type processEntry struct {
	step string
	sys  string // empty if no systems defined
	key  string // process-compose process name
}

// runMultiStep reads a JSON config defining steps (with optional systems and
// dependencies), resolves remote hosts, extracts the repo to each target,
// generates a process-compose config, and runs all steps in parallel.
// Each step self-invokes localci in single-step mode with --sha pinning.
func runMultiStep(args cliArgs, sha string) int {
	config, err := loadConfig(args.configFile)
	if err != nil {
		logErr("%v", err)
		return 1
	}

	logMsg("Multi-step mode: %s  %s", cBold(args.configFile), cDim("SHA="+shortSHA(sha)))

	currentSystem := getCurrentSystem()
	cwd, _ := os.Getwd()

	// Collect all unique systems from config
	allSystems := collectSystems(config)

	// Resolve remote hosts upfront — process-compose subprocesses can't
	// prompt for hostnames, so we do it here while we still have a TTY.
	hostMap := map[string]string{currentSystem: mustHostname()}
	for _, sys := range allSystems {
		if sys != currentSystem {
			host, err := getRemoteHost(sys)
			if err != nil {
				logErr("Failed to get host for %s: %v", sys, err)
				return 1
			}
			hostMap[sys] = host
			// Warm SSH connection
			logMsg("Warming SSH connection to %s (%s)...", cBold(host), sys)
			exec.Command("ssh", host, "echo", "ok").Run()
		}
	}

	workdirMap := make(map[string]string)
	var localDir string

	if args.mcp {
		// MCP mode: skip pre-extraction. Each tool invocation resolves HEAD
		// fresh and extracts its own archive. This ensures agents always run
		// against the current commit, not a stale one from server startup.
	} else {
		// Normal mode: pre-extract repo once per system for efficiency
		workdirBase := fmt.Sprintf("/tmp/localci-%s", shortSHA(sha))

		localDir = workdirBase + "-local"
		logMsg("Extracting repo (local)...")
		if err := extractRepoLocal(sha, localDir); err != nil {
			logErr("Failed to extract repo locally: %v", err)
			return 1
		}
		workdirMap[currentSystem] = localDir

		for _, sys := range allSystems {
			if sys != currentSystem {
				host := hostMap[sys]
				rdir := fmt.Sprintf("%s-%s", workdirBase, sys)
				logMsg("Extracting repo on %s (%s)...", cBold(host), sys)
				if err := extractRepoRemote(sha, host, rdir); err != nil {
					logErr("Failed to extract repo on %s: %v", host, err)
					return 1
				}
				workdirMap[sys] = rdir
			}
		}
	}

	logDir := fmt.Sprintf("/tmp/localci-%s-logs", shortSHA(sha))
	os.MkdirAll(logDir, 0o755)

	// Build process entries (step × system matrix)
	procs := buildProcessEntries(config)

	// Resolve self path
	self, err := selfPathResolved()
	if err != nil {
		logErr("Could not resolve self path: %v", err)
		return 1
	}

	// Generate process-compose config
	pcCfg := generatePCConfig(procs, config, sha, self, cwd, logDir, hostMap, workdirMap, args.mcp, args.noSignoff)

	// Write process-compose config to temp file
	pcFile, err := os.CreateTemp("", "localci-pc-*.json")
	if err != nil {
		logErr("Failed to create temp file: %v", err)
		return 1
	}
	defer os.Remove(pcFile.Name())

	enc := json.NewEncoder(pcFile)
	enc.SetIndent("", "  ")
	if err := enc.Encode(pcCfg); err != nil {
		logErr("Failed to write process-compose config: %v", err)
		return 1
	}
	pcFile.Close()

	// Run process-compose
	pcArgs := []string{"up", "--config", pcFile.Name()}
	if args.mcp {
		// MCP mode: stdio transport. --no-server disables the HTTP API
		// (which would conflict on port 8080); MCP uses stdio instead.
		pcArgs = append(pcArgs, "--tui=false", "--no-server")
	} else {
		pcArgs = append(pcArgs, "--tui="+strconv.FormatBool(args.tui), "--no-server")
	}
	pcCmd := exec.Command("process-compose", pcArgs...)
	pcCmd.Stdout = os.Stdout
	pcCmd.Stderr = os.Stderr
	pcCmd.Stdin = os.Stdin
	pcExit := exitCode(pcCmd.Run())

	// Cleanup temp dirs. Keep log dir on failure for debugging.
	if pcExit == 0 {
		os.RemoveAll(logDir)
	}
	if !args.mcp {
		workdirBase := fmt.Sprintf("/tmp/localci-%s", shortSHA(sha))
		os.RemoveAll(localDir)
		for _, sys := range allSystems {
			if sys != currentSystem {
				host := hostMap[sys]
				rdir := fmt.Sprintf("%s-%s", workdirBase, sys)
				exec.Command("ssh", host, "rm -rf '"+rdir+"'").Run()
			}
		}
	}

	// Print summary (skip in MCP mode — agent reads structured MCP responses)
	if !args.mcp {
		fmt.Fprintln(os.Stderr)
		if pcExit == 0 {
			logOk("All steps passed")
		} else {
			logWarn("One or more steps failed (exit %d)", pcExit)
			printStepReport(logDir)
			logInfo("Full logs: %s/", logDir)
		}
	}

	return pcExit
}

func collectSystems(config MultiStepConfig) []string {
	seen := make(map[string]bool)
	var systems []string
	for _, step := range config.Steps {
		for _, sys := range step.Systems {
			if !seen[sys] {
				seen[sys] = true
				systems = append(systems, sys)
			}
		}
	}
	return systems
}

// buildProcessEntries expands the step×system matrix into individual
// process entries. Each entry gets a unique key for process-compose:
// just the step name when there's one system, "step (system)" when multiple.
func buildProcessEntries(config MultiStepConfig) []processEntry {
	var procs []processEntry
	for stepName, step := range config.Steps {
		systems := step.Systems
		if len(systems) == 0 {
			systems = []string{""} // no-system sentinel
		}
		for _, sys := range systems {
			key := stepName
			if sys != "" && len(step.Systems) > 1 {
				key = fmt.Sprintf("%s (%s)", stepName, sys)
			}
			procs = append(procs, processEntry{step: stepName, sys: sys, key: key})
		}
	}
	return procs
}

// generatePCConfig builds the process-compose JSON config. Each process
// is a self-invocation of localci in single-step mode with --sha pinning.
// Dependencies are resolved per-system: step B on x86_64-linux waits for
// step A on x86_64-linux, not step A on aarch64-darwin.
func generatePCConfig(
	procs []processEntry, config MultiStepConfig,
	sha, self, cwd, logDir string,
	hostMap, workdirMap map[string]string,
	mcpMode, noSignoff bool,
) pcConfig {
	processes := make(map[string]pcProcess)

	for _, p := range procs {
		step := config.Steps[p.step]

		// In MCP mode, use "HEAD" so each invocation resolves the current
		// commit fresh. In normal mode, use the pre-resolved SHA with
		// --workdir for efficiency.
		stepSHA := sha
		if mcpMode {
			stepSHA = "HEAD"
		}
		cmdParts := []string{self, "--sha", stepSHA}
		if noSignoff {
			cmdParts = append(cmdParts, "--no-signoff")
		}
		if p.sys != "" {
			cmdParts = append(cmdParts, "-s", p.sys)
			if !mcpMode {
				if dir, ok := workdirMap[p.sys]; ok {
					cmdParts = append(cmdParts, "--workdir", dir)
				}
			}
		}
		cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

		// Resolve dependencies: match by step name + same system
		var depends map[string]pcDependency
		for _, dep := range step.DependsOn {
			for _, dp := range procs {
				if dp.step == dep && dp.sys == p.sys {
					if depends == nil {
						depends = make(map[string]pcDependency)
					}
					depends[dp.key] = pcDependency{Condition: "process_completed_successfully"}
					break
				}
			}
		}

		proc := pcProcess{
			Command:     strings.Join(cmdParts, " "),
			WorkingDir:  cwd,
			LogLocation: filepath.Join(logDir, sanitizeLogName(p.key)+".log"),
			Shutdown:    &pcShutdown{Signal: 9},
			DependsOn:   depends,
		}
		if mcpMode {
			proc.Disabled = true
			proc.MCP = &pcMCP{Type: "tool"}
		} else {
			proc.Availability = &pcAvailability{Restart: "exit_on_failure"}
		}
		if p.sys != "" {
			hostname := hostMap[p.sys]
			if hostname == "" {
				hostname = "local"
			}
			proc.Namespace = fmt.Sprintf("%s (%s) @%s", p.sys, hostname, shortSHA(sha))
		} else {
			proc.Namespace = "@" + shortSHA(sha)
		}

		processes[p.key] = proc

		// In MCP mode, add a companion resource to read each step's log file
		if mcpMode {
			logFile := filepath.Join(logDir, sanitizeLogName(p.key)+".log")
			processes[p.key+" logs"] = pcProcess{
				Command:    fmt.Sprintf("cat '%s' 2>/dev/null || echo 'No logs yet (step has not run)'", logFile),
				WorkingDir: cwd,
				Disabled:   true,
				MCP:        &pcMCP{Type: "resource"},
			}
		}
	}

	cfg := pcConfig{
		Version:          "0.5",
		LogConfiguration: pcLogConfig{FlushEachLine: true},
		Processes:        processes,
	}
	if mcpMode {
		cfg.MCPServer = &pcMCPServer{Transport: "stdio"}
	}
	return cfg
}

// parseProcessKey splits "step (system)" into step and system parts.
// Returns (name, "") if no system suffix.
func parseProcessKey(key string) (string, string) {
	if idx := strings.LastIndex(key, " ("); idx != -1 && strings.HasSuffix(key, ")") {
		return key[:idx], key[idx+2 : len(key)-1]
	}
	return key, ""
}

var logNameReplacer = strings.NewReplacer("/", "-", " ", "-", "(", "-", ")", "-")
var multiDash = regexp.MustCompile(`-{2,}`)

func sanitizeLogName(name string) string {
	s := logNameReplacer.Replace(name)
	s = multiDash.ReplaceAllString(s, "-")
	return strings.TrimRight(s, "-")
}

// selfPathResolved returns the real path to this executable, following
// symlinks. Needed because nix wraps the binary and we need the wrapper
// path for self-invocation in multi-step mode.
func selfPathResolved() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

func mustHostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "local"
	}
	return h
}

// stepLog holds parsed info from a process-compose log file.
type stepLog struct {
	name     string // process-compose key, e.g. "nix (x86_64-linux)"
	failed   bool
	messages []string
}

// parseStepLogs reads all log files and extracts step status and messages.
func parseStepLogs(logDir string) []stepLog {
	paths, _ := filepath.Glob(filepath.Join(logDir, "*.log"))
	var logs []stepLog
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil || len(data) == 0 {
			continue
		}
		sl := stepLog{}
		for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
			var entry struct {
				Process string `json:"process"`
				Message string `json:"message"`
			}
			if json.Unmarshal([]byte(line), &entry) == nil {
				// Use the process field from the first log entry as the name
				if sl.name == "" && entry.Process != "" {
					sl.name = entry.Process
				}
				if entry.Message != "" {
					sl.messages = append(sl.messages, entry.Message)
					if strings.Contains(entry.Message, "failed") {
						sl.failed = true
					}
				}
			}
		}
		if sl.name == "" {
			sl.name = strings.TrimSuffix(filepath.Base(path), ".log")
		}
		logs = append(logs, sl)
	}
	return logs
}

// printStepReport prints a summary table of step results and the tail
// of output for failed steps.
func printStepReport(logDir string) {
	logs := parseStepLogs(logDir)
	if len(logs) == 0 {
		return
	}

	// Summary table
	headerFmt := color.New(color.FgWhite, color.Bold).SprintfFunc()
	passFmt := color.New(color.FgGreen).SprintfFunc()
	failFmt := color.New(color.FgRed, color.Bold).SprintfFunc()

	// Check if any step has a system (name contains " (system)")
	hasSystems := false
	for _, sl := range logs {
		if strings.Contains(sl.name, " (") {
			hasSystems = true
			break
		}
	}

	if hasSystems {
		tbl := table.New("Step", "System", "Status")
		tbl.WithHeaderFormatter(headerFmt).WithWriter(os.Stderr)
		for _, sl := range logs {
			step, sys := parseProcessKey(sl.name)
			status := passFmt("pass")
			if sl.failed {
				status = failFmt("FAIL")
			}
			tbl.AddRow(step, sys, status)
		}
		tbl.Print()
	} else {
		tbl := table.New("Step", "Status")
		tbl.WithHeaderFormatter(headerFmt).WithWriter(os.Stderr)
		for _, sl := range logs {
			status := passFmt("pass")
			if sl.failed {
				status = failFmt("FAIL")
			}
			tbl.AddRow(sl.name, status)
		}
		tbl.Print()
	}

	// Tail of failed step output
	const tailLines = 20
	for _, sl := range logs {
		if !sl.failed {
			continue
		}
		fmt.Fprintln(os.Stderr)
		logWarn("%s:", cBold(sl.name))
		start := 0
		if len(sl.messages) > tailLines {
			start = len(sl.messages) - tailLines
			logInfo("... (%d lines omitted)", start)
		}
		for _, msg := range sl.messages[start:] {
			fmt.Fprintf(os.Stderr, "    %s\n", msg)
		}
	}
}
