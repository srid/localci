// Git operations: repo detection, clean-tree check, HEAD resolution,
// and archive extraction (local and remote via SSH pipe).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func isInGitRepo() bool {
	cmd := exec.Command("git", "rev-parse", "--is-inside-work-tree")
	cmd.Stderr = nil
	cmd.Stdout = nil
	return cmd.Run() == nil
}

func isTreeClean() bool {
	// Single porcelain call detects staged, unstaged, and untracked changes
	out, err := exec.Command("git", "status", "--porcelain").Output()
	if err != nil {
		return false
	}
	return len(strings.TrimSpace(string(out))) == 0
}

func resolveHEAD() (string, error) {
	return resolveRef("HEAD")
}

// resolveRef resolves a git ref (SHA, branch, HEAD, etc.) to a full SHA.
func resolveRef(ref string) (string, error) {
	out, err := exec.Command("git", "rev-parse", ref).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// gitRepoRoot returns the top-level directory of the git repository.
func gitRepoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// validWorkdir returns cwd if it still exists, otherwise falls back
// to the git repo root. Prevents "cannot get current path" errors
// when cwd is deleted during long-running async handlers.
func validWorkdir() string {
	cwd, err := os.Getwd()
	if err == nil {
		if _, statErr := os.Stat(cwd); statErr == nil {
			return cwd
		}
	}
	root, err := gitRepoRoot()
	if err == nil {
		return root
	}
	return "."
}

// isCommitPushed checks if a SHA exists on any remote branch.
func isCommitPushed(sha string) bool {
	out, err := exec.Command("git", "branch", "-r", "--contains", sha).Output()
	if err != nil {
		return false
	}
	return len(strings.TrimSpace(string(out))) > 0
}

// extractRepoLocal extracts the repo at the given SHA to a local directory.
func extractRepoLocal(sha, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	untar := exec.Command("tar", "-C", dir, "-x")
	if err := pipeGitArchive(sha, untar); err != nil {
		return err
	}
	return exec.Command("chmod", "-R", "u+w", dir).Run()
}

// extractRepoRemote extracts the repo at the given SHA to a remote host via SSH.
func extractRepoRemote(sha, host, dir string) error {
	sshCmd := exec.Command("ssh", host,
		fmt.Sprintf("mkdir -p '%s' && tar -C '%s' -x && chmod -R u+w '%s'", dir, dir, dir))
	sshCmd.Stdout = os.Stdout
	sshCmd.Stderr = os.Stderr
	return pipeGitArchive(sha, sshCmd)
}

// pipeGitArchive streams `git archive` tar output into a consumer command
// (either local `tar -x` or remote `ssh host "tar -x"`). This avoids
// writing the archive to disk — the tar stream flows through a pipe.
func pipeGitArchive(sha string, consumer *exec.Cmd) error {
	archive := exec.Command("git", "archive", "--format=tar", sha)
	pipe, err := archive.StdoutPipe()
	if err != nil {
		return err
	}
	consumer.Stdin = pipe
	if err := archive.Start(); err != nil {
		return err
	}
	if err := consumer.Run(); err != nil {
		return fmt.Errorf("consumer: %w", err)
	}
	if err := archive.Wait(); err != nil {
		return fmt.Errorf("git archive: %w", err)
	}
	return nil
}
