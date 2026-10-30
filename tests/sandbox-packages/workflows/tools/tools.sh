set -euo pipefail
test "$EUID" -ne 0
case ":$PATH:" in *:/bin:*|*:/usr/bin:*|*:/usr/local/bin:*) exit 1;; esac
test "$(diff <(printf 'same\n') <(printf 'same\n'); printf done)" = done
printf 'pipe\n' | (read -r value; test "$value" = pipe)
test "$(printf 'answer\0' | xargs -0 printf '%s')" = answer
printf 'before\n' > edit.txt
printf '%s\n' '--- edit.txt' '+++ edit.txt' '@@ -1 +1 @@' '-before' '+after' | patch -p0
sed -i 's/after/42/' edit.txt
test "$(awk '{print $1}' edit.txt)" = 42
grep -Fx 42 edit.txt
mkdir tree unpacked
printf 'archive data\n' > tree/data
ln tree/data tree/hardlink
ln -s data tree/symlink
tar -cf tree.tar tree
for compressor in gzip bzip2 xz; do
    "$compressor" -c tree.tar > "tree.$compressor"
    "$compressor" -dc "tree.$compressor" | tar -xf - -C unpacked
    diff -r tree unpacked/tree
    test "$(stat -c %i unpacked/tree/data)" = "$(stat -c %i unpacked/tree/hardlink)"
    test "$(readlink unpacked/tree/symlink)" = data
    rm -rf unpacked/tree
done
find tree -type f -print0 | sort -z | xargs -0 sha256sum > checksums
sha256sum -c checksums
cat > answer.c <<'EOF'
int answer(void) { return 42; }
EOF
cat > main.c <<'EOF'
#include <stdio.h>
int answer(void);
int main(void) { int n = answer(); printf("%d\n", n); return n != 42; }
EOF
cat > Makefile <<'EOF'
all: answer
answer.o: answer.c
	$(CC) -c answer.c -o answer.o
libanswer.a: answer.o
	$(AR) crs libanswer.a answer.o
answer: main.c libanswer.a
	$(CC) main.c libanswer.a -o answer
EOF
make -j2
test "$(./answer)" = 42
printf '%s\n' '-x c -DNATIVE_RESPONSE=42 -fsyntax-only -' > compile.rsp
printf '_Static_assert(NATIVE_RESPONSE == 42, "response file");\n' | "$CC" @compile.rsp
cat > answer.pc <<EOF
prefix=$PWD
libdir=\${prefix}
Name: sandbox answer
Description: native archive consumer
Version: 1
Libs: -L\${libdir} -lanswer
EOF
PKG_CONFIG_PATH="$PWD" "$CC" main.c $(PKG_CONFIG_PATH="$PWD" pkg-config --libs answer) -o pkgconfig-answer
test "$(./pkgconfig-answer)" = 42
file answer | grep ELF
patchelf --print-rpath answer > rpath
git init repository
git -C repository config user.email sandbox@example.invalid
git -C repository config user.name 'Sandbox Test'
cp main.c repository/main.c
git -C repository add main.c
git -C repository commit -m fixture
git clone --no-local repository clone
git -C clone fsck --strict
git -C clone archive --format=tar HEAD | tar -xf - -C unpacked
cmp main.c unpacked/main.c
perl -Mthreads -MCompress::Raw::Zlib -MTime::HiRes -e '
  die unless threads->create(sub { 42 })->join == 42;
  die unless Compress::Raw::Zlib::zlib_version();
  die unless Time::HiRes::time() > 0;
'
printf 'NATIVE_TOOL_WORKFLOWS_PASS\n'
