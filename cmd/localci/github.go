package main

import (
	"os/exec"
	"strings"
)

// getRepo returns the GitHub owner/repo string.
func getRepo() (string, error) {
	out, err := exec.Command("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// postStatus posts a GitHub commit status.
func postStatus(repo, sha, state, context, description string) error {
	// GitHub status API enforces a 140-char limit on description
	if len(description) > 140 {
		description = description[:140]
	}
	return exec.Command("gh", "api",
		"repos/"+repo+"/statuses/"+sha,
		"-f", "state="+state,
		"-f", "context="+context,
		"-f", "description="+description,
		"--silent",
	).Run()
}
