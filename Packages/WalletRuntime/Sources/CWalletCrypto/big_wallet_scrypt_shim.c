// ∅ 2026 lil org

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int32_t bw_scrypt_romix_blocks(const uint32_t *input_words,
                               uint32_t *output_words,
                               size_t n,
                               size_t r,
                               size_t p);

int32_t bw_scrypt_romix_blocks_range(const uint32_t *input_words,
                                     uint32_t *output_words,
                                     size_t n,
                                     size_t r,
                                     size_t block_start,
                                     size_t block_count);

static void bw_scrypt_zero_memory(void *ptr, size_t byte_count) {
    volatile uint8_t *bytes = (volatile uint8_t *)ptr;
    while (byte_count > 0) {
        *bytes++ = 0;
        byte_count--;
    }
}

static void bw_scrypt_free_zero(void *ptr, size_t byte_count) {
    if (ptr != NULL) {
        bw_scrypt_zero_memory(ptr, byte_count);
        free(ptr);
    }
}

static inline uint32_t bw_scrypt_rotate_left(uint32_t value, uint32_t amount) {
    return (value << amount) | (value >> (32 - amount));
}

static void bw_scrypt_salsa20_8(uint32_t block[16]) {
    uint32_t x0 = block[0], x1 = block[1], x2 = block[2], x3 = block[3];
    uint32_t x4 = block[4], x5 = block[5], x6 = block[6], x7 = block[7];
    uint32_t x8 = block[8], x9 = block[9], x10 = block[10], x11 = block[11];
    uint32_t x12 = block[12], x13 = block[13], x14 = block[14], x15 = block[15];

    for (int round = 0; round < 4; round++) {
        x4 ^= bw_scrypt_rotate_left(x0 + x12, 7);
        x8 ^= bw_scrypt_rotate_left(x4 + x0, 9);
        x12 ^= bw_scrypt_rotate_left(x8 + x4, 13);
        x0 ^= bw_scrypt_rotate_left(x12 + x8, 18);
        x9 ^= bw_scrypt_rotate_left(x5 + x1, 7);
        x13 ^= bw_scrypt_rotate_left(x9 + x5, 9);
        x1 ^= bw_scrypt_rotate_left(x13 + x9, 13);
        x5 ^= bw_scrypt_rotate_left(x1 + x13, 18);
        x14 ^= bw_scrypt_rotate_left(x10 + x6, 7);
        x2 ^= bw_scrypt_rotate_left(x14 + x10, 9);
        x6 ^= bw_scrypt_rotate_left(x2 + x14, 13);
        x10 ^= bw_scrypt_rotate_left(x6 + x2, 18);
        x3 ^= bw_scrypt_rotate_left(x15 + x11, 7);
        x7 ^= bw_scrypt_rotate_left(x3 + x15, 9);
        x11 ^= bw_scrypt_rotate_left(x7 + x3, 13);
        x15 ^= bw_scrypt_rotate_left(x11 + x7, 18);

        x1 ^= bw_scrypt_rotate_left(x0 + x3, 7);
        x2 ^= bw_scrypt_rotate_left(x1 + x0, 9);
        x3 ^= bw_scrypt_rotate_left(x2 + x1, 13);
        x0 ^= bw_scrypt_rotate_left(x3 + x2, 18);
        x6 ^= bw_scrypt_rotate_left(x5 + x4, 7);
        x7 ^= bw_scrypt_rotate_left(x6 + x5, 9);
        x4 ^= bw_scrypt_rotate_left(x7 + x6, 13);
        x5 ^= bw_scrypt_rotate_left(x4 + x7, 18);
        x11 ^= bw_scrypt_rotate_left(x10 + x9, 7);
        x8 ^= bw_scrypt_rotate_left(x11 + x10, 9);
        x9 ^= bw_scrypt_rotate_left(x8 + x11, 13);
        x10 ^= bw_scrypt_rotate_left(x9 + x8, 18);
        x12 ^= bw_scrypt_rotate_left(x15 + x14, 7);
        x13 ^= bw_scrypt_rotate_left(x12 + x15, 9);
        x14 ^= bw_scrypt_rotate_left(x13 + x12, 13);
        x15 ^= bw_scrypt_rotate_left(x14 + x13, 18);
    }

    block[0] += x0;
    block[1] += x1;
    block[2] += x2;
    block[3] += x3;
    block[4] += x4;
    block[5] += x5;
    block[6] += x6;
    block[7] += x7;
    block[8] += x8;
    block[9] += x9;
    block[10] += x10;
    block[11] += x11;
    block[12] += x12;
    block[13] += x13;
    block[14] += x14;
    block[15] += x15;
}

static void bw_scrypt_block_mix(uint32_t *block, uint32_t *scratch, uint32_t *x, size_t r) {
    const size_t chunk_count = 2 * r;
    memcpy(x, block + (chunk_count - 1) * 16, 16 * sizeof(uint32_t));

    for (size_t index = 0; index < chunk_count; index++) {
        const uint32_t *input = block + index * 16;
        for (size_t word = 0; word < 16; word++) {
            x[word] ^= input[word];
        }
        bw_scrypt_salsa20_8(x);
        const size_t output_offset = ((index & 1) == 0 ? index / 2 : r + index / 2) * 16;
        memcpy(scratch + output_offset, x, 16 * sizeof(uint32_t));
    }

    memcpy(block, scratch, chunk_count * 16 * sizeof(uint32_t));
}

static inline uint64_t bw_scrypt_integerify(const uint32_t *block, size_t r) {
    const uint32_t *value = block + (2 * r - 1) * 16;
    return ((uint64_t)value[1] << 32) | value[0];
}

static void bw_scrypt_romix_preallocated(const uint32_t *input_words,
                                         uint32_t *output_words,
                                         size_t n,
                                         size_t r,
                                         uint32_t *block,
                                         uint32_t *scratch,
                                         uint32_t *x,
                                         uint32_t *v) {
    const size_t block_words = 32 * r;
    memcpy(block, input_words, block_words * sizeof(uint32_t));

    for (size_t index = 0; index < n; index++) {
        memcpy(v + index * block_words, block, block_words * sizeof(uint32_t));
        bw_scrypt_block_mix(block, scratch, x, r);
    }

    for (size_t index = 0; index < n; index++) {
        const size_t offset = (size_t)(bw_scrypt_integerify(block, r) & (uint64_t)(n - 1)) * block_words;
        const uint32_t *selected = v + offset;
        for (size_t word = 0; word < block_words; word++) {
            block[word] ^= selected[word];
        }
        bw_scrypt_block_mix(block, scratch, x, r);
    }

    memcpy(output_words, block, block_words * sizeof(uint32_t));
}

int32_t bw_scrypt_romix_blocks(const uint32_t *input_words,
                               uint32_t *output_words,
                               size_t n,
                               size_t r,
                               size_t p) {
    return bw_scrypt_romix_blocks_range(input_words, output_words, n, r, 0, p);
}

int32_t bw_scrypt_romix_blocks_range(const uint32_t *input_words,
                                     uint32_t *output_words,
                                     size_t n,
                                     size_t r,
                                     size_t block_start,
                                     size_t block_count) {
    if (input_words == NULL || output_words == NULL || n <= 1 || r == 0 || block_count == 0 || (n & (n - 1)) != 0) {
        return 0;
    }

    const size_t block_words = 32 * r;
    if (block_words / 32 != r ||
        block_count > SIZE_MAX - block_start ||
        n > SIZE_MAX / block_words ||
        block_words > SIZE_MAX / sizeof(uint32_t)) {
        return 0;
    }

    const size_t block_end = block_start + block_count;
    if (block_end > SIZE_MAX / block_words) {
        return 0;
    }

    const size_t v_words = n * block_words;
    if (v_words > SIZE_MAX / sizeof(uint32_t)) {
        return 0;
    }

    const size_t block_bytes = block_words * sizeof(uint32_t);
    const size_t x_bytes = 16 * sizeof(uint32_t);
    const size_t v_bytes = v_words * sizeof(uint32_t);

    uint32_t *block = malloc(block_bytes);
    uint32_t *scratch = malloc(block_bytes);
    uint32_t *x = malloc(x_bytes);
    uint32_t *v = malloc(v_bytes);

    if (block == NULL || scratch == NULL || x == NULL || v == NULL) {
        free(block);
        free(scratch);
        free(x);
        free(v);
        return 0;
    }

    for (size_t block_index = block_start; block_index < block_end; block_index++) {
        const size_t offset = block_index * block_words;
        bw_scrypt_romix_preallocated(input_words + offset,
                                     output_words + offset,
                                     n,
                                     r,
                                     block,
                                     scratch,
                                     x,
                                     v);
    }

    bw_scrypt_free_zero(block, block_bytes);
    bw_scrypt_free_zero(scratch, block_bytes);
    bw_scrypt_free_zero(x, x_bytes);
    bw_scrypt_free_zero(v, v_bytes);
    return 1;
}
