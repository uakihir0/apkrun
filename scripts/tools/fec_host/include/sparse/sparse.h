/*
 * Host declarations for the bounded libsparse compatibility implementation.
 *
 * Copyright (C) 2026 APKRun contributors
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef APKRUN_FEC_SPARSE_H
#define APKRUN_FEC_SPARSE_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sparse_file;
typedef int (*sparse_file_callback_t)(
    void* private_data,
    const void* data,
    size_t len
);

struct sparse_file* sparse_file_import(int fd, bool sparse, bool crc);
struct sparse_file* sparse_file_import_auto(int fd, bool crc, bool verbose);
int64_t sparse_file_len(struct sparse_file* file, bool sparse, bool crc);
int sparse_file_callback(
    struct sparse_file* file,
    bool sparse,
    bool crc,
    sparse_file_callback_t callback,
    void* private_data
);
void sparse_file_destroy(struct sparse_file* file);

#ifdef __cplusplus
}
#endif

#endif  // APKRUN_FEC_SPARSE_H
