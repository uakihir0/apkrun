/*
 * Minimal large-file compatibility macros for AOSP verity/fec on macOS.
 *
 * Copyright (C) 2026 APKRun contributors
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef APKRUN_FEC_UTILS_COMPAT_H
#define APKRUN_FEC_UTILS_COMPAT_H

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef TEMP_FAILURE_RETRY
#define TEMP_FAILURE_RETRY(expression)                  \
    (__extension__({                                    \
        long int _result;                               \
        do {                                            \
            _result = (long int)(expression);           \
        } while (_result == -1L && errno == EINTR);    \
        _result;                                        \
    }))
#endif

#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif

#ifndef lseek64
#define lseek64 lseek
#endif

#endif  // APKRUN_FEC_UTILS_COMPAT_H
