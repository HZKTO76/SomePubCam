// java.util.zip's Inflater (a zlib stream: its header, the DEFLATE data, Adler-32) and CRC32 for the engine's own data files, header
// only and with no library: P683's 'SFD2' film arrays (FilmSpectral.parse, tools/film_pack.py) are read on the iPhone, the iPad and
// the host checks alike, none of which links zlib. The decoder is RFC 1951 as Mark Adler's puff.c reads it (stored, fixed and
// dynamic Huffman blocks, canonical codes decoded a bit at a time); a damaged stream throws.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace scam_post {
namespace Inflate {

/// java.util.zip.CRC32 of n bytes
inline uint32_t crc32(const uint8_t* p, size_t n) {
    static const std::array<uint32_t, 256> table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

/// java.util.zip.Adler32 of n bytes
inline uint32_t adler32(const uint8_t* p, size_t n) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < n; i++) {
        a = (a + p[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

namespace detail {

[[noreturn]] inline void damaged(const char* why) { throw std::runtime_error(std::string("inflate: ") + why); }

/// the input's bits, least significant first
struct Bits {
    const uint8_t* in;
    size_t n, at = 0;
    uint32_t buf = 0;
    int count = 0;

    int take(int k) {
        uint32_t v = buf;
        while (count < k) {
            if (at >= n) damaged("the data ends early");
            v |= uint32_t(in[at++]) << count;
            count += 8;
        }
        buf = k < 32 ? v >> k : 0;
        count -= k;
        return int(v & ((1u << k) - 1u));
    }
};

/// a canonical Huffman code: the number of codes of each length and the symbols in code order
struct Huffman {
    std::array<int16_t, 16> count{};
    std::vector<int16_t> symbol;
};

/// puff.c construct: 0 a complete code, > 0 an incomplete one, < 0 an over-subscribed one
inline int build(Huffman& h, const int16_t* length, int n) {
    h.count.fill(0);
    for (int s = 0; s < n; s++) h.count[size_t(length[s])]++;
    if (h.count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len < 16; len++) {
        left <<= 1;
        left -= h.count[size_t(len)];
        if (left < 0) return left;
    }
    std::array<int16_t, 16> offs{};
    for (int len = 1; len < 15; len++) offs[size_t(len + 1)] = int16_t(offs[size_t(len)] + h.count[size_t(len)]);
    h.symbol.assign(size_t(n), 0);
    for (int s = 0; s < n; s++)
        if (length[s] != 0) h.symbol[size_t(offs[size_t(length[s])]++)] = int16_t(s);
    return left;
}

inline int decode(Bits& s, const Huffman& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len < 16; len++) {
        code |= s.take(1);
        const int count = h.count[size_t(len)];
        if (code - count < first) return h.symbol[size_t(index + (code - first))];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    damaged("a code that is not in the table");
}

/// the literals and length / distance pairs of one block, up to its end code
inline void codes(Bits& s, std::vector<uint8_t>& out, size_t limit, const Huffman& lencode, const Huffman& distcode) {
    static const int16_t LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                                      163, 195, 227, 258};
    static const int16_t LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
    static const int32_t DBASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                      2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
    static const int16_t DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
    for (;;) {
        int symbol = decode(s, lencode);
        if (symbol < 256) {
            if (out.size() >= limit) damaged("more data than expected");
            out.push_back(uint8_t(symbol));
        } else if (symbol > 256) {
            symbol -= 257;
            if (symbol >= 29) damaged("a bad length code");
            const size_t len = size_t(LBASE[symbol] + s.take(LEXT[symbol]));
            const int d = decode(s, distcode);
            if (d >= 30) damaged("a bad distance code");
            const size_t dist = size_t(DBASE[d] + s.take(DEXT[d]));
            if (dist > out.size()) damaged("a distance before the start");
            if (out.size() + len > limit) damaged("more data than expected");
            const size_t from = out.size() - dist;
            for (size_t i = 0; i < len; i++) out.push_back(out[from + i]);
        } else {
            return;
        }
    }
}

inline void stored(Bits& s, std::vector<uint8_t>& out, size_t limit) {
    s.buf = 0;
    s.count = 0;
    if (s.n - s.at < 4) damaged("the data ends early");
    const unsigned len = unsigned(s.in[s.at]) | unsigned(s.in[s.at + 1]) << 8;
    const unsigned nlen = unsigned(s.in[s.at + 2]) | unsigned(s.in[s.at + 3]) << 8;
    s.at += 4;
    if (len != (~nlen & 0xFFFFu)) damaged("a stored block's length");
    if (s.n - s.at < len) damaged("the data ends early");
    if (out.size() + len > limit) damaged("more data than expected");
    out.insert(out.end(), s.in + s.at, s.in + s.at + len);
    s.at += len;
}

inline void fixed(Bits& s, std::vector<uint8_t>& out, size_t limit) {
    static const std::pair<Huffman, Huffman> tables = [] {
        std::pair<Huffman, Huffman> t;
        int16_t lengths[288];
        int sym = 0;
        for (; sym < 144; sym++) lengths[sym] = 8;
        for (; sym < 256; sym++) lengths[sym] = 9;
        for (; sym < 280; sym++) lengths[sym] = 7;
        for (; sym < 288; sym++) lengths[sym] = 8;
        build(t.first, lengths, 288);
        for (sym = 0; sym < 30; sym++) lengths[sym] = 5;
        build(t.second, lengths, 30);
        return t;
    }();
    codes(s, out, limit, tables.first, tables.second);
}

inline void dynamic(Bits& s, std::vector<uint8_t>& out, size_t limit) {
    static const int16_t ORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    const int nlen = s.take(5) + 257, ndist = s.take(5) + 1, ncode = s.take(4) + 4;
    if (nlen > 286 || ndist > 30) damaged("a bad code count");
    int16_t lengths[316] = {};
    for (int i = 0; i < ncode; i++) lengths[ORDER[i]] = int16_t(s.take(3));
    Huffman lencode, distcode;
    if (build(lencode, lengths, 19) != 0) damaged("an incomplete code length code");
    int index = 0;
    while (index < nlen + ndist) {
        int symbol = decode(s, lencode);
        if (symbol < 16) {
            lengths[index++] = int16_t(symbol);
            continue;
        }
        int16_t len = 0;
        if (symbol == 16) {
            if (index == 0) damaged("a repeat with no length before it");
            len = lengths[index - 1];
            symbol = 3 + s.take(2);
        } else if (symbol == 17) {
            symbol = 3 + s.take(3);
        } else {
            symbol = 11 + s.take(7);
        }
        if (index + symbol > nlen + ndist) damaged("too many lengths");
        while (symbol--) lengths[index++] = len;
    }
    if (lengths[256] == 0) damaged("no end-of-block code");
    int err = build(lencode, lengths, nlen);
    if (err < 0 || (err > 0 && nlen != lencode.count[0] + lencode.count[1])) damaged("an incomplete literal / length code");
    err = build(distcode, lengths + nlen, ndist);
    if (err < 0 || (err > 0 && ndist != distcode.count[0] + distcode.count[1])) damaged("an incomplete distance code");
    codes(s, out, limit, lencode, distcode);
}

} // namespace detail

/// Inflater (with the zlib wrapper) of p: exactly `expected` bytes and the stream's end, its Adler-32 checked; throws otherwise
inline std::vector<uint8_t> zlib(const uint8_t* p, size_t n, size_t expected) {
    using namespace detail;
    if (n < 6 || (p[0] & 0x0F) != 8 || (p[0] >> 4) > 7 || (unsigned(p[0]) * 256u + p[1]) % 31u != 0 || (p[1] & 0x20))
        damaged("not a zlib stream");
    std::vector<uint8_t> out;
    out.reserve(expected);
    Bits s{p + 2, n - 2};
    int last;
    do {
        last = s.take(1);
        const int type = s.take(2);
        if (type == 0) stored(s, out, expected);
        else if (type == 1) fixed(s, out, expected);
        else if (type == 2) dynamic(s, out, expected);
        else damaged("a bad block type");
    } while (!last);
    if (out.size() != expected) damaged("less data than expected");
    if (s.n - s.at < 4) damaged("no Adler-32");
    const uint8_t* a = s.in + s.at;
    if ((uint32_t(a[0]) << 24 | uint32_t(a[1]) << 16 | uint32_t(a[2]) << 8 | a[3]) != adler32(out.data(), out.size()))
        damaged("the Adler-32 does not match");
    return out;
}

} // namespace Inflate
} // namespace scam_post
