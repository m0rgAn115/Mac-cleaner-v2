#include <stdint.h>
#include <stddef.h>
typedef struct {
    uint64_t files, dirs, links, bytes, selected, selected_bytes, errors;
} RustStats;
int32_t rust_scan(const char *path, size_t workers, RustStats *output);
