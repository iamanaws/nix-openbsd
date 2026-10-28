package main

import (
	"fmt"
	"runtime"
	"strings"
)

func main() {
	fmt.Printf("Go %s/%s: %s\n", runtime.GOOS, runtime.GOARCH, strings.ToUpper("héllo"))
}
