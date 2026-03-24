package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func runSingleStep(args cliArgs, sha string) int {
	name := args.name
	if name == "" {
		name = filepath.Base(args.cmd[0])
	}

	var context string
	if args.systemExplicit {
		context = fmt.Sprintf("giton/%s/%s", name, args.system)
	} else {
		context = fmt.Sprintf("giton/%s", name)
	}

	repo, err := getRepo()
	if err != nil || repo == "" {
		logErr("Could not determine GitHub repository. Is 'gh' authenticated?")
		return 1
	}

	cmdStr := strings.Join(args.cmd, " ")

	logMsg("%s  %s", cBold(context), cDim(repo+"@"+shortSHA(sha)))
	logInfo("%s", cmdStr)

	postStatus(repo, sha, "pending", context, "Running: "+cmdStr)

	remote := args.systemExplicit && getCurrentSystem() != args.system

	start := time.Now()
	var rc int

	if args.workdir != "" {
		if remote {
			host, err := getRemoteHost(args.system)
			if err != nil {
				logErr("%v", err)
				return 1
			}
			rc = runSSH(host, args.workdir, args.cmd)
		} else {
			rc = runLocal(args.workdir, args.cmd)
		}
	} else if remote {
		host, err := getRemoteHost(args.system)
		if err != nil {
			logErr("%v", err)
			return 1
		}
		remoteDir := fmt.Sprintf("/tmp/giton-%s", shortSHA(sha))
		defer cleanupRemote(host, remoteDir)

		ensureSSHControlDir(host)
		logMsg("Copying repo to %s...", cBold(host))
		if err := extractRepoRemote(sha, host, remoteDir); err != nil {
			logErr("Failed to extract repo remotely: %v", err)
			return 1
		}
		rc = runSSH(host, remoteDir, args.cmd)
	} else {
		tmpdir, err := os.MkdirTemp("", fmt.Sprintf("giton-%s-", shortSHA(sha)))
		if err != nil {
			logErr("Failed to create temp dir: %v", err)
			return 1
		}
		defer os.RemoveAll(tmpdir)

		logMsg("Extracting repo...")
		if err := extractRepoLocal(sha, tmpdir); err != nil {
			logErr("Failed to extract repo: %v", err)
			return 1
		}
		rc = runLocal(tmpdir, args.cmd)
	}

	elapsed := fmtDuration(time.Since(start))

	if rc == 0 {
		logOk("%s passed in %s", cBold(context), cGreen(elapsed))
		postStatus(repo, sha, "success", context, fmt.Sprintf("Passed in %s: %s", elapsed, cmdStr))
	} else {
		logWarn("%s failed (exit %d) in %s", cBold(context), rc, cYellow(elapsed))
		postStatus(repo, sha, "failure", context, fmt.Sprintf("Failed (exit %d) in %s: %s", rc, elapsed, cmdStr))
	}

	return rc
}

// runLocal executes a command locally in the given directory.
func runLocal(dir string, cmdArgs []string) int {
	cmd := exec.Command("bash", "-c", strings.Join(cmdArgs, " "))
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return exitCode(cmd.Run())
}

// runSSH executes a command on a remote host via SSH.
func runSSH(host, dir string, cmdArgs []string) int {
	cmd := exec.Command("ssh", host, fmt.Sprintf("cd '%s' && %s", dir, strings.Join(cmdArgs, " ")))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return exitCode(cmd.Run())
}

// exitCode extracts the process exit code from an exec error.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 1
}

func cleanupRemote(host, dir string) {
	logMsg("Cleaning up remote temp dir...")
	exec.Command("ssh", host, "rm -rf '"+dir+"'").Run()
}

func ensureSSHControlDir(host string) {
	out, err := exec.Command("ssh", "-G", host).Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "controlpath ") {
			path := strings.TrimPrefix(line, "controlpath ")
			os.MkdirAll(filepath.Dir(path), 0o700)
			break
		}
	}
}

func getCurrentSystem() string {
	out, err := exec.Command("nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem").Output()
	if err != nil {
		return ""
	}
	return string(out)
}

func shortSHA(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
