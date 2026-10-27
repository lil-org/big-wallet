#include <stddef.h>
#include <stdint.h>

void bw_wallet_zero_memory(void *pointer, size_t count) {
    volatile uint8_t *bytes = (volatile uint8_t *)pointer;
    while (count > 0) {
        *bytes++ = 0;
        count--;
    }
}
