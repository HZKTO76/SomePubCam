// P662 (item 4): scamera_rowcopy::copyRows puts every source row of a tile at its row of the bitmap and nothing else - the bytes
// TileBlitter's strip bitmap drawn with SRC puts there (TileBlitterTest) - for tight and padded strides, any thread count, any
// tile position and height (the last tile shorter).
#include "../app/src/main/cpp/scamera-rowcopy.h"
#include <cstdio>
#include <random>
#include <vector>

static bool check10BitFrame(size_t pad) {
    constexpr uint32_t width = 4096, height = 3073, tileRows = 256;
    constexpr size_t row = width * sizeof(uint32_t);
    const size_t stride = row + pad;
    std::mt19937 random(659);
    std::vector<uint32_t> tile(width * tileRows);
    std::vector<uint8_t> frame(stride * height, 0xA5);
    for (uint32_t y = 0; y < height; y += tileRows) {
        const uint32_t rows = std::min(tileRows, height - y);
        for (uint32_t &pixel : tile) pixel = 0xC0000000u | (random() & 0x3FFFFFFFu);
        const auto *src = reinterpret_cast<const uint8_t *>(tile.data());
        auto *dst = frame.data() + y * stride;
        scamera_rowcopy::copyRows(src, dst, row, stride, rows, 1);
        for (uint32_t r = 0; r < rows; ++r) {
            if (std::memcmp(src + r * row, dst + r * stride, row) != 0) return false;
            for (size_t b = row; b < stride; ++b)
                if (dst[r * stride + b] != 0xA5) return false;
        }
    }
    return true;
}

int main() {
    int cases = 0;
    for (uint32_t width : {1u, 7u, 256u, 8160u}) {
        for (size_t pad : {size_t(0), size_t(64)}) {
            const size_t row = size_t(width) * 4, stride = row + pad;
            const uint32_t height = 37;
            for (uint32_t y : {0u, 5u, 36u}) {
                for (uint32_t rows : {1u, 3u, 32u}) {
                    if (y + rows > height) continue;
                    for (int threads : {1, 2, 4, 8, 64}) {
                        std::vector<uint8_t> src(row * rows), dst(stride * height, 0xA5), want(dst);
                        for (size_t i = 0; i < src.size(); i++) src[i] = uint8_t(i * 131 + y * 7 + rows);
                        for (uint32_t r = 0; r < rows; r++)
                            for (size_t b = 0; b < row; b++) want[(y + r) * stride + b] = src[r * row + b];
                        scamera_rowcopy::copyRows(src.data(), dst.data() + size_t(y) * stride, row, stride, rows, threads);
                        if (dst != want) {
                            std::fprintf(stderr, "row copy differs: width %u pad %zu y %u rows %u threads %d\n", width, pad, y, rows, threads);
                            return 1;
                        }
                        cases++;
                    }
                }
            }
        }
    }
    for (size_t pad : {size_t(0), size_t(64)}) {
        if (!check10BitFrame(pad)) {
            std::fprintf(stderr, "10-bit frame differs: pad %zu\n", pad);
            return 1;
        }
        cases++;
    }
    std::printf("{\"check\": \"row_copy\", \"cases\": %d, \"identical\": true}\n", cases);
    return 0;
}
