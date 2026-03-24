// Colored log output to stderr. fatih/color auto-disables when stderr
// is not a TTY (piped or redirected), matching the bash version's behavior.
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/fatih/color"
)

// Color functions for inline styling within log messages.
var (
	cBold   = color.New(color.Bold).SprintFunc()
	cDim    = color.New(color.Faint).SprintFunc()
	cHeader = color.New(color.FgCyan, color.Bold).SprintFunc()
	cOk     = color.New(color.FgGreen, color.Bold).SprintFunc()
	cWarn   = color.New(color.FgYellow, color.Bold).SprintFunc()
	cErr    = color.New(color.FgRed, color.Bold).SprintFunc()
	cGreen  = color.New(color.FgGreen).SprintFunc()
	cYellow = color.New(color.FgYellow).SprintFunc()
)

func logMsg(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", cHeader("==>"), fmt.Sprintf(msg, args...))
}

func logInfo(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "    %s\n", cDim(fmt.Sprintf(msg, args...)))
}

func logErr(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", cErr("Error:"), fmt.Sprintf(msg, args...))
}

func logOk(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", cOk("==>"), fmt.Sprintf(msg, args...))
}

func logWarn(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", cWarn("==>"), fmt.Sprintf(msg, args...))
}

// fmtDuration formats a duration as "Xs", "Xm00s", or "Xh00m00s"
// matching the compact style used in GitHub status descriptions.
func fmtDuration(d time.Duration) string {
	s := int(d.Seconds())
	if s >= 3600 {
		return fmt.Sprintf("%dh%02dm%02ds", s/3600, (s%3600)/60, s%60)
	}
	if s >= 60 {
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	}
	return fmt.Sprintf("%ds", s)
}
