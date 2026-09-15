#include <assert.h>
#include <stdio.h>

extern unsigned __int128 __udivti3(unsigned __int128, unsigned __int128);
extern unsigned __int128 __umodti3(unsigned __int128, unsigned __int128);
extern __int128 __divti3(__int128, __int128);
extern __int128 __modti3(__int128, __int128);
extern unsigned __int128 __fixunsdfti(double);

int main(void)
{
    unsigned __int128 numerator = ((unsigned __int128)1 << 100) + 12345;
    unsigned __int128 quotient =
        ((unsigned __int128)0x6eb3e453ULL << 64) + 0x06eb3e45306eb531ULL;
    assert(__udivti3(numerator, 37) == quotient);
    assert(__umodti3(numerator, 37) == 36);
    assert(__divti3(-(__int128)numerator, 37) == -(__int128)quotient);
    assert(__modti3(-(__int128)numerator, 37) == -36);
    assert(__fixunsdfti(0x1p100) == ((unsigned __int128)1 << 100));
    puts("native compiler-rt builtins passed");
    return 0;
}
