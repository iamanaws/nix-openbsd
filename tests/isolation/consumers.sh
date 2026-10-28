set -euo pipefail
fixtures=$1
destination=$2
export PATH="$fixtures/cc/bin:$fixtures/go/bin:$fixtures/coreutils/bin:$fixtures/bash/bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/isolation-consumers.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" TMPDIR="$work/tmp" GOCACHE="$work/cache" GOPATH="$work/go"
export GOTOOLCHAIN=local GOENV=off GOPROXY=off GOSUMDB=off GOMAXPROCS=2
export CC="$fixtures/cc/bin/cc" CXX="$fixtures/cc/bin/c++"
mkdir -p "$HOME" "$TMPDIR" "$destination"
cd "$work"
cat > c.c <<'EOF'
#include <stdio.h>
int main(void) { puts("42"); return 0; }
EOF
cat > cpp.cc <<'EOF'
#include <iostream>
int main() { std::cout << 42 << '\n'; }
EOF
cat > pure.go <<'EOF'
package main
import "fmt"
func main() { fmt.Println(42) }
EOF
cat > cgo.go <<'EOF'
package main
// static int answer(void) { return 42; }
import "C"
import "fmt"
func main() { fmt.Println(C.answer()) }
EOF
"$CC" c.c -o "$destination/c"
cxxlib=$(readlink -f "$fixtures/libcxx")
"$CXX" cpp.cc -L"$cxxlib/lib" -Wl,-rpath,"$cxxlib/lib" -o "$destination/cpp"
CGO_ENABLED=0 go build -p 2 -o "$destination/pure" pure.go
CGO_ENABLED=1 go build -p 2 -o "$destination/cgo" cgo.go
for program in c cpp pure cgo; do
    test "$("$destination/$program")" = 42
done
printf 'NATIVE_CONSUMERS_PASS\n' > "$destination/result"
