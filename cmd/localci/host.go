// Host configuration: maps Nix system strings (e.g. "aarch64-darwin") to
// SSH hostnames. Persisted in $XDG_CONFIG_HOME/localci/hosts.json so users
// only need to enter a hostname once per system.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

func hostsFilePath() string {
	configDir := os.Getenv("XDG_CONFIG_HOME")
	if configDir == "" {
		home, _ := os.UserHomeDir()
		configDir = filepath.Join(home, ".config")
	}
	return filepath.Join(configDir, "localci", "hosts.json")
}

func loadHosts() (map[string]string, error) {
	data, err := os.ReadFile(hostsFilePath())
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]string), nil
		}
		return nil, err
	}
	var hosts map[string]string
	if err := json.Unmarshal(data, &hosts); err != nil {
		return nil, err
	}
	return hosts, nil
}

func saveHost(system, host string) error {
	hosts, err := loadHosts()
	if err != nil {
		hosts = make(map[string]string)
	}
	hosts[system] = host

	path := hostsFilePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(hosts, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

var validHostname = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)

// getRemoteHost looks up or prompts for the SSH hostname for a system.
func getRemoteHost(system string) (string, error) {
	hosts, _ := loadHosts()
	if host, ok := hosts[system]; ok && host != "" {
		logMsg("Using saved host for %s: %s", system, cBold(host))
		return host, nil
	}

	// Prompt for hostname
	fmt.Fprintf(os.Stderr, "==> Enter hostname for %s: ", system)
	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		return "", fmt.Errorf("no hostname provided")
	}
	host := scanner.Text()
	if !validHostname.MatchString(host) {
		return "", fmt.Errorf("invalid hostname: %s", host)
	}

	if err := saveHost(system, host); err != nil {
		logWarn("Could not save host: %v", err)
	}
	return host, nil
}
