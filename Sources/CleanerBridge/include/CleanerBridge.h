#ifndef CLEANER_BRIDGE_H
#define CLEANER_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct CMSession CMSession;
typedef struct { uint8_t *data; size_t len; } CMBuffer;
// JSON UTF-8, version 1. Inputs are borrowed only for the duration of the call.
CMSession *cm_session_new(const uint8_t *request, size_t len);
// Poll returns at most 128 candidates. Each returned buffer must be freed exactly once.
CMBuffer cm_session_poll(CMSession *session);
// Validate a scanned candidate ID, current exclusions and running bundle IDs.
CMBuffer cm_session_validate(CMSession *session, const uint8_t *request, size_t len);
void cm_session_cancel(CMSession *session);
// Cancels and joins workers. Caller must not use the session concurrently with free.
void cm_session_free(CMSession *session);
void cm_buffer_free(CMBuffer buffer);
#endif
