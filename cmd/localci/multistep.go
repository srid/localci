package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/fatih/color"
	"github.com/mattn/go-isatty"
	"github.com/rodaine/table"
	"golang.org/x/term"
)

// StepConfig represents a CI step parsed from a justfile ci module.
type StepConfig struct {
	Command   string   // "just ci::<recipe>"
	Systems   []string // from [metadata("systems", ...)]
	DependsOn []string // from [metadata("depends_on", ...)]
}

// MultiStepConfig holds all CI steps.
type MultiStepConfig struct {
	Steps map[string]StepConfig
}

// justfile JSON dump types (subset we parse from `just --dump --dump-format json`)
type justDump struct {
	Modules map[string]justModule `json:"modules"`
}

type justModule struct {
	Recipes map[string]justRecipe `json:"recipes"`
}

type justRecipe struct {
	Attributes []map[string][]string `json:"attributes"`
}

// loadFromJustfile runs `just --dump --dump-format json` and extracts CI
// steps from the "ci" module's recipes. Metadata attributes encode systems
// and dependencies; the command is `just ci::<recipe>`.
func loadFromJustfile() (MultiStepConfig, error) {
	out, err := exec.Command("just", "--dump", "--dump-format", "json").Output()
	if err != nil {
		return MultiStepConfig{}, fmt.Errorf("failed to run just --dump: %w", err)
	}

	var dump justDump
	if err := json.Unmarshal(out, &dump); err != nil {
		return MultiStepConfig{}, fmt.Errorf("failed to parse just dump: %w", err)
	}

	ciModule, ok := dump.Modules["ci"]
	if !ok {
		return MultiStepConfig{}, fmt.Errorf("no 'ci' module found in justfile (add 'mod ci' and create ci.just)")
	}

	steps := make(map[string]StepConfig)
	for name, recipe := range ciModule.Recipes {
		if name == "default" {
			continue
		}
		step := StepConfig{
			Command: fmt.Sprintf("just ci::%s", name),
		}
		for _, attr := range recipe.Attributes {
			if vals, ok := attr["metadata"]; ok && len(vals) >= 2 {
				switch vals[0] {
				case "systems":
					step.Systems = append(step.Systems, vals[1:]...)
				case "depends_on":
					step.DependsOn = append(step.DependsOn, vals[1:]...)
				}
			}
		}
		steps[name] = step
	}

	if len(steps) == 0 {
		return MultiStepConfig{}, fmt.Errorf("ci module has no recipes")
	}

	return MultiStepConfig{Steps: steps}, nil
}

// processEntry tracks a step×system combination and its unique key.
type processEntry struct {
	step string
	sys  string // empty if no systems defined
	key  string // "step" or "step (system)"
}

// resolveHosts resolves and warms SSH connections for all remote systems.
// When allowPrompt is false (MCP mode), errors instead of prompting for uncached hosts.
func resolveHosts(config MultiStepConfig, allowPrompt bool) (hostMap map[string]string, allSystems []string, err error) {
	currentSystem := getCurrentSystem()
	allSystems = collectSystems(config)
	hostMap = map[string]string{currentSystem: mustHostname()}
	for _, sys := range allSystems {
		if sys != currentSystem {
			var host string
			if allowPrompt {
				host, err = getRemoteHost(sys)
			} else {
				host, err = getRemoteHostCached(sys)
			}
			if err != nil {
				return nil, nil, fmt.Errorf("failed to get host for %s: %w", sys, err)
			}
			hostMap[sys] = host
			logMsg("Warming SSH connection to %s (%s)...", cBold(host), sys)
			exec.Command("ssh", host, "echo", "ok").Run()
		}
	}
	return hostMap, allSystems, nil
}

// runMultiStep loads CI steps from the justfile ci module, resolves remote
// hosts, extracts the repo to each target, and runs all steps in parallel
// using a native DAG executor. Each step self-invokes localci in single-step
// mode with --sha pinning.
func runMultiStep(args cliArgs, sha string) int {
	config, err := loadFromJustfile()
	if err != nil {
		logErr("%v", err)
		return 1
	}

	logMsg("Multi-step mode: %s  %s", cBold("justfile ci module"), cDim("SHA="+shortSHA(sha)))

	currentSystem := getCurrentSystem()
	cwd, _ := os.Getwd()

	hostMap, allSystems, err := resolveHosts(config, true)
	if err != nil {
		logErr("%v", err)
		return 1
	}

	// Pre-extract repo once per system for efficiency
	workdirBase := fmt.Sprintf("/tmp/localci-%s", shortSHA(sha))
	workdirMap := make(map[string]string)

	localDir := workdirBase + "-local"
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

	logDir := fmt.Sprintf("/tmp/localci-%s-logs", shortSHA(sha))
	os.RemoveAll(logDir)
	os.MkdirAll(logDir, 0o755)

	procs := buildProcessEntries(config)
	writeManifest(logDir, procs)

	self, err := selfPathResolved()
	if err != nil {
		logErr("Could not resolve self path: %v", err)
		return 1
	}

	tobs := newTerminalObserver(procs)

	exitCode := runDAG(procs, config, sha, self, cwd, logDir, hostMap, workdirMap, args.noSignoff, tobs)
	tobs.done()

	// Cleanup
	if exitCode == 0 {
		os.RemoveAll(logDir)
	}
	os.RemoveAll(localDir)
	for _, sys := range allSystems {
		if sys != currentSystem {
			host := hostMap[sys]
			rdir := fmt.Sprintf("%s-%s", workdirBase, sys)
			exec.Command("ssh", host, "rm -rf '"+rdir+"'").Run()
		}
	}

	fmt.Fprintln(os.Stderr)
	if exitCode == 0 {
		logOk("All steps passed")
	} else {
		logWarn("One or more steps failed (exit %d)", exitCode)
		printStepReport(logDir)
		logInfo("Full logs: %s/", logDir)
	}

	return exitCode
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
// process entries.
func buildProcessEntries(config MultiStepConfig) []processEntry {
	var procs []processEntry
	for stepName, step := range config.Steps {
		systems := step.Systems
		if len(systems) == 0 {
			systems = []string{""} // no-system sentinel
		}
		for _, sys := range systems {
			key := stepName
			if sys != "" {
				key = fmt.Sprintf("%s (%s)", stepName, sys)
			}
			procs = append(procs, processEntry{step: stepName, sys: sys, key: key})
		}
	}
	return procs
}

// buildDepMap builds a map from process key → list of dependency keys.
func buildDepMap(procs []processEntry, config MultiStepConfig) map[string][]string {
	depMap := make(map[string][]string)
	for _, p := range procs {
		step := config.Steps[p.step]
		for _, dep := range step.DependsOn {
			for _, dp := range procs {
				if dp.step == dep && dp.sys == p.sys {
					depMap[p.key] = append(depMap[p.key], dp.key)
					break
				}
			}
		}
	}
	return depMap
}

// ── DAG executor ────────────────────────────────────────────────────────────

type stepState int

const (
	stateWaiting stepState = iota
	stateRunning
	stateDone
	stateFailed
	stateSkipped
)

// runDAG runs all steps in dependency order using goroutines.
// Independent steps run concurrently; a failed step causes its
// dependents to be skipped.
func runDAG(
	procs []processEntry, config MultiStepConfig,
	sha, self, cwd, logDir string,
	hostMap, workdirMap map[string]string,
	noSignoff bool,
	tobs *terminalObserver,
) int {
	depMap := buildDepMap(procs, config)

	// Channel per process: closed when that process is done
	doneCh := make(map[string]chan struct{})
	results := make(map[string]int) // exit codes
	var mu sync.Mutex

	for _, p := range procs {
		doneCh[p.key] = make(chan struct{})
	}

	// Build prefix formatter once — shared by all goroutines for aligned output
	pf := newPrefixFormatter(procs)

	var wg sync.WaitGroup
	for _, p := range procs {
		wg.Add(1)
		go func(p processEntry) {
			defer wg.Done()

			// Wait for dependencies to pass before running
			for _, dep := range depMap[p.key] {
				<-doneCh[dep]
				mu.Lock()
				depRC := results[dep]
				mu.Unlock()
				if depRC != 0 {
					mu.Lock()
					results[p.key] = 1
					mu.Unlock()
					tobs.update(p.key, stateSkipped)
					close(doneCh[p.key])
					return
				}
			}

			tobs.update(p.key, stateRunning)

			// Build the self-invocation command for this step
			step := config.Steps[p.step]
			cmdParts := []string{self, "--sha", sha}
			if noSignoff {
				cmdParts = append(cmdParts, "--no-signoff")
			}
			if p.sys != "" {
				cmdParts = append(cmdParts, "-s", p.sys)
				if dir, ok := workdirMap[p.sys]; ok {
					cmdParts = append(cmdParts, "--workdir", dir)
				}
			}
			cmdParts = append(cmdParts, "-n", p.step, "--", step.Command)

			logFile := filepath.Join(logDir, sanitizeLogName(p.key)+".log")

			cmd := exec.Command(cmdParts[0], cmdParts[1:]...)
			cmd.Dir = cwd

			prefix := pf.format(p)

			pr, pw, _ := os.Pipe()
			cmd.Stdout = pw
			cmd.Stderr = pw

			lf, _ := os.Create(logFile)

			var streamWg sync.WaitGroup
			streamWg.Add(1)
			go func() {
				defer streamWg.Done()
				scanner := bufio.NewScanner(pr)
				for scanner.Scan() {
					line := scanner.Text()
					if lf != nil {
						fmt.Fprintf(lf, "%s\n", line)
					}
					tobs.writeLine(fmt.Sprintf("%s %s", prefix, line))
				}
			}()

			rc := exitCode(cmd.Run())
			pw.Close()
			streamWg.Wait()
			pr.Close()
			if lf != nil {
				lf.Close()
			}

			mu.Lock()
			results[p.key] = rc
			mu.Unlock()

			if rc == 0 {
				tobs.update(p.key, stateDone)
			} else {
				tobs.update(p.key, stateFailed)
			}
			close(doneCh[p.key])
		}(p)
	}

	wg.Wait()

	// Compute overall exit: 1 if any failed/skipped
	for _, rc := range results {
		if rc != 0 {
			return 1
		}
	}
	return 0
}

// ── Terminal observer ──────────────────────────────────────────────────────

// palette of distinct colors for step/system prefixes.
var palette = []color.Attribute{
	color.FgCyan,
	color.FgMagenta,
	color.FgBlue,
	color.FgYellow,
	color.FgGreen,
	color.FgHiCyan,
	color.FgHiMagenta,
	color.FgHiBlue,
}

func colorFor(name string) *color.Color {
	h := fnv.New32a()
	h.Write([]byte(name))
	return color.New(palette[int(h.Sum32())%len(palette)])
}

type prefixFormatter struct {
	maxStep int
	maxSys  int
}

func newPrefixFormatter(procs []processEntry) prefixFormatter {
	var pf prefixFormatter
	for _, p := range procs {
		if len(p.step) > pf.maxStep {
			pf.maxStep = len(p.step)
		}
		if len(p.sys) > pf.maxSys {
			pf.maxSys = len(p.sys)
		}
	}
	return pf
}

func (pf prefixFormatter) format(p processEntry) string {
	stepC := colorFor(p.step)
	padded := fmt.Sprintf("%-*s", pf.maxStep, p.step)
	if pf.maxSys == 0 {
		return stepC.Sprintf("[%s]", padded)
	}
	sysC := colorFor(p.sys)
	sysPadded := fmt.Sprintf("%-*s", pf.maxSys, p.sys)
	return stepC.Sprintf("[%s]", padded) + " " + sysC.Sprintf("[%s]", sysPadded)
}

// terminalObserver manages the status bar and output streaming.
type terminalObserver struct {
	mu     sync.Mutex
	procs  []processEntry
	states map[string]stepState
	isTTY  bool
}

func newTerminalObserver(procs []processEntry) *terminalObserver {
	return &terminalObserver{
		procs:  procs,
		states: make(map[string]stepState),
		isTTY:  isatty.IsTerminal(os.Stderr.Fd()),
	}
}

func (t *terminalObserver) update(key string, state stepState) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.states[key] = state
	if t.isTTY {
		t.renderStatusBar()
	}
}

func (t *terminalObserver) writeLine(line string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.isTTY {
		// Clear status bar, write line, re-render
		fmt.Fprintf(os.Stderr, "\033[2K\r%s\n", line)
		t.renderStatusBar()
	} else {
		fmt.Fprintln(os.Stderr, line)
	}
}

func (t *terminalObserver) renderStatusBar() {
	width, _, _ := term.GetSize(int(os.Stderr.Fd()))
	if width == 0 {
		width = 80
	}

	var parts []string
	for _, p := range t.procs {
		state := t.states[p.key]
		var sym string
		switch state {
		case stateWaiting:
			sym = "·"
		case stateRunning:
			sym = color.YellowString("●")
		case stateDone:
			sym = color.GreenString("✓")
		case stateFailed:
			sym = color.RedString("✗")
		case stateSkipped:
			sym = color.HiBlackString("○")
		}
		label := p.step
		if p.sys != "" {
			label += "/" + p.sys
		}
		parts = append(parts, sym+" "+label)
	}

	bar := strings.Join(parts, "  ")
	if len(bar) > width {
		bar = bar[:width]
	}
	fmt.Fprintf(os.Stderr, "\033[2K\r%s", bar)
}

func (t *terminalObserver) done() {
	if t.isTTY {
		fmt.Fprintf(os.Stderr, "\033[2K\r") // Clear status bar
	}
}

// ── Shared helpers ──────────────────────────────────────────────────────────

var logNameReplacer = strings.NewReplacer("/", "-", " ", "-", "(", "-", ")", "-")
var multiDash = regexp.MustCompile(`-{2,}`)

func sanitizeLogName(name string) string {
	s := logNameReplacer.Replace(name)
	s = multiDash.ReplaceAllString(s, "-")
	return strings.TrimRight(s, "-")
}

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

type manifestEntry struct {
	Key     string `json:"key"`
	Step    string `json:"step"`
	System  string `json:"system,omitempty"`
	LogFile string `json:"log_file"`
}

func writeManifest(logDir string, procs []processEntry) {
	var entries []manifestEntry
	for _, p := range procs {
		entries = append(entries, manifestEntry{
			Key:     p.key,
			Step:    p.step,
			System:  p.sys,
			LogFile: filepath.Join(logDir, sanitizeLogName(p.key)+".log"),
		})
	}
	data, _ := json.MarshalIndent(entries, "", "  ")
	os.WriteFile(filepath.Join(logDir, "manifest.json"), data, 0o644)
}

type stepResult struct {
	step     string
	system   string
	failed   bool
	messages []string
}

func loadStepResults(logDir string) []stepResult {
	data, err := os.ReadFile(filepath.Join(logDir, "manifest.json"))
	if err != nil {
		return nil
	}
	var entries []manifestEntry
	if json.Unmarshal(data, &entries) != nil {
		return nil
	}

	var results []stepResult
	for _, e := range entries {
		sr := stepResult{step: e.Step, system: e.System}
		logData, err := os.ReadFile(e.LogFile)
		if err != nil || len(logData) == 0 {
			sr.failed = true // no log = didn't run or crashed
			results = append(results, sr)
			continue
		}
		lines := strings.Split(strings.TrimSpace(string(logData)), "\n")
		sr.messages = lines
		// Check last few lines for failure indicators
		for _, line := range lines {
			if strings.Contains(line, "failed") || strings.Contains(line, "FAIL") {
				sr.failed = true
			}
		}
		results = append(results, sr)
	}
	return results
}

func printStepReport(logDir string) {
	results := loadStepResults(logDir)
	if len(results) == 0 {
		return
	}

	headerFmt := color.New(color.FgWhite, color.Bold).SprintfFunc()
	passFmt := color.New(color.FgGreen).SprintfFunc()
	failFmt := color.New(color.FgRed, color.Bold).SprintfFunc()

	hasSystems := false
	for _, r := range results {
		if r.system != "" {
			hasSystems = true
			break
		}
	}

	fmt.Fprintln(os.Stderr)
	if hasSystems {
		tbl := table.New("Step", "System", "Status")
		tbl.WithHeaderFormatter(headerFmt).WithWriter(os.Stderr)
		for _, r := range results {
			status := passFmt("pass")
			if r.failed {
				status = failFmt("FAIL")
			}
			tbl.AddRow(r.step, r.system, status)
		}
		tbl.Print()
	} else {
		tbl := table.New("Step", "Status")
		tbl.WithHeaderFormatter(headerFmt).WithWriter(os.Stderr)
		for _, r := range results {
			status := passFmt("pass")
			if r.failed {
				status = failFmt("FAIL")
			}
			tbl.AddRow(r.step, status)
		}
		tbl.Print()
	}

	const tailLines = 20
	for _, r := range results {
		if !r.failed {
			continue
		}
		label := r.step
		if r.system != "" {
			label += " (" + r.system + ")"
		}
		fmt.Fprintln(os.Stderr)
		logWarn("%s:", cBold(label))
		start := 0
		if len(r.messages) > tailLines {
			start = len(r.messages) - tailLines
			logInfo("... (%d lines omitted)", start)
		}
		for _, msg := range r.messages[start:] {
			fmt.Fprintf(os.Stderr, "    %s\n", msg)
		}
	}
}

// buildDependencyGraph returns a JSON-serializable graph for MCP resources.
func buildDependencyGraph(procs []processEntry, config MultiStepConfig) map[string]any {
	depMap := buildDepMap(procs, config)
	graph := make(map[string]any)
	for _, p := range procs {
		entry := map[string]any{
			"step":       p.step,
			"system":     p.sys,
			"depends_on": depMap[p.key],
		}
		graph[p.key] = entry
	}
	return graph
}
