#ifndef SPATIAL_PAKE_H
#define SPATIAL_PAKE_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32) && defined(SPATIAL_PAKE_SHARED)
#define SPATIAL_PAKE_API __declspec(dllexport)
#else
#define SPATIAL_PAKE_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct spatial_pake spatial_pake;
/* role: 0 = client/Alice, 1 = host/Bob. Names are ordered local, peer.
 * PIN is exactly four ASCII digits. Each handle represents ONE attempt.
 * No deterministic RNG or secret export interface exists. */
SPATIAL_PAKE_API spatial_pake *spatial_pake_create(int role,
    const uint8_t *pin, size_t pin_len,
    const uint8_t *local_name, size_t local_len,
    const uint8_t *peer_name, size_t peer_len,
    uint8_t *message, size_t message_len);
/* Consumes the attempt even on failure. Success produces 64 secret bytes;
 * callers must confirm the key against a role/channel-bound transcript. */
SPATIAL_PAKE_API int spatial_pake_finish(spatial_pake *state,
    const uint8_t *peer_message, size_t peer_len,
    uint8_t *key, size_t key_len);
SPATIAL_PAKE_API void spatial_pake_destroy(spatial_pake *state);
SPATIAL_PAKE_API void spatial_pake_cleanse(uint8_t *bytes, size_t length);
#ifdef __cplusplus
}
#endif
#endif
