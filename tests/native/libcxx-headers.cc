// Compile with and without C_HEADERS_FIRST, feature-test macros and Clang modules.
#ifdef C_HEADERS_FIRST
#include <locale.h>
#include <wchar.h>
#endif

#include <cassert>
#include <cwchar>
#include <locale>
#include <sstream>
#include <type_traits>

#ifdef EXPECT_XOPEN_SOURCE
static_assert(_XOPEN_SOURCE == EXPECT_XOPEN_SOURCE);
#endif
#ifdef EXPECT_POSIX_C_SOURCE
static_assert(_POSIX_C_SOURCE == EXPECT_POSIX_C_SOURCE);
#endif

// Both include orders must preserve the const and mutable C++ overloads.
static_assert(std::is_same_v<decltype(std::wcschr(static_cast<wchar_t*>(nullptr), L'x')), wchar_t*>);
static_assert(std::is_same_v<decltype(std::wcschr(static_cast<const wchar_t*>(nullptr), L'x')), const wchar_t*>);

int main() {
  std::istringstream input("42.5");
  input.imbue(std::locale::classic());
  double value = 0;
  input >> value;
  assert(!input.fail() && value == 42.5);

  std::mbstate_t state{};
  wchar_t wide = 0;
  assert(std::mbrtowc(&wide, "A", 1, &state) == 1);
  assert(wide == L'A' && std::mbsinit(&state));
}
