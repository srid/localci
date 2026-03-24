import std/[json, os, osproc, strutils, strformat, times, terminal, tempfiles, re, envvars, streams]

# ── Colors ──────────────────────────────────────────────────────────────────

var useColor = isatty(stderr)

proc bold(s: string): string =
  if useColor: "\e[1m" & s & "\e[0m" else: s

proc dim(s: string): string =
  if useColor: "\e[2m" & s & "\e[0m" else: s

proc red(s: string): string =
  if useColor: "\e[31m" & s & "\e[0m" else: s

proc green(s: string): string =
  if useColor: "\e[32m" & s & "\e[0m" else: s

proc yellow(s: string): string =
  if useColor: "\e[33m" & s & "\e[0m" else: s

proc cyan(s: string): string =
  if useColor: "\e[36m" & s & "\e[0m" else: s

proc cBold(s: string): string =
  if useColor: "\e[1m" & s & "\e[0m" else: s

# ── Logging ─────────────────────────────────────────────────────────────────

proc log(msg: string) =
  stderr.writeLine(cyan(bold("==>")) & " " & msg)

proc info(msg: string) =
  stderr.writeLine("    " & dim(msg))

proc err(msg: string) =
  stderr.writeLine(red(bold("Error:")) & " " & msg)

proc ok(msg: string) =
  stderr.writeLine(green(bold("==>")) & " " & msg)

proc warn(msg: string) =
  stderr.writeLine(yellow(bold("==>")) & " " & msg)

# ── Helpers ─────────────────────────────────────────────────────────────────

proc shortSHA(sha: string): string =
  if sha.len > 12: sha[0..11] else: sha

proc fmtTime(s: int): string =
  if s >= 3600:
    &"{s div 3600}h{(s mod 3600) div 60:02d}m{s mod 60:02d}s"
  elif s >= 60:
    &"{s div 60}m{s mod 60:02d}s"
  else:
    &"{s}s"

proc sanitizeLogName(name: string): string =
  result = name.multiReplace([("/", "-"), (" ", "-"), ("(", "-"), (")", "-")])
  result = result.replacef(re"-{2,}", "-")
  result = result.strip(leading = false, chars = {'-'})

proc run(cmd: string, args: openArray[string]): tuple[output: string, exitCode: int] =
  try:
    let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
    let output = p.outputStream.readAll()
    result.exitCode = p.waitForExit()
    result.output = output.strip()
    p.close()
  except OSError:
    result.output = ""
    result.exitCode = 127

proc runSilent(cmd: string, args: openArray[string]): int =
  try:
    let p = startProcess(cmd, args = args, options = {poUsePath})
    result = p.waitForExit()
    p.close()
  except OSError:
    result = 127

proc runPassthrough(cmd: string, args: openArray[string]): int =
  ## Run command with stdout/stderr inherited from parent process
  try:
    let p = startProcess(cmd, args = args, options = {poUsePath, poParentStreams})
    result = p.waitForExit()
    p.close()
  except OSError:
    result = 127

proc runCapture(cmd: string, args: openArray[string]): string =
  let (output, _) = run(cmd, args)
  return output

# ── Git ─────────────────────────────────────────────────────────────────────

proc isInGitRepo(): bool =
  runSilent("git", ["rev-parse", "--is-inside-work-tree"]) == 0

proc isTreeClean(): bool =
  let (output, rc) = run("git", ["status", "--porcelain"])
  return rc == 0 and output.len == 0

proc resolveHEAD(): string =
  runCapture("git", ["rev-parse", "HEAD"])

proc extractRepoLocal(sha, dir: string) =
  createDir(dir)
  # Pipe git archive to tar
  let archive = startProcess("git", args = ["archive", "--format=tar", sha], options = {poUsePath})
  let untar = startProcess("tar", args = ["-C", dir, "-x"], options = {poUsePath})
  let archiveOut = archive.outputStream
  let untarIn = untar.inputStream
  var buf: array[8192, char]
  while true:
    let n = archiveOut.readData(addr buf[0], buf.len)
    if n <= 0: break
    untarIn.writeData(addr buf[0], n)
  untarIn.close()
  discard archive.waitForExit()
  discard untar.waitForExit()
  archive.close()
  untar.close()
  discard runSilent("chmod", ["-R", "u+w", dir])

proc extractRepoRemote(sha, host, dir: string) =
  let sshCmd = &"mkdir -p '{dir}' && tar -C '{dir}' -x && chmod -R u+w '{dir}'"
  let archive = startProcess("git", args = ["archive", "--format=tar", sha], options = {poUsePath})
  let ssh = startProcess("ssh", args = [host, sshCmd], options = {poUsePath})
  let archiveOut = archive.outputStream
  let sshIn = ssh.inputStream
  var buf: array[8192, char]
  while true:
    let n = archiveOut.readData(addr buf[0], buf.len)
    if n <= 0: break
    sshIn.writeData(addr buf[0], n)
  sshIn.close()
  discard archive.waitForExit()
  discard ssh.waitForExit()
  archive.close()
  ssh.close()

# ── GitHub ──────────────────────────────────────────────────────────────────

proc getRepo(): string =
  runCapture("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])

proc postStatus(repo, sha, state, context, description: string) =
  var desc = description
  if desc.len > 140:
    desc = desc[0..139]
  discard runSilent("gh", ["api",
    "repos/" & repo & "/statuses/" & sha,
    "-f", "state=" & state,
    "-f", "context=" & context,
    "-f", "description=" & desc,
    "--silent"])

# ── Host config ─────────────────────────────────────────────────────────────

proc hostsFilePath(): string =
  let configDir = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  configDir / "giton" / "hosts.json"

proc loadHosts(): JsonNode =
  let path = hostsFilePath()
  if fileExists(path):
    try:
      return parseFile(path)
    except:
      return newJObject()
  return newJObject()

proc saveHost(system, host: string) =
  var hosts = loadHosts()
  hosts[system] = newJString(host)
  let path = hostsFilePath()
  createDir(parentDir(path))
  writeFile(path, $hosts)

proc getRemoteHost(system: string): string =
  let hosts = loadHosts()
  if hosts.hasKey(system):
    let h = hosts[system].getStr()
    if h.len > 0:
      log("Using saved host for " & system & ": " & cBold(h))
      return h

  # Prompt on /dev/tty (or stderr)
  stderr.write("==> Enter hostname for " & system & ": ")
  stderr.flushFile()
  var tty: File
  if open(tty, "/dev/tty"):
    result = tty.readLine().strip()
    tty.close()
  else:
    result = stdin.readLine().strip()

  # Sanitize hostname
  result = result.replacef(re"[^a-zA-Z0-9._-]", "")
  if result.len == 0:
    err("No hostname provided.")
    quit(1)
  saveHost(system, result)

# ── SSH helpers ─────────────────────────────────────────────────────────────

proc ensureSSHControlDir(host: string) =
  let (output, rc) = run("ssh", ["-G", host])
  if rc != 0: return
  for line in output.splitLines():
    if line.startsWith("controlpath "):
      let path = line[12..^1]
      createDir(parentDir(path))
      break

proc getCurrentSystem(): string =
  runCapture("nix", ["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])

# ── CLI args ────────────────────────────────────────────────────────────────

type
  CliArgs = object
    system: string
    systemExplicit: bool
    name: string
    cmd: seq[string]
    shaPin: string
    configFile: string
    tui: bool
    workdir: string

proc usage() =
  echo "Usage: giton [options] -- <command...>"
  echo "       giton -f <config.json>"
  echo ""
  echo "Run commands on Nix platforms and post GitHub commit statuses."
  echo ""
  echo "Single-step mode:"
  echo "  -s, --system    Nix system string (if omitted, runs on current system)"
  echo "  -n, --name      Check name for GitHub status context (default: command name)"
  echo "  --              Separator before the command to run"
  echo ""
  echo "Multi-step mode:"
  echo "  -f, --file      JSON config file defining steps, systems, and dependencies"
  echo ""
  echo "Common options:"
  echo "  --sha           Pin to a specific commit SHA (skips clean-tree check)"
  echo "  --tui           Enable process-compose TUI (multi-step mode only)"
  echo ""
  echo "Status context: giton/<name> (no --system) or giton/<name>/<system> (with --system)"
  quit(1)

proc parseArgs(): CliArgs =
  var i = 1
  let argc = paramCount()
  while i <= argc:
    let arg = paramStr(i)
    case arg
    of "-s", "--system":
      inc i
      if i > argc: err("--system requires a value"); quit(1)
      result.system = paramStr(i)
      result.systemExplicit = true
    of "-n", "--name":
      inc i
      if i > argc: err("--name requires a value"); quit(1)
      result.name = paramStr(i)
    of "--sha":
      inc i
      if i > argc: err("--sha requires a value"); quit(1)
      result.shaPin = paramStr(i)
    of "-f", "--file":
      inc i
      if i > argc: err("--file requires a value"); quit(1)
      result.configFile = paramStr(i)
    of "--tui":
      result.tui = true
    of "--workdir":
      inc i
      if i > argc: err("--workdir requires a value"); quit(1)
      result.workdir = paramStr(i)
    of "--":
      inc i
      while i <= argc:
        result.cmd.add(paramStr(i))
        inc i
      break
    of "-h", "--help":
      usage()
    else:
      echo "Error: Unknown option '" & arg & "'"
      usage()
    inc i

# ── Execution ───────────────────────────────────────────────────────────────

proc runLocal(dir: string, cmdArgs: seq[string]): int =
  let cmdStr = cmdArgs.join(" ")
  runPassthrough("bash", ["-c", "cd '" & dir & "' && " & cmdStr])

proc runSSH(host, dir: string, cmdArgs: seq[string]): int =
  let cmdStr = cmdArgs.join(" ")
  runPassthrough("ssh", [host, "cd '" & dir & "' && " & cmdStr])

proc cleanupRemote(host, dir: string) =
  log("Cleaning up remote temp dir...")
  discard runSilent("ssh", [host, "rm -rf '" & dir & "'"])

# ── Single-step mode ───────────────────────────────────────────────────────

proc runSingleStep(args: CliArgs, sha: string): int =
  if args.cmd.len == 0:
    err("A command after -- is required (or use -f for multi-step mode).")
    usage()

  var name = args.name
  if name.len == 0:
    name = args.cmd[0].extractFilename()

  var context: string
  if args.systemExplicit:
    context = &"giton/{name}/{args.system}"
  else:
    context = &"giton/{name}"

  let repo = getRepo()
  if repo.len == 0:
    err("Could not determine GitHub repository. Is 'gh' authenticated?")
    return 1

  let cmdStr = args.cmd.join(" ")
  log(cBold(context) & "  " & dim(repo & "@" & shortSHA(sha)))
  info(cmdStr)

  postStatus(repo, sha, "pending", context, "Running: " & cmdStr)

  let remote = args.systemExplicit and getCurrentSystem() != args.system
  let start = epochTime()
  var rc: int

  if args.workdir.len > 0:
    if remote:
      let host = getRemoteHost(args.system)
      rc = runSSH(host, args.workdir, args.cmd)
    else:
      rc = runLocal(args.workdir, args.cmd)
  elif remote:
    let host = getRemoteHost(args.system)
    let remoteDir = "/tmp/giton-" & shortSHA(sha)
    ensureSSHControlDir(host)
    log("Copying repo to " & cBold(host) & "...")
    extractRepoRemote(sha, host, remoteDir)
    rc = runSSH(host, remoteDir, args.cmd)
    cleanupRemote(host, remoteDir)
  else:
    let tmpdir = getTempDir() / ("giton-" & shortSHA(sha) & "-XXXXXX")
    log("Extracting repo...")
    extractRepoLocal(sha, tmpdir)
    rc = runLocal(tmpdir, args.cmd)
    removeDir(tmpdir)

  let elapsed = fmtTime(int(epochTime() - start))

  if rc == 0:
    ok(cBold(context) & " passed in " & green(elapsed))
    postStatus(repo, sha, "success", context, "Passed in " & elapsed & ": " & cmdStr)
  else:
    warn(cBold(context) & " failed (exit " & $rc & ") in " & yellow(elapsed))
    postStatus(repo, sha, "failure", context, "Failed (exit " & $rc & ") in " & elapsed & ": " & cmdStr)

  return rc

# ── Multi-step mode ────────────────────────────────────────────────────────

type
  StepConfig = object
    command: string
    systems: seq[string]
    dependsOn: seq[string]

  ProcessEntry = object
    step: string
    sys: string  # empty if no systems
    key: string  # process-compose process name

proc parseConfig(path: string): JsonNode =
  if not fileExists(path):
    err("Config file not found: " & path)
    quit(1)
  return parseFile(path)

proc collectSystems(config: JsonNode): seq[string] =
  var seen: seq[string] = @[]
  for stepName, step in config["steps"]:
    if step.hasKey("systems"):
      for sys in step["systems"]:
        let s = sys.getStr()
        if s notin seen:
          seen.add(s)
  return seen

proc buildProcessEntries(config: JsonNode): seq[ProcessEntry] =
  for stepName, step in config["steps"]:
    var systems: seq[string] = @[]
    if step.hasKey("systems"):
      for sys in step["systems"]:
        systems.add(sys.getStr())

    if systems.len == 0:
      result.add(ProcessEntry(step: stepName, sys: "", key: stepName))
    else:
      for sys in systems:
        let key = if systems.len == 1: stepName
                  else: stepName & " (" & sys & ")"
        result.add(ProcessEntry(step: stepName, sys: sys, key: key))

proc selfPath(): string =
  result = getAppFilename()
  try:
    result = expandSymlink(result)
  except:
    discard

proc runMultiStep(args: CliArgs, sha: string): int =
  let config = parseConfig(args.configFile)
  log("Multi-step mode: " & cBold(args.configFile) & "  " & dim("SHA=" & shortSHA(sha)))

  let currentSystem = getCurrentSystem()
  let cwd = getCurrentDir()
  let allSystems = collectSystems(config)

  # Resolve remote hosts upfront
  var hostMap = newJObject()
  let hostname = runCapture("hostname", [])
  hostMap[currentSystem] = newJString(hostname)

  for sys in allSystems:
    if sys != currentSystem:
      let host = getRemoteHost(sys)
      hostMap[sys] = newJString(host)
      log("Warming SSH connection to " & cBold(host) & " (" & sys & ")...")
      discard runSilent("ssh", [host, "echo", "ok"])

  # Pre-extract repo once per system
  let workdirBase = "/tmp/giton-" & shortSHA(sha)
  var workdirMap = newJObject()

  # Local
  let localDir = workdirBase & "-local"
  log("Extracting repo (local)...")
  extractRepoLocal(sha, localDir)
  workdirMap[currentSystem] = newJString(localDir)

  # Remote
  for sys in allSystems:
    if sys != currentSystem:
      let host = hostMap[sys].getStr()
      let rdir = workdirBase & "-" & sys
      log("Extracting repo on " & cBold(host) & " (" & sys & ")...")
      extractRepoRemote(sha, host, rdir)
      workdirMap[sys] = newJString(rdir)

  let logDir = "/tmp/giton-" & shortSHA(sha) & "-logs"
  createDir(logDir)

  # Build process entries
  let procs = buildProcessEntries(config)
  let self = selfPath()

  # Generate process-compose config
  var processes = newJObject()

  for p in procs:
    let step = config["steps"][p.step]
    var cmdParts: seq[string] = @[self, "--sha", sha]
    if p.sys.len > 0:
      cmdParts.add("-s")
      cmdParts.add(p.sys)
      if workdirMap.hasKey(p.sys):
        cmdParts.add("--workdir")
        cmdParts.add(workdirMap[p.sys].getStr())
    cmdParts.add("-n")
    cmdParts.add(p.step)
    cmdParts.add("--")
    cmdParts.add(step["command"].getStr())

    # Resolve dependencies
    var depends = newJObject()
    if step.hasKey("depends_on"):
      for dep in step["depends_on"]:
        let depName = dep.getStr()
        for dp in procs:
          if dp.step == depName and dp.sys == p.sys:
            depends[dp.key] = %*{"condition": "process_completed_successfully"}
            break

    let logFile = logDir / (sanitizeLogName(p.key) & ".log")

    var proc_obj = %*{
      "command": cmdParts.join(" "),
      "working_dir": cwd,
      "log_location": logFile,
      "availability": {"restart": "exit_on_failure"}
    }

    if depends.len > 0:
      proc_obj["depends_on"] = depends

    if p.sys.len > 0:
      let h = if hostMap.hasKey(p.sys): hostMap[p.sys].getStr() else: "local"
      proc_obj["namespace"] = newJString(p.sys & " (" & h & ")")

    processes[p.key] = proc_obj

  let pcConfig = %*{
    "version": "0.5",
    "log_configuration": {"flush_each_line": true},
    "processes": processes
  }

  # Write to temp file
  let pcFile = getTempDir() / ("giton-pc-" & $getCurrentProcessId() & ".json")
  writeFile(pcFile, pretty(pcConfig))

  # Run process-compose
  let tuiStr = if args.tui: "true" else: "false"
  let pcExit = runPassthrough("process-compose", ["up", "--tui=" & tuiStr, "--no-server", "--config", pcFile])

  # Cleanup
  removeFile(pcFile)
  removeDir(localDir)
  for sys in allSystems:
    if sys != currentSystem:
      let host = hostMap[sys].getStr()
      let rdir = workdirBase & "-" & sys
      discard runSilent("ssh", [host, "rm -rf '" & rdir & "'"])

  # Summary
  stderr.writeLine("")
  if pcExit == 0:
    ok("All steps passed")
  else:
    warn("One or more steps failed (exit " & $pcExit & ")")
    info("Logs: " & logDir & "/")
    if not args.tui:
      # Print failed logs
      for logfile in walkFiles(logDir / "*.log"):
        let data = readFile(logfile)
        if data.len == 0 or "failed" notin data:
          continue
        let stepname = extractFilename(logfile).replace(".log", "")
        stderr.writeLine("")
        warn(cBold(stepname) & ":")
        for line in data.splitLines():
          if line.len == 0: continue
          try:
            let entry = parseJson(line)
            if entry.hasKey("message"):
              stderr.writeLine(entry["message"].getStr())
          except:
            discard

  return pcExit

# ── Main ────────────────────────────────────────────────────────────────────

proc main() =
  let args = parseArgs()

  if not isInGitRepo():
    err("Not inside a git repository.")
    quit(1)

  var sha: string
  if args.shaPin.len > 0:
    sha = args.shaPin
  else:
    if not isTreeClean():
      err("Working tree is dirty. Commit or stash changes first.")
      quit(1)
    sha = resolveHEAD()

  if args.configFile.len > 0:
    quit(runMultiStep(args, sha))

  quit(runSingleStep(args, sha))

main()
