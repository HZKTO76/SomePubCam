// ClipBandTiles.java one to one (P671, speed): the TILE x TILE tiles of the frame that hold a flagged pixel (worker clip flag bits
// 0 - 3), marked in the same walk of the flags as «Inpaint opposed»'s count, and activeMap's tiles within the clip band's reach
// (scamhdr/clipmask + scamhdr/clipband BAND_TILES): outside them both passes return the very value they computed before, so the
// photo is the same bit for bit; a shot with no flagged pixel skips both passes. Marking is conservative: an 8-byte word with a
// flag marks the tiles of its first and its last byte.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace scam_post {

class ClipBandTiles {
public:
    /// Tile side, px (a power of two).
    static constexpr int TILE = 32;
    const int width, height, tilesX, tilesY;

    /// create: a map for a frame of width x height flags in `parts` parallel parts, or null when it does not fit
    static std::unique_ptr<ClipBandTiles> create(int width, int height, int64_t bytes, int parts) {
        if (width <= 0 || height <= 0 || int64_t(width) * height != bytes || parts <= 0 || parts > 128) return nullptr;
        const int64_t tiles = ((int64_t(width) + TILE - 1) / TILE) * ((int64_t(height) + TILE - 1) / TILE);
        if (tiles * parts / 8 > 4LL * 1024 * 1024) return nullptr;
        try {
            return std::unique_ptr<ClipBandTiles>(new ClipBandTiles(width, height, parts));
        } catch (const std::bad_alloc&) {
            return nullptr;
        }
    }

    /// mark: the tile of flag byte `index` in part `part`'s bits
    void mark(int part, int64_t index) {
        const int y = int(index / width), x = int(index - int64_t(y) * width);
        const int tile = (y / TILE) * tilesX + x / TILE;
        parts_[size_t(part)][size_t(unsigned(tile) >> 6)] |= uint64_t(1) << (tile & 63);
    }

    /// scan: the flagged tiles of bytes [start, end) of flags into part `part` (any of flag bits 0 - 3)
    void scan(const uint8_t* flags, int64_t start, int64_t end, int part) {
        int64_t i = start;
        for (; i + 8 <= end; i += 8) {
            uint64_t value;
            std::memcpy(&value, flags + i, 8); // the test is the same for either byte order
            if ((((value & 0x0F0F0F0F0F0F0F0FULL) + 0x7F7F7F7F7F7F7F7FULL) & 0x8080808080808080ULL) != 0) {
                mark(part, i);
                mark(part, i + 7);
            }
        }
        for (; i < end; i++) if ((flags[i] & 15) != 0) mark(part, i);
    }

    /// flagged: the flagged tiles (parts combined), one bit each, row by row
    std::vector<uint64_t> flagged() const {
        std::vector<uint64_t> all(parts_[0].size(), 0);
        for (const auto& p : parts_) for (size_t i = 0; i < all.size(); i++) all[i] |= p[i];
        return all;
    }

    /// activeMap: the tiles whose pixels may have a flagged pixel within `reach` px (the flagged tiles widened by whole tiles), one
    /// byte each (255 = draw, 0 = the pixel stays), row by row; empty when no tile is flagged at all
    std::vector<uint8_t> activeMap(int reach) const {
        const std::vector<uint64_t> bits = flagged();
        const int grow = std::max(1, (std::max(0, reach) + TILE - 1) / TILE);
        std::vector<uint8_t> map(size_t(tilesX) * size_t(tilesY), 0);
        bool any = false;
        for (size_t w = 0; w < bits.size(); w++) {
            for (uint64_t b = bits[w]; b != 0; b &= b - 1) {
                const int tile = int(w << 6) + __builtin_ctzll(b), ty = tile / tilesX, tx = tile - ty * tilesX;
                any = true;
                for (int y = std::max(0, ty - grow); y <= std::min(tilesY - 1, ty + grow); y++)
                    for (int x = std::max(0, tx - grow); x <= std::min(tilesX - 1, tx + grow); x++) map[size_t(y) * tilesX + x] = 255;
            }
        }
        return any ? map : std::vector<uint8_t>();
    }

    /// share: the share of tiles set in map, for the log
    static float share(const std::vector<uint8_t>& map) {
        if (map.empty()) return 0.f;
        int n = 0;
        for (uint8_t b : map) if (b != 0) n++;
        return float(n) / float(map.size());
    }

private:
    std::vector<std::vector<uint64_t>> parts_;

    ClipBandTiles(int w, int h, int parts)
        : width(w), height(h), tilesX((w + TILE - 1) / TILE), tilesY((h + TILE - 1) / TILE),
          parts_(size_t(parts), std::vector<uint64_t>(size_t((tilesX * tilesY + 63) / 64), 0)) {}
};

} // namespace scam_post
