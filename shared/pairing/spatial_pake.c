#include "include/spatial_pake.h"
#include <openssl/curve25519.h>
#include <openssl/mem.h>

struct spatial_pake { SPAKE2_CTX *ctx; };

spatial_pake *spatial_pake_create(int role, const uint8_t *pin, size_t pin_len,
    const uint8_t *local_name, size_t local_len,
    const uint8_t *peer_name, size_t peer_len,
    uint8_t *message, size_t message_len) {
    if (!pin || pin_len != 4 || !local_name || !peer_name ||
        !local_len || local_len > 256 || !peer_len || peer_len > 256 ||
        !message || message_len != SPAKE2_MAX_MSG_SIZE || (role != 0 && role != 1)) return NULL;
    for (size_t i = 0; i < pin_len; ++i) if (pin[i] < '0' || pin[i] > '9') return NULL;
    spatial_pake *state = OPENSSL_zalloc(sizeof(*state));
    if (!state) return NULL;
    state->ctx = SPAKE2_CTX_new(role == 0 ? spake2_role_alice : spake2_role_bob,
        local_name, local_len, peer_name, peer_len);
    size_t produced = 0;
    if (!state->ctx || !SPAKE2_generate_msg(state->ctx, message, &produced,
            message_len, pin, pin_len) || produced != SPAKE2_MAX_MSG_SIZE) {
        OPENSSL_cleanse(message, message_len);
        spatial_pake_destroy(state);
        return NULL;
    }
    return state;
}

int spatial_pake_finish(spatial_pake *state, const uint8_t *peer_message,
    size_t peer_len, uint8_t *key, size_t key_len) {
    if (!state || !state->ctx) return 0;
    SPAKE2_CTX *ctx = state->ctx;
    state->ctx = NULL;
    size_t produced = 0;
    int ok = peer_message && peer_len == SPAKE2_MAX_MSG_SIZE && key &&
        key_len == SPAKE2_MAX_KEY_SIZE &&
        SPAKE2_process_msg(ctx, key, &produced, key_len, peer_message, peer_len) &&
        produced == SPAKE2_MAX_KEY_SIZE;
    SPAKE2_CTX_free(ctx);
    if (!ok && key && key_len == SPAKE2_MAX_KEY_SIZE) OPENSSL_cleanse(key, key_len);
    return ok;
}

void spatial_pake_destroy(spatial_pake *state) {
    if (!state) return;
    SPAKE2_CTX_free(state->ctx);
    OPENSSL_clear_free(state, sizeof(*state));
}

void spatial_pake_cleanse(uint8_t *bytes, size_t length) {
    if (bytes && length) OPENSSL_cleanse(bytes, length);
}
