/*
 * SHA-256 compatibility shim using Apple's system CommonCrypto.
 *
 * Copyright (C) 2026 APKRun contributors
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef APKRUN_FEC_OPENSSL_SHA_H
#define APKRUN_FEC_OPENSSL_SHA_H

#include <CommonCrypto/CommonDigest.h>

#include <stddef.h>
#include <stdint.h>

#define SHA256_DIGEST_LENGTH CC_SHA256_DIGEST_LENGTH

static inline unsigned char* SHA256(
    const unsigned char* data,
    size_t length,
    unsigned char* digest
) {
    return CC_SHA256(data, (CC_LONG)length, digest);
}

#endif  // APKRUN_FEC_OPENSSL_SHA_H
