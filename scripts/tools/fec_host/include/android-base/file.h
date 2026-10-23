/*
 * Minimal host compatibility surface for AOSP verity/fec.
 *
 * Copyright (C) 2026 APKRun contributors
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef APKRUN_FEC_ANDROID_BASE_FILE_H
#define APKRUN_FEC_ANDROID_BASE_FILE_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

namespace android::base {

inline bool ReadFully(int fd, void* data, uint64_t byte_count) {
    auto* cursor = static_cast<unsigned char*>(data);
    while (byte_count > 0) {
        const size_t requested = byte_count > static_cast<uint64_t>(SIZE_MAX)
            ? SIZE_MAX
            : static_cast<size_t>(byte_count);
        const ssize_t count = read(fd, cursor, requested);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return false;
        }
        cursor += count;
        byte_count -= static_cast<uint64_t>(count);
    }
    return true;
}

inline bool WriteFully(int fd, const void* data, uint64_t byte_count) {
    auto* cursor = static_cast<const unsigned char*>(data);
    while (byte_count > 0) {
        const size_t requested = byte_count > static_cast<uint64_t>(SIZE_MAX)
            ? SIZE_MAX
            : static_cast<size_t>(byte_count);
        const ssize_t count = write(fd, cursor, requested);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return false;
        }
        cursor += count;
        byte_count -= static_cast<uint64_t>(count);
    }
    return true;
}

}  // namespace android::base

#endif  // APKRUN_FEC_ANDROID_BASE_FILE_H
