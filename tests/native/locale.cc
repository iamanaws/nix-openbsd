#include <cassert>
#include <codecvt>
#include <cwchar>
#include <locale>
#include <string>

int main()
{
    // OpenBSD provides UTF-8 conversion, but keeps C-locale number formatting.
    std::locale utf8("C.UTF-8");
    const auto &convert = std::use_facet<std::codecvt<wchar_t, char, std::mbstate_t>>(utf8);
    const std::string input = "\xc3\xa9\xe7\x95\x8c";
    std::mbstate_t state{};
    const char *next_in;
    wchar_t wide[2], *next_wide;
    assert(convert.in(state, input.data(), input.data() + input.size(), next_in,
                      wide, wide + 2, next_wide) == std::codecvt_base::ok);
    assert(next_in == input.data() + input.size() && next_wide == wide + 2);
    assert(wide[0] == L'\u00e9' && wide[1] == L'\u754c');
    state = {};
    const wchar_t *next_out;
    char output[5], *next_byte;
    assert(convert.out(state, wide, wide + 2, next_out,
                       output, output + 5, next_byte) == std::codecvt_base::ok);
    assert(next_out == wide + 2 && next_byte == output + 5);
    assert(std::string(output, 5) == input);
    const auto &characters = std::use_facet<std::ctype<wchar_t>>(utf8);
    assert(characters.toupper(L'\u00e9') == L'\u00c9');
    const auto &numbers = std::use_facet<std::numpunct<char>>(utf8);
    assert(numbers.decimal_point() == '.' && numbers.grouping().empty());
}
