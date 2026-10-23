/*
 * Bounded libsparse compatibility layer used to feed AOSP verity/fec.
 *
 * Copyright (C) 2026 APKRun contributors
 * Licensed under the Apache License, Version 2.0.
 */

#include <sparse/sparse.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kSparseMagic = 0xed26ff3a;
constexpr uint16_t kSparseMajorVersion = 1;
constexpr uint16_t kSparseMinorVersion = 0;
constexpr uint16_t kChunkRaw = 0xcac1;
constexpr uint16_t kChunkFill = 0xcac2;
constexpr uint16_t kChunkDontCare = 0xcac3;
constexpr uint16_t kChunkCrc32 = 0xcac4;
constexpr size_t kSparseHeaderSize = 28;
constexpr size_t kChunkHeaderSize = 12;
constexpr size_t kCallbackChunkSize = 64 * 1024;

enum class ChunkKind { Raw, Fill, DontCare };

struct Chunk {
    ChunkKind kind;
    uint64_t logical_size;
    uint64_t file_offset;
    std::array<unsigned char, 4> fill{};
};

bool read_exact_at(int fd, void* destination, size_t length, uint64_t offset) {
    auto* out = static_cast<unsigned char*>(destination);
    size_t consumed = 0;
    while (consumed < length) {
        const ssize_t count = pread(
            fd,
            out + consumed,
            length - consumed,
            static_cast<off_t>(offset + consumed)
        );
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return false;
        }
        consumed += static_cast<size_t>(count);
    }
    return true;
}

uint16_t le16(const unsigned char* p) {
    return static_cast<uint16_t>(p[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(p[1]) << 8);
}

uint32_t le32(const unsigned char* p) {
    return static_cast<uint32_t>(p[0]) |
        (static_cast<uint32_t>(p[1]) << 8) |
        (static_cast<uint32_t>(p[2]) << 16) |
        (static_cast<uint32_t>(p[3]) << 24);
}

bool checked_add(uint64_t left, uint64_t right, uint64_t* result) {
    if (right > std::numeric_limits<uint64_t>::max() - left) {
        return false;
    }
    *result = left + right;
    return true;
}

bool checked_multiply(uint64_t left, uint64_t right, uint64_t* result) {
    if (left != 0 && right > std::numeric_limits<uint64_t>::max() / left) {
        return false;
    }
    *result = left * right;
    return true;
}

struct sparse_file* import_file(int fd, bool accept_raw);

}  // namespace

struct sparse_file {
    int fd;
    uint64_t logical_size;
    std::vector<Chunk> chunks;
};

namespace {

struct sparse_file* import_file(int fd, bool accept_raw) {
    struct stat status {};
    if (fstat(fd, &status) != 0 || status.st_size < 0) {
        return nullptr;
    }
    const uint64_t file_size = static_cast<uint64_t>(status.st_size);
    unsigned char header[kSparseHeaderSize]{};
    if (file_size < sizeof(uint32_t) ||
        !read_exact_at(fd, header, sizeof(uint32_t), 0)) {
        return nullptr;
    }

    if (le32(header) != kSparseMagic) {
        if (!accept_raw) {
            return nullptr;
        }
        auto* file = new (std::nothrow) sparse_file;
        if (file == nullptr) {
            return nullptr;
        }
        file->fd = fd;
        file->logical_size = file_size;
        if (file_size != 0) {
            file->chunks.push_back(Chunk{ChunkKind::Raw, file_size, 0, {}});
        }
        return file;
    }

    if (file_size < kSparseHeaderSize ||
        !read_exact_at(fd, header, sizeof(header), 0)) {
        return nullptr;
    }
    const uint16_t major_version = le16(header + 4);
    const uint16_t minor_version = le16(header + 6);
    const uint16_t file_header_size = le16(header + 8);
    const uint16_t chunk_header_size = le16(header + 10);
    const uint32_t block_size = le32(header + 12);
    const uint32_t total_blocks = le32(header + 16);
    const uint32_t total_chunks = le32(header + 20);
    if (major_version != kSparseMajorVersion ||
        minor_version > kSparseMinorVersion ||
        file_header_size < kSparseHeaderSize ||
        chunk_header_size < kChunkHeaderSize ||
        block_size == 0 || (block_size & 3) != 0) {
        return nullptr;
    }

    uint64_t logical_size = 0;
    if (!checked_multiply(total_blocks, block_size, &logical_size)) {
        return nullptr;
    }

    auto* file = new (std::nothrow) sparse_file;
    if (file == nullptr) {
        return nullptr;
    }
    file->fd = fd;
    file->logical_size = logical_size;
    uint64_t position = file_header_size;
    uint64_t output_blocks = 0;
    for (uint32_t index = 0; index < total_chunks; ++index) {
        unsigned char chunk_header[kChunkHeaderSize]{};
        if (position > file_size ||
            file_size - position < chunk_header_size ||
            !read_exact_at(fd, chunk_header, sizeof(chunk_header), position)) {
            delete file;
            return nullptr;
        }
        const uint16_t type = le16(chunk_header);
        const uint32_t chunk_blocks = le32(chunk_header + 4);
        const uint32_t total_size = le32(chunk_header + 8);
        if (total_size < chunk_header_size) {
            delete file;
            return nullptr;
        }
        uint64_t next_position = 0;
        if (!checked_add(position, total_size, &next_position) ||
            next_position > file_size) {
            delete file;
            return nullptr;
        }
        uint64_t logical_chunk_size = 0;
        if (!checked_multiply(chunk_blocks, block_size, &logical_chunk_size)) {
            delete file;
            return nullptr;
        }

        const uint64_t payload_offset = position + chunk_header_size;
        const uint32_t payload_size = total_size - chunk_header_size;
        if (type == kChunkRaw) {
            if (logical_chunk_size != payload_size ||
                chunk_blocks > total_blocks - output_blocks) {
                delete file;
                return nullptr;
            }
            file->chunks.push_back(
                Chunk{ChunkKind::Raw, logical_chunk_size, payload_offset, {}}
            );
            output_blocks += chunk_blocks;
        } else if (type == kChunkFill) {
            if (payload_size != 4 || chunk_blocks > total_blocks - output_blocks) {
                delete file;
                return nullptr;
            }
            Chunk chunk{ChunkKind::Fill, logical_chunk_size, 0, {}};
            if (!read_exact_at(fd, chunk.fill.data(), chunk.fill.size(), payload_offset)) {
                delete file;
                return nullptr;
            }
            file->chunks.push_back(chunk);
            output_blocks += chunk_blocks;
        } else if (type == kChunkDontCare) {
            if (payload_size != 0 ||
                chunk_blocks > total_blocks - output_blocks) {
                delete file;
                return nullptr;
            }
            file->chunks.push_back(
                Chunk{ChunkKind::DontCare, logical_chunk_size, 0, {}}
            );
            output_blocks += chunk_blocks;
        } else if (type == kChunkCrc32) {
            if (chunk_blocks != 0 || payload_size != 4) {
                delete file;
                return nullptr;
            }
        } else {
            delete file;
            return nullptr;
        }
        position = next_position;
    }
    if (position != file_size || output_blocks != total_blocks) {
        delete file;
        return nullptr;
    }
    return file;
}

bool emit_data(
    sparse_file_callback_t callback,
    void* private_data,
    const void* data,
    size_t length
) {
    return callback(private_data, data, length) == 0;
}

}  // namespace

extern "C" {

struct sparse_file* sparse_file_import(int fd, bool, bool) {
    return import_file(fd, false);
}

struct sparse_file* sparse_file_import_auto(int fd, bool, bool) {
    return import_file(fd, true);
}

int64_t sparse_file_len(struct sparse_file* file, bool, bool) {
    if (file == nullptr ||
        file->logical_size > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        return -1;
    }
    return static_cast<int64_t>(file->logical_size);
}

int sparse_file_callback(
    struct sparse_file* file,
    bool,
    bool,
    sparse_file_callback_t callback,
    void* private_data
) {
    if (file == nullptr || callback == nullptr) {
        return -1;
    }
    std::array<unsigned char, kCallbackChunkSize> buffer{};
    for (const Chunk& chunk : file->chunks) {
        uint64_t consumed = 0;
        while (consumed < chunk.logical_size) {
            const size_t count = static_cast<size_t>(std::min<uint64_t>(
                buffer.size(),
                chunk.logical_size - consumed
            ));
            if (chunk.kind == ChunkKind::Raw) {
                if (!read_exact_at(
                        file->fd,
                        buffer.data(),
                        count,
                        chunk.file_offset + consumed
                    ) ||
                    !emit_data(callback, private_data, buffer.data(), count)) {
                    return -1;
                }
            } else if (chunk.kind == ChunkKind::Fill) {
                for (size_t index = 0; index < count; ++index) {
                    buffer[index] = chunk.fill[(consumed + index) % chunk.fill.size()];
                }
                if (!emit_data(callback, private_data, buffer.data(), count)) {
                    return -1;
                }
            } else if (!emit_data(callback, private_data, nullptr, count)) {
                return -1;
            }
            consumed += count;
        }
    }
    return 0;
}

void sparse_file_destroy(struct sparse_file* file) {
    delete file;
}

}  // extern "C"
