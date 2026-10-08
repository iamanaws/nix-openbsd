/* Negative timestamps and boundaries for OpenBSD's signed 64-bit time_t. */
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

int main(void)
{
    _Static_assert(sizeof(time_t) == sizeof(int64_t), "requires 64-bit time_t");
    _Static_assert((time_t)-1 < 0, "requires signed time_t");
    _Static_assert(LDBL_MANT_DIG >= 64, "reference calculation needs 64-bit precision");
    const time_t times[] = {
        INT64_MIN, INT64_MIN + 1,
        -9007199254740993LL, -9007199254740992LL,
        -4294967297LL, -4294967296LL, -4294967295LL,
        -1, 0, 1,
        4294967295LL, 4294967296LL, 4294967297LL,
        9007199254740992LL, 9007199254740993LL,
        INT64_MAX - 1, INT64_MAX,
    };
    /* Use a volatile pointer so the compiler cannot substitute its builtin. */
    double (*volatile difference)(time_t, time_t) = difftime;
    unsigned failures = 0;
    const unsigned count = sizeof(times) / sizeof(times[0]);
    for (unsigned i = 0; i < count; ++i) {
        for (unsigned j = 0; j < count; ++j) {
            const double expected = (double)((long double)times[i] - (long double)times[j]);
            const double actual = difference(times[i], times[j]);
            if (actual != expected) {
                if (failures == 0)
                    fprintf(stderr, "difftime(%lld, %lld): got %.17g, expected %.17g\n",
                            (long long)times[i], (long long)times[j], actual, expected);
                ++failures;
            }
        }
    }
    printf("difftime: %u/%u cases passed\n", count * count - failures, count * count);
    return failures != 0;
}
