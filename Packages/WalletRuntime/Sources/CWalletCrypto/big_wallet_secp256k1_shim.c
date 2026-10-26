// ∅ 2026 lil org

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "secp256k1/include/secp256k1.h"
#include "secp256k1/include/secp256k1_recovery.h"

static secp256k1_context *bw_secp256k1_context = NULL;
static pthread_once_t bw_secp256k1_context_once = PTHREAD_ONCE_INIT;

static void bw_secp256k1_noop_callback(const char *message, void *data) {
    (void)message;
    (void)data;
}

static void bw_secp256k1_init_context(void) {
    unsigned char seed[32];
    bw_secp256k1_context = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    if (bw_secp256k1_context == NULL) {
        abort();
    }
    secp256k1_context_set_illegal_callback(bw_secp256k1_context, bw_secp256k1_noop_callback, NULL);
    arc4random_buf(seed, sizeof(seed));
    if (!secp256k1_context_randomize(bw_secp256k1_context, seed)) {
        memset(seed, 0, sizeof(seed));
        abort();
    }
    memset(seed, 0, sizeof(seed));
}

static const secp256k1_context *bw_secp256k1_get_context(void) {
    pthread_once(&bw_secp256k1_context_once, bw_secp256k1_init_context);
    return bw_secp256k1_context;
}

int32_t bw_secp256k1_is_valid_private_key(const uint8_t *private_key32) {
    if (private_key32 == NULL) {
        return 0;
    }
    return secp256k1_ec_seckey_verify(bw_secp256k1_get_context(), private_key32);
}

int32_t bw_secp256k1_create_public_key(const uint8_t *private_key32,
                                       uint8_t *public_key_out,
                                       size_t *public_key_len,
                                       int32_t compressed) {
    secp256k1_pubkey public_key;
    unsigned int flags = compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED;
    if (private_key32 == NULL || public_key_out == NULL || public_key_len == NULL) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_create(bw_secp256k1_get_context(), &public_key, private_key32)) {
        return 0;
    }
    *public_key_len = compressed ? 33 : 65;
    return secp256k1_ec_pubkey_serialize(bw_secp256k1_get_context(),
                                          public_key_out,
                                          public_key_len,
                                          &public_key,
                                          flags);
}

int32_t bw_secp256k1_is_valid_public_key(const uint8_t *public_key,
                                         size_t public_key_len) {
    secp256k1_pubkey parsed;
    if (public_key == NULL) {
        return 0;
    }
    return secp256k1_ec_pubkey_parse(bw_secp256k1_get_context(), &parsed, public_key, public_key_len);
}

int32_t bw_secp256k1_serialize_public_key(const uint8_t *public_key,
                                          size_t public_key_len,
                                          uint8_t *public_key_out,
                                          size_t *public_key_out_len,
                                          int32_t compressed) {
    secp256k1_pubkey parsed;
    unsigned int flags = compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED;
    if (public_key == NULL || public_key_out == NULL || public_key_out_len == NULL) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_parse(bw_secp256k1_get_context(), &parsed, public_key, public_key_len)) {
        return 0;
    }
    *public_key_out_len = compressed ? 33 : 65;
    return secp256k1_ec_pubkey_serialize(bw_secp256k1_get_context(),
                                          public_key_out,
                                          public_key_out_len,
                                          &parsed,
                                          flags);
}

int32_t bw_secp256k1_sign_recoverable(const uint8_t *digest32,
                                      const uint8_t *private_key32,
                                      uint8_t *signature65_out) {
    secp256k1_ecdsa_recoverable_signature signature;
    int recovery_id = 0;
    if (digest32 == NULL || private_key32 == NULL || signature65_out == NULL) {
        return 0;
    }
    if (!secp256k1_ecdsa_sign_recoverable(bw_secp256k1_get_context(),
                                           &signature,
                                           digest32,
                                           private_key32,
                                           NULL,
                                           NULL)) {
        return 0;
    }
    if (!secp256k1_ecdsa_recoverable_signature_serialize_compact(bw_secp256k1_get_context(),
                                                                  signature65_out,
                                                                  &recovery_id,
                                                                  &signature)) {
        return 0;
    }
    signature65_out[64] = (uint8_t)recovery_id;
    return 1;
}

int32_t bw_secp256k1_recover_public_key(const uint8_t *digest32,
                                        const uint8_t *signature65,
                                        uint8_t *public_key65_out) {
    secp256k1_ecdsa_recoverable_signature signature;
    secp256k1_pubkey public_key;
    size_t public_key_len = 65;
    int recovery_id;
    if (digest32 == NULL || signature65 == NULL || public_key65_out == NULL) {
        return 0;
    }
    recovery_id = signature65[64];
    if (recovery_id >= 27) {
        recovery_id -= 27;
    }
    if (recovery_id < 0 || recovery_id > 3) {
        return 0;
    }
    if (!secp256k1_ecdsa_recoverable_signature_parse_compact(bw_secp256k1_get_context(),
                                                              &signature,
                                                              signature65,
                                                              recovery_id)) {
        return 0;
    }
    if (!secp256k1_ecdsa_recover(bw_secp256k1_get_context(), &public_key, &signature, digest32)) {
        return 0;
    }
    return secp256k1_ec_pubkey_serialize(bw_secp256k1_get_context(),
                                          public_key65_out,
                                          &public_key_len,
                                          &public_key,
                                          SECP256K1_EC_UNCOMPRESSED);
}

int32_t bw_secp256k1_combine_public_keys(const uint8_t *left_public_key,
                                         size_t left_public_key_len,
                                         const uint8_t *right_public_key,
                                         size_t right_public_key_len,
                                         uint8_t *public_key65_out) {
    secp256k1_pubkey left;
    secp256k1_pubkey right;
    secp256k1_pubkey combined;
    const secp256k1_pubkey *public_keys[2];
    size_t public_key_len = 65;
    if (left_public_key == NULL || right_public_key == NULL || public_key65_out == NULL) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_parse(bw_secp256k1_get_context(), &left, left_public_key, left_public_key_len)) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_parse(bw_secp256k1_get_context(), &right, right_public_key, right_public_key_len)) {
        return 0;
    }
    public_keys[0] = &left;
    public_keys[1] = &right;
    if (!secp256k1_ec_pubkey_combine(bw_secp256k1_get_context(), &combined, public_keys, 2)) {
        return 0;
    }
    return secp256k1_ec_pubkey_serialize(bw_secp256k1_get_context(),
                                          public_key65_out,
                                          &public_key_len,
                                          &combined,
                                          SECP256K1_EC_UNCOMPRESSED);
}

int32_t bw_secp256k1_tweak_add_private_key(const uint8_t *private_key32,
                                           const uint8_t *tweak32,
                                           uint8_t *private_key32_out) {
    if (private_key32 == NULL || tweak32 == NULL || private_key32_out == NULL) {
        return 0;
    }
    memcpy(private_key32_out, private_key32, 32);
    if (!secp256k1_ec_seckey_tweak_add(bw_secp256k1_get_context(), private_key32_out, tweak32)) {
        memset(private_key32_out, 0, 32);
        return 0;
    }
    return 1;
}
