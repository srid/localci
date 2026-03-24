#!/usr/bin/env python3
"""giton — Local CI tool: run commands on Nix platforms with GitHub status reporting."""

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# ── Colors ──────────────────────────────────────────────────────────────────

if sys.stderr.isatty():
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    CYAN = "\033[36m"
    RESET = "\033[0m"
else:
    BOLD = DIM = RED = GREEN = YELLOW = CYAN = RESET = ""


def log(msg):
    print(f"{CYAN}{BOLD}==>{RESET} {msg}", file=sys.stderr)


def info(msg):
    print(f"    {DIM}{msg}{RESET}", file=sys.stderr)


def err(msg):
    print(f"{RED}{BOLD}Error:{RESET} {msg}", file=sys.stderr)


def ok(msg):
    print(f"{GREEN}{BOLD}==>{RESET} {msg}", file=sys.stderr)


def warn(msg):
    print(f"{YELLOW}{BOLD}==>{RESET} {msg}", file=sys.stderr)


def fmt_time(s):
    if s >= 3600:
        return f"{s // 3600}h{s % 3600 // 60:02d}m{s % 60:02d}s"
    elif s >= 60:
        return f"{s // 60}m{s % 60:02d}s"
    else:
        return f"{s}s"


# ── Subprocess helpers ──────────────────────────────────────────────────────


def _run(*args, capture=True, check=True, **kwargs):
    """Run a command, returning CompletedProcess."""
    return subprocess.run(args, capture_output=capture, text=True, check=check, **kwargs)


def run_output(*args):
    """Run a command, return stripped stdout."""
    return _run(*args).stdout.strip()


# ── Git helpers ─────────────────────────────────────────────────────────────


def is_in_git_repo():
    try:
        _run("git", "rev-parse", "--is-inside-work-tree")
        return True
    except subprocess.CalledProcessError:
        return False


def is_tree_clean():
    try:
        _run("git", "diff", "--quiet")
        _run("git", "diff", "--cached", "--quiet")
        out = run_output("git", "ls-files", "--others", "--exclude-standard")
        return out == ""
    except subprocess.CalledProcessError:
        return False


def resolve_head():
    return run_output("git", "rev-parse", "HEAD")


# ── Host configuration ─────────────────────────────────────────────────────


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config"))
    return os.path.join(base, "giton")


def hosts_file():
    return os.path.join(config_dir(), "hosts.json")


def load_hosts():
    path = hosts_file()
    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_host(system, host):
    d = config_dir()
    os.makedirs(d, exist_ok=True)
    hosts = load_hosts()
    hosts[system] = host
    with open(hosts_file(), "w") as f:
        json.dump(hosts, f)


def get_remote_host(system):
    hosts = load_hosts()
    host = hosts.get(system)
    if host:
        log(f"Using saved host for {system}: {BOLD}{host}{RESET}")
        return host

    # Prompt from tty
    try:
        tty = open("/dev/tty", "r")
    except OSError:
        err("Cannot open /dev/tty to prompt for hostname.")
        sys.exit(1)
    print(f"==> Enter hostname for {system}: ", end="", file=sys.stderr, flush=True)
    host = tty.readline().strip()
    tty.close()
    host = re.sub(r"[^a-zA-Z0-9._-]", "", host)
    if not host:
        err("No hostname provided.")
        sys.exit(1)
    save_host(system, host)
    return host


# ── GitHub status ───────────────────────────────────────────────────────────


def get_repo():
    try:
        return run_output("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
    except subprocess.CalledProcessError:
        return ""


def post_status(repo, sha, context, state, description=""):
    description = description[:140]
    try:
        _run(
            "gh", "api", f"repos/{repo}/statuses/{sha}",
            "-f", f"state={state}",
            "-f", f"context={context}",
            "-f", f"description={description}",
            "--silent",
        )
    except subprocess.CalledProcessError:
        pass


# ── Execution helpers ───────────────────────────────────────────────────────


def current_system():
    return run_output("nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem")


def sanitize_log_name(name):
    name = re.sub(r"[/ ()]", "-", name)
    name = re.sub(r"-+", "-", name)
    name = name.rstrip("-")
    return name


def self_invoke_prefix():
    """Return the command prefix for self-invocation.

    When invoked as 'python3 giton.py', sys.argv[0] is the .py file.
    When invoked via a Nix wrapper, sys.argv[0] is the wrapper script.
    We need to reconstruct the full invocation command.
    """
    argv0 = sys.argv[0]
    if argv0.endswith(".py"):
        return f"{sys.executable} {argv0}"
    return argv0


# ── Multi-step mode ─────────────────────────────────────────────────────────


def run_multi_step(args, sha):
    if not os.path.isfile(args.config_file):
        err(f"Config file not found: {args.config_file}")
        return 1

    with open(args.config_file) as f:
        config = json.load(f)

    log(f"Multi-step mode: {BOLD}{args.config_file}{RESET}  {DIM}SHA={sha[:12]}{RESET}")

    steps = config["steps"]
    cur_sys = current_system()
    host_map = {cur_sys: socket.gethostname()}

    # Collect all systems
    all_systems = set()
    for step_cfg in steps.values():
        for s in step_cfg.get("systems", []):
            all_systems.add(s)

    # Resolve remote hosts upfront
    for remote_sys in sorted(all_systems):
        if remote_sys != cur_sys:
            host = get_remote_host(remote_sys)
            host_map[remote_sys] = host
            log(f"Warming SSH connection to {BOLD}{host}{RESET} ({remote_sys})...")
            subprocess.run(["ssh", host, "echo", "ok"], stdout=subprocess.DEVNULL)

    # Pre-extract repo
    workdir_base = f"/tmp/giton-{sha[:12]}"
    workdir_map = {}

    local_dir = f"{workdir_base}-local"
    os.makedirs(local_dir, exist_ok=True)
    log("Extracting repo (local)...")
    p1 = subprocess.Popen(["git", "archive", "--format=tar", sha], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-C", local_dir, "-x"], stdin=p1.stdout, check=True)
    p1.wait()
    subprocess.run(["chmod", "-R", "u+w", local_dir], check=True)
    workdir_map[cur_sys] = local_dir

    for remote_sys in sorted(all_systems):
        if remote_sys != cur_sys:
            host = host_map[remote_sys]
            rdir = f"{workdir_base}-{remote_sys}"
            log(f"Extracting repo on {BOLD}{host}{RESET} ({remote_sys})...")
            p1 = subprocess.Popen(["git", "archive", "--format=tar", sha], stdout=subprocess.PIPE)
            subprocess.run(
                ["ssh", host, f"mkdir -p '{rdir}' && tar -C '{rdir}' -x && chmod -R u+w '{rdir}'"],
                stdin=p1.stdout, check=True,
            )
            p1.wait()
            workdir_map[remote_sys] = rdir

    log_dir = f"/tmp/giton-{sha[:12]}-logs"
    os.makedirs(log_dir, exist_ok=True)

    # Build process-compose config
    giton_cmd = self_invoke_prefix()
    cwd = os.getcwd()

    # Build proc list: each step x system
    procs = []
    for step_name, step_cfg in steps.items():
        systems = step_cfg.get("systems", [None])
        for step_sys in systems:
            if step_sys is None:
                key = step_name
            elif len(systems) == 1:
                key = step_name
            else:
                key = f"{step_name} ({step_sys})"
            procs.append({"step": step_name, "sys": step_sys, "key": key})

    processes = {}
    for proc in procs:
        step_name = proc["step"]
        step_sys = proc["sys"]
        key = proc["key"]
        step_cfg = steps[step_name]

        # Build command
        cmd_parts = [giton_cmd, "--sha", sha]
        if step_sys is not None:
            cmd_parts += ["-s", step_sys]
            if step_sys in workdir_map:
                cmd_parts += ["--workdir", workdir_map[step_sys]]
        cmd_parts += ["-n", step_name, "--", step_cfg["command"]]
        command_str = " ".join(cmd_parts)

        # Dependencies
        deps = step_cfg.get("depends_on", [])
        depends_on = {}
        for dep in deps:
            for p in procs:
                if p["step"] == dep and p["sys"] == step_sys:
                    depends_on[p["key"]] = {"condition": "process_completed_successfully"}
                    break

        log_file = os.path.join(log_dir, sanitize_log_name(key) + ".log")

        process = {
            "command": command_str,
            "working_dir": cwd,
            "log_location": log_file,
            "availability": {"restart": "exit_on_failure"},
        }
        if step_sys is not None:
            namespace = f"{step_sys} ({host_map.get(step_sys, 'local')})"
            process["namespace"] = namespace
        if depends_on:
            process["depends_on"] = depends_on

        processes[key] = process

    pc_config = {
        "version": "0.5",
        "log_configuration": {"flush_each_line": True},
        "processes": processes,
    }

    pc_fd, pc_path = tempfile.mkstemp(prefix="giton-pc-", suffix=".json")
    try:
        with os.fdopen(pc_fd, "w") as f:
            json.dump(pc_config, f)

        tui_flag = "true" if args.tui else "false"
        result = subprocess.run(
            ["process-compose", "up", f"--tui={tui_flag}", "--no-server", "--config", pc_path],
            check=False,
        )
        pc_exit = result.returncode
    finally:
        os.unlink(pc_path)
        # Cleanup workdirs
        shutil.rmtree(local_dir, ignore_errors=True)
        for remote_sys in sorted(all_systems):
            if remote_sys != cur_sys and remote_sys in host_map:
                host = host_map[remote_sys]
                rdir = f"{workdir_base}-{remote_sys}"
                subprocess.run(
                    ["ssh", host, f"rm -rf '{rdir}'"],
                    capture_output=True, check=False,
                )

    print("", file=sys.stderr)
    if pc_exit == 0:
        ok("All steps passed")
    else:
        warn(f"One or more steps failed (exit {pc_exit})")
        info(f"Logs: {log_dir}/")
        if not args.tui:
            try:
                log_files = sorted(os.listdir(log_dir))
            except OSError:
                log_files = []
            for logfile in log_files:
                if not logfile.endswith(".log"):
                    continue
                path = os.path.join(log_dir, logfile)
                if os.path.getsize(path) == 0:
                    continue
                try:
                    with open(path) as lf:
                        content = lf.read()
                    if "failed" not in content:
                        continue
                    stepname = logfile[:-4]
                    print("", file=sys.stderr)
                    warn(f"{BOLD}{stepname}{RESET}:")
                    for line in content.strip().split("\n"):
                        try:
                            msg = json.loads(line).get("message", line)
                        except (json.JSONDecodeError, AttributeError):
                            msg = line
                        print(msg, file=sys.stderr)
                except OSError:
                    pass

    return pc_exit


# ── Single-step mode ────────────────────────────────────────────────────────


def run_single_step(args, sha):
    name = args.name or os.path.basename(args.cmd[0])
    system_explicit = args.system is not None

    if system_explicit:
        context = f"giton/{name}/{args.system}"
    else:
        context = f"giton/{name}"

    repo = get_repo()
    if not repo:
        err("Could not determine GitHub repository. Is 'gh' authenticated?")
        return 1

    log(f"{BOLD}{context}{RESET}  {DIM}{repo}@{sha[:12]}{RESET}")
    info(" ".join(args.cmd))

    post_status(repo, sha, context, "pending", f"Running: {' '.join(args.cmd)}")

    # Determine remote
    remote = False
    if system_explicit:
        cur_sys = current_system()
        if cur_sys != args.system:
            remote = True

    start = int(time.time())
    exit_code = 0

    if args.workdir:
        # Pre-extracted workdir (multi-step mode)
        if remote:
            host = get_remote_host(args.system)
            result = subprocess.run(
                ["ssh", host, f"cd '{args.workdir}' && {' '.join(args.cmd)}"],
                check=False,
            )
            exit_code = result.returncode
        else:
            result = subprocess.run(
                ["bash", "-c", f"cd '{args.workdir}' && {' '.join(args.cmd)}"],
                check=False,
            )
            exit_code = result.returncode
    elif remote:
        host = get_remote_host(args.system)
        remote_dir = f"/tmp/giton-{sha[:12]}"

        # Ensure SSH ControlMaster socket directory exists
        try:
            ssh_config = run_output("ssh", "-G", host)
            for line in ssh_config.split("\n"):
                if line.startswith("controlpath "):
                    cp = line.split(" ", 1)[1]
                    os.makedirs(os.path.dirname(cp), exist_ok=True)
                    break
        except (subprocess.CalledProcessError, OSError):
            pass

        log(f"Copying repo to {BOLD}{host}{RESET}...")
        try:
            p1 = subprocess.Popen(["git", "archive", "--format=tar", sha], stdout=subprocess.PIPE)
            subprocess.run(
                ["ssh", host, f"mkdir -p '{remote_dir}' && tar -C '{remote_dir}' -x && chmod -R u+w '{remote_dir}'"],
                stdin=p1.stdout, check=True,
            )
            p1.wait()

            result = subprocess.run(
                ["ssh", host, f"cd '{remote_dir}' && {' '.join(args.cmd)}"],
                check=False,
            )
            exit_code = result.returncode
        finally:
            log("Cleaning up remote temp dir...")
            subprocess.run(
                ["ssh", host, f"rm -rf '{remote_dir}'"],
                capture_output=True, check=False,
            )
    else:
        tmpdir = tempfile.mkdtemp(prefix=f"giton-{sha[:12]}-")
        try:
            log("Extracting repo...")
            p1 = subprocess.Popen(["git", "archive", "--format=tar", sha], stdout=subprocess.PIPE)
            subprocess.run(["tar", "-C", tmpdir, "-x"], stdin=p1.stdout, check=True)
            p1.wait()
            subprocess.run(["chmod", "-R", "u+w", tmpdir], check=True)

            result = subprocess.run(
                ["bash", "-c", f"cd '{tmpdir}' && {' '.join(args.cmd)}"],
                check=False,
            )
            exit_code = result.returncode
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    elapsed = fmt_time(int(time.time()) - start)
    cmd_str = " ".join(args.cmd)

    if exit_code == 0:
        ok(f"{BOLD}{context}{RESET} passed in {GREEN}{elapsed}{RESET}")
        post_status(repo, sha, context, "success", f"Passed in {elapsed}: {cmd_str}")
    else:
        warn(f"{BOLD}{context}{RESET} failed (exit {exit_code}) in {YELLOW}{elapsed}{RESET}")
        post_status(repo, sha, context, "failure", f"Failed (exit {exit_code}) in {elapsed}: {cmd_str}")

    return exit_code


# ── Main ────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Local CI tool — run commands on Nix platforms with GitHub status reporting.",
        usage="giton [options] -- <command...>\n       giton -f <config.json>",
    )
    parser.add_argument("-s", "--system", default=None, help="Nix system string (if omitted, runs on current system)")
    parser.add_argument("-n", "--name", default=None, help="Check name for GitHub status context (default: command name)")
    parser.add_argument("--sha", default=None, help="Pin to a specific commit SHA (skips clean-tree check)")
    parser.add_argument("-f", "--file", dest="config_file", default=None, help="JSON config file defining steps, systems, and dependencies")
    parser.add_argument("--tui", action="store_true", help="Enable process-compose TUI (multi-step mode only)")
    parser.add_argument("--workdir", default=None, help=argparse.SUPPRESS)
    parser.add_argument("cmd", nargs="*", help="Command to run (after --)")

    args = parser.parse_args()

    if not is_in_git_repo():
        err("Not inside a git repository.")
        sys.exit(1)

    if args.sha:
        sha = args.sha
    else:
        if not is_tree_clean():
            err("Working tree is dirty. Commit or stash changes first.")
            sys.exit(1)
        sha = resolve_head()

    if args.config_file:
        sys.exit(run_multi_step(args, sha))

    if not args.cmd:
        err("A command after -- is required (or use -f for multi-step mode).")
        parser.print_usage(sys.stderr)
        sys.exit(1)

    sys.exit(run_single_step(args, sha))


if __name__ == "__main__":
    main()
