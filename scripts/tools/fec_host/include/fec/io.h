/*
 * Narrow host declaration shim for AOSP verity/fec.
 *
 * Copyright (C) 2015 The Android Open Source Project
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef APKRUN_FEC_IO_H
#define APKRUN_FEC_IO_H

#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <string>

#ifndef SHA256_DIGEST_LENGTH
#define SHA256_DIGEST_LENGTH 32
#endif

#define FEC_BLOCKSIZE 4096
#define FEC_DEFAULT_ROOTS 2
#define FEC_MAGIC 0xFECFECFE
#define FEC_VERSION 0
#define FEC_VERITY_DISABLE (1 << 8)

struct fec_header {
    uint32_t magic;
    uint32_t version;
    uint32_t size;
    uint32_t roots;
    uint32_t fec_size;
    uint64_t inp_size;
    uint8_t hash[SHA256_DIGEST_LENGTH];
} __attribute__((packed));

struct fec_ecc_metadata {
    bool valid;
    uint32_t roots;
    uint64_t blocks;
    uint64_t rounds;
    uint64_t start;
};

struct fec_verity_metadata {
    bool disabled;
    uint64_t data_size;
};

namespace fec {

// Metadata extraction belongs to libfec, which this host tool does not need
// for --encode, --decode, or --print-fec-size. Keep these modes explicit.
class io {
public:
    io(const std::string&, int = O_RDONLY, int = 0, int = FEC_DEFAULT_ROOTS) {}
    explicit operator bool() const { return false; }
    bool get_ecc_metadata(fec_ecc_metadata&) { return false; }
    bool get_verity_metadata(fec_verity_metadata&) { return false; }
};

}  // namespace fec

#endif  // APKRUN_FEC_IO_H
