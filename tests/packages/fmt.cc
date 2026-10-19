#include <fmt/format.h>
#include <fmt/ranges.h>
#include <stdexcept>
#include <vector>

int main() {
  if (fmt::format("{}: {:.2f}", "OpenBSD", 1.25) != "OpenBSD: 1.25" ||
      fmt::format("{}", fmt::join(std::vector<int>{1, 2, 3}, ",")) != "1,2,3" ||
      fmt::format("{:.3f}", 1.125L) != "1.125")
    throw std::runtime_error("fmt output mismatch");
  try {
    (void)fmt::format(fmt::runtime("{"), 1);
    throw std::runtime_error("fmt accepted an invalid format");
  } catch (const fmt::format_error &) {
  }
  fmt::print("PASS fmt: shared library, formatting, ranges and exceptions\n");
}
