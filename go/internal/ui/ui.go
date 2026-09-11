package ui

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

const (
	Green  = "\033[1;32m"
	Yellow = "\033[1;33m"
	Red    = "\033[1;31m"
	Blue   = "\033[1;34m"
	Reset  = "\033[0m"
)

var reader = bufio.NewReader(os.Stdin)

func Log(format string, a ...interface{}) {
	fmt.Printf(Green+"[+]"+Reset+" "+format+"\n", a...)
}

func Warn(format string, a ...interface{}) {
	fmt.Printf(Yellow+"[!]"+Reset+" "+format+"\n", a...)
}

func Err(format string, a ...interface{}) {
	fmt.Printf(Red+"[x]"+Reset+" "+format+"\n", a...)
}

func Pause() {
	fmt.Print("Press Enter to continue...")
	reader.ReadString('\n')
}

func Ask(prompt, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", prompt, def)
	} else {
		fmt.Printf("%s: ", prompt)
	}
	line, _ := reader.ReadString('\n')
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return def
	}
	return line
}

func Confirm(prompt string, def bool) bool {
	d := "n"
	if def {
		d = "y"
	}
	ans := strings.ToLower(strings.TrimSpace(Ask(prompt, d)))
	return ans == "y"
}

func Clear() {
	fmt.Print("\033[H\033[2J")
}
