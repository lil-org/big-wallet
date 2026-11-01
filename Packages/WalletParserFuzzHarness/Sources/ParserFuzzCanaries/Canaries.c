#include "ParserFuzzCanaries.h"
#include <stdlib.h>
#include <unistd.h>

__attribute__((noinline)) int bw_parser_fuzz_asan_canary(void) {
    volatile unsigned char *bytes = malloc(16);
    if (!bytes) abort();
    volatile size_t index = 24;
    bytes[index] = 1;
    int result = bytes[index];
    free((void *)bytes);
    return result;
}

void bw_parser_fuzz_rss_canary(void) {
    size_t count = 256 * 1024 * 1024;
    volatile unsigned char *bytes = malloc(count);
    if (!bytes) abort();
    for (size_t index = 0; index < count; index += 4096) bytes[index] = 1;
    for (;;) sleep(1);
}
