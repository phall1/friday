#ifndef FRIDAY_HOST_H
#define FRIDAY_HOST_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct friday_host_native friday_host_native;
typedef void (*friday_host_event_callback)(void *context, const uint8_t *bytes, size_t length);
typedef void (*friday_host_completion_callback)(void *context, uint64_t key, bool ok, const uint8_t *bytes, size_t length);

friday_host_native *friday_host_native_create(const char *data_dir, friday_host_event_callback callback, void *context);
void friday_host_native_destroy(friday_host_native *host);
size_t friday_host_native_request(friday_host_native *host, const char *name, size_t name_length, const uint8_t *payload, size_t payload_length, bool *ok, uint8_t *output, size_t output_capacity);
void friday_host_native_request_async(friday_host_native *host, uint64_t key, const char *name, size_t name_length, const uint8_t *payload, size_t payload_length, friday_host_completion_callback callback, void *context);
void friday_host_native_cancel(friday_host_native *host, uint64_t key);

#ifdef __cplusplus
}
#endif

#endif
