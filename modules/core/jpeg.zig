//! Minimal JFIF/JPEG decoder — enough to read the base-colour atlases that ship
//! inside glTF (.glb) files when they're JPEG rather than PNG (CesiumMan, and many
//! real-world exporters, embed a *progressive* JPEG). Pure CPU + allocator, no
//! GPU: it runs headless and deterministically, like the sibling `png.zig`.
//!
//! Supported: 8-bit **baseline** (SOF0) and **progressive** (SOF2) Huffman JPEGs,
//! any component count (1 = grayscale, 3 = YCbCr), arbitrary chroma subsampling
//! (upsampled by replication), and restart intervals. Always expands to RGBA8
//! (the format the render layer uploads). Arithmetic coding, 12-bit, hierarchical
//! and lossless modes are rejected — no glTF exporter emits them.
//!
//! The algorithm follows the JPEG spec (ITU-T T.81): per-component coefficient
//! buffers are filled across one-or-more entropy scans, then dequantised, inverse
//! DCT'd, upsampled, and colour-converted in one finishing pass. This unified
//! "accumulate coefficients, finish once" shape is what lets baseline and
//! progressive share a single path.

const std = @import("std");
const assets = @import("assets.zig");

pub const Error = error{
    NotJpeg,
    Truncated,
    Unsupported,
    BadHuffman,
};

// Markers (the byte after 0xFF).
const M_SOI = 0xD8;
const M_EOI = 0xD9;
const M_SOF0 = 0xC0; // baseline DCT
const M_SOF1 = 0xC1; // extended sequential DCT (Huffman) — decoded like baseline
const M_SOF2 = 0xC2; // progressive DCT
const M_DHT = 0xC4;
const M_DQT = 0xDB;
const M_DRI = 0xDD;
const M_SOS = 0xDA;

/// Zigzag scan order → natural (row-major) 8×8 index. The trailing repeats guard
/// a corrupt stream whose run-length walks `k` past 63 (it writes harmlessly into
/// the last cell instead of out of bounds), mirroring the standard decoders.
const dezigzag = [64 + 16]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
};

/// `cos((2x+1)·u·π/16)` and the DC scale, precomputed for the separable inverse
/// DCT (one-time at decode, so a clear float IDCT is fine).
const idct_cos: [8][8]f32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [8][8]f32 = undefined;
    for (0..8) |x| for (0..8) |u| {
        t[x][u] = @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0);
    };
    break :blk t;
};
const idct_cu: [8]f32 = blk: {
    var c: [8]f32 = undefined;
    c[0] = 1.0 / @sqrt(2.0);
    for (1..8) |u| c[u] = 1.0;
    break :blk c;
};

/// A built canonical Huffman table (JPEG spec Annex C/F): decode is a bit-at-a-time
/// walk comparing the accumulated code against `maxcode[len]`.
const Huffman = struct {
    symbols: [256]u8 = undefined,
    mincode: [17]i32 = undefined,
    maxcode: [18]i32 = undefined, // maxcode[17] = sentinel
    valptr: [17]i32 = undefined,
    defined: bool = false,

    fn build(self: *Huffman, counts: *const [16]u8) void {
        var code: i32 = 0;
        var k: usize = 0;
        for (1..17) |l| {
            const n = counts[l - 1];
            if (n == 0) {
                self.maxcode[l] = -1;
            } else {
                self.valptr[l] = @intCast(k);
                self.mincode[l] = code;
                code += n;
                k += n;
                self.maxcode[l] = code - 1;
            }
            code <<= 1;
        }
        self.maxcode[17] = std.math.maxInt(i32);
        self.defined = true;
    }
};

/// Per-component frame state: sampling factors, the quant/Huffman selectors set by
/// each scan, the running DC predictor, and the full-frame coefficient buffer that
/// the (possibly multiple) scans fill before the finishing pass reads it.
const Component = struct {
    id: u8,
    h: u8, // horizontal sampling factor
    v: u8, // vertical sampling factor
    tq: u8, // quant table selector
    td: u8 = 0, // DC Huffman selector (per scan)
    ta: u8 = 0, // AC Huffman selector (per scan)
    dc_pred: i32 = 0,
    blocks_w: usize = 0, // coeff stride, in 8×8 blocks (mcus_per_line × h)
    blocks_h: usize = 0,
    coeff: []i16 = &.{}, // blocks_w·blocks_h·64, natural order, zero-init
};

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buf: u32 = 0,
    bit_cnt: u6 = 0,
    /// Nonzero once entropy-coded data hits a real marker (FF xx, xx≠00/≠FF): the
    /// scan is over; from here the reader feeds zero bits so an over-read decodes
    /// to harmless zeros instead of faulting.
    marker: u8 = 0,

    /// Top up the bit buffer to ≥24 bits, removing 0xFF byte-stuffing and latching
    /// the first real marker encountered (after which only zero bits are fed).
    fn refill(self: *BitReader) void {
        while (self.bit_cnt <= 24) {
            if (self.marker != 0 or self.pos >= self.data.len) {
                self.bit_buf <<= 8;
                self.bit_cnt += 8;
                continue;
            }
            var b = self.data[self.pos];
            self.pos += 1;
            if (b == 0xFF) {
                while (self.pos < self.data.len and self.data[self.pos] == 0xFF) self.pos += 1;
                const c: u8 = if (self.pos < self.data.len) self.data[self.pos] else 0;
                self.pos += 1;
                if (c == 0) {
                    b = 0xFF; // stuffed: a literal 0xFF data byte
                } else {
                    self.marker = c; // a real marker — stop consuming, feed zeros
                    self.bit_buf <<= 8;
                    self.bit_cnt += 8;
                    continue;
                }
            }
            self.bit_buf = (self.bit_buf << 8) | b;
            self.bit_cnt += 8;
        }
    }

    fn getBit(self: *BitReader) i32 {
        if (self.bit_cnt < 1) self.refill();
        self.bit_cnt -= 1;
        return @intCast((self.bit_buf >> @intCast(self.bit_cnt)) & 1);
    }

    fn getBits(self: *BitReader, n: u5) u32 {
        if (n == 0) return 0;
        if (self.bit_cnt < n) self.refill();
        self.bit_cnt -= n;
        return (self.bit_buf >> @intCast(self.bit_cnt)) & ((@as(u32, 1) << n) - 1);
    }

    /// JPEG EXTEND: turn `n` received magnitude bits into a signed coefficient.
    fn receiveExtend(self: *BitReader, n: u5) i32 {
        const v: i32 = @intCast(self.getBits(n));
        const vt = @as(i32, 1) << (n - 1);
        return if (v < vt) v + (@as(i32, -1) << n) + 1 else v;
    }

    fn decodeHuff(self: *BitReader, hf: *const Huffman) !u8 {
        var code: i32 = 0;
        for (1..17) |l| {
            code = (code << 1) | self.getBit();
            if (code <= hf.maxcode[l]) {
                const idx: usize = @intCast(hf.valptr[l] + (code - hf.mincode[l]));
                return hf.symbols[idx];
            }
        }
        return Error.BadHuffman;
    }

    /// Resynchronise at a restart interval: drop partial bits and step past the
    /// upcoming RSTn marker (consumed lazily by `refill`, or scanned for here).
    fn restart(self: *BitReader) void {
        self.bit_buf = 0;
        self.bit_cnt = 0;
        if (self.marker >= 0xD0 and self.marker <= 0xD7) {
            self.marker = 0;
            return;
        }
        self.marker = 0;
        while (self.pos + 1 < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == 0xFF) {
                const c = self.data[self.pos + 1];
                if (c >= 0xD0 and c <= 0xD7) {
                    self.pos += 2;
                    return;
                }
                if (c != 0 and c != 0xFF) return; // some other marker: leave it
            }
        }
    }
};

const Decoder = struct {
    a: std.mem.Allocator,
    width: u16 = 0,
    height: u16 = 0,
    progressive: bool = false,
    ncomp: u8 = 0,
    comps: [4]Component = undefined,
    qt: [4][64]u16 = undefined, // quant tables, zigzag order
    hdc: [4]Huffman = @splat(.{}),
    hac: [4]Huffman = @splat(.{}),
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcus_per_line: usize = 0,
    mcus_per_col: usize = 0,
    restart_interval: usize = 0,
    eob_run: i32 = 0,

    fn deinit(self: *Decoder) void {
        for (self.comps[0..self.ncomp]) |*c| if (c.coeff.len != 0) self.a.free(c.coeff);
    }

    fn parseFrame(self: *Decoder, seg: []const u8) !void {
        if (seg.len < 6) return Error.Truncated;
        if (seg[0] != 8) return Error.Unsupported; // 8-bit precision only
        self.height = std.mem.readInt(u16, seg[1..3], .big);
        self.width = std.mem.readInt(u16, seg[3..5], .big);
        self.ncomp = seg[5];
        if (self.ncomp == 0 or self.ncomp > 4) return Error.Unsupported;
        if (seg.len < 6 + @as(usize, self.ncomp) * 3) return Error.Truncated;
        self.hmax = 1;
        self.vmax = 1;
        for (0..self.ncomp) |i| {
            const o = 6 + i * 3;
            const samp = seg[o + 1];
            self.comps[i] = .{ .id = seg[o], .h = samp >> 4, .v = samp & 0xF, .tq = seg[o + 2] };
            if (self.comps[i].h == 0 or self.comps[i].v == 0) return Error.Unsupported;
            self.hmax = @max(self.hmax, self.comps[i].h);
            self.vmax = @max(self.vmax, self.comps[i].v);
        }
        self.mcus_per_line = (@as(usize, self.width) + 8 * self.hmax - 1) / (8 * self.hmax);
        self.mcus_per_col = (@as(usize, self.height) + 8 * self.vmax - 1) / (8 * self.vmax);
        for (self.comps[0..self.ncomp]) |*c| {
            c.blocks_w = self.mcus_per_line * c.h;
            c.blocks_h = self.mcus_per_col * c.v;
            c.coeff = try self.a.alloc(i16, c.blocks_w * c.blocks_h * 64);
            @memset(c.coeff, 0);
        }
    }

    fn parseHuffman(self: *Decoder, seg: []const u8) !void {
        var p: usize = 0;
        while (p < seg.len) {
            const tc_th = seg[p];
            const tc = tc_th >> 4; // 0 = DC, 1 = AC
            const th = tc_th & 0xF;
            if (th > 3 or tc > 1) return Error.Unsupported;
            p += 1;
            if (p + 16 > seg.len) return Error.Truncated;
            var counts: [16]u8 = undefined;
            var total: usize = 0;
            for (0..16) |i| {
                counts[i] = seg[p + i];
                total += counts[i];
            }
            p += 16;
            if (total > 256 or p + total > seg.len) return Error.Truncated;
            const tbl = if (tc == 0) &self.hdc[th] else &self.hac[th];
            @memcpy(tbl.symbols[0..total], seg[p .. p + total]);
            tbl.build(&counts);
            p += total;
        }
    }

    fn parseQuant(self: *Decoder, seg: []const u8) !void {
        var p: usize = 0;
        while (p < seg.len) {
            const pq_tq = seg[p];
            const pq = pq_tq >> 4; // 0 = 8-bit, 1 = 16-bit
            const tq = pq_tq & 0xF;
            if (tq > 3) return Error.Unsupported;
            p += 1;
            if (pq == 0) {
                if (p + 64 > seg.len) return Error.Truncated;
                for (0..64) |i| self.qt[tq][i] = seg[p + i];
                p += 64;
            } else {
                if (p + 128 > seg.len) return Error.Truncated;
                for (0..64) |i| self.qt[tq][i] = std.mem.readInt(u16, seg[p + i * 2 ..][0..2], .big);
                p += 128;
            }
        }
    }

    /// Parse a scan header and decode its entropy-coded segment. `data` starts at
    /// the SOS payload (length-prefixed header, then the entropy bytes); returns
    /// the offset of the next marker so the caller resumes segment parsing.
    fn decodeScan(self: *Decoder, data: []const u8) !usize {
        const hlen = std.mem.readInt(u16, data[0..2], .big);
        const ns = data[2];
        if (ns == 0 or ns > self.ncomp) return Error.Unsupported;
        var scan_comps: [4]usize = undefined; // indices into self.comps
        for (0..ns) |i| {
            const cs = data[3 + i * 2];
            const tdta = data[4 + i * 2];
            // find the component with this id
            var ci: usize = 0;
            while (ci < self.ncomp and self.comps[ci].id != cs) ci += 1;
            if (ci == self.ncomp) return Error.Unsupported;
            self.comps[ci].td = tdta >> 4;
            self.comps[ci].ta = tdta & 0xF;
            scan_comps[i] = ci;
        }
        const ss = data[3 + @as(usize, ns) * 2];
        const se = data[4 + @as(usize, ns) * 2];
        const ahal = data[5 + @as(usize, ns) * 2];
        const ah: u5 = @intCast(ahal >> 4);
        const al: u5 = @intCast(ahal & 0xF);

        var br = BitReader{ .data = data, .pos = hlen };
        self.eob_run = 0;
        for (self.comps[0..self.ncomp]) |*c| c.dc_pred = 0;
        var todo: usize = if (self.restart_interval != 0) self.restart_interval else std.math.maxInt(usize);

        if (ns == 1) {
            // Non-interleaved: walk this component's own block grid.
            const c = &self.comps[scan_comps[0]];
            const bw = ((@as(usize, self.width) * c.h + self.hmax - 1) / self.hmax + 7) / 8;
            const bh = ((@as(usize, self.height) * c.v + self.vmax - 1) / self.vmax + 7) / 8;
            for (0..bh) |by| {
                for (0..bw) |bx| {
                    const blk = c.coeff[(by * c.blocks_w + bx) * 64 ..][0..64];
                    try self.decodeBlock(&br, c, blk, ss, se, ah, al);
                    todo -= 1;
                    if (todo == 0) {
                        br.restart();
                        for (self.comps[0..self.ncomp]) |*cc| cc.dc_pred = 0;
                        self.eob_run = 0;
                        todo = self.restart_interval;
                    }
                }
            }
        } else {
            // Interleaved: walk MCUs, each holding h×v blocks per component.
            for (0..self.mcus_per_col) |mcy| {
                for (0..self.mcus_per_line) |mcx| {
                    for (scan_comps[0..ns]) |ci| {
                        const c = &self.comps[ci];
                        for (0..c.v) |vy| {
                            for (0..c.h) |hx| {
                                const bx = mcx * c.h + hx;
                                const by = mcy * c.v + vy;
                                const blk = c.coeff[(by * c.blocks_w + bx) * 64 ..][0..64];
                                try self.decodeBlock(&br, c, blk, ss, se, ah, al);
                            }
                        }
                    }
                    todo -= 1;
                    if (todo == 0) {
                        br.restart();
                        for (self.comps[0..self.ncomp]) |*cc| cc.dc_pred = 0;
                        self.eob_run = 0;
                        todo = self.restart_interval;
                    }
                }
            }
        }

        // Advance the caller past the entropy bytes to the next real marker.
        var p = br.pos;
        if (br.marker != 0) {
            // refill consumed FF + marker; rewind to the FF so the caller sees it.
            return rewindToMarker(data, p);
        }
        while (p + 1 < data.len) : (p += 1) {
            if (data[p] == 0xFF and data[p + 1] != 0 and (data[p + 1] < 0xD0 or data[p + 1] > 0xD7) and data[p + 1] != 0xFF) return p;
        }
        return data.len;
    }

    fn decodeBlock(self: *Decoder, br: *BitReader, c: *Component, blk: []i16, ss: u8, se: u8, ah: u5, al: u5) !void {
        if (!self.progressive) {
            try self.decodeBaseline(br, c, blk);
        } else if (ss == 0) {
            if (ah == 0) {
                const t = try br.decodeHuff(&self.hdc[c.td]);
                const diff = if (t != 0) br.receiveExtend(@intCast(t)) else 0;
                c.dc_pred += diff;
                blk[0] = @intCast(c.dc_pred * (@as(i32, 1) << al));
            } else if (br.getBit() != 0) {
                blk[0] += @intCast(@as(i32, 1) << al);
            }
        } else if (ah == 0) {
            try self.decodeAcFirst(br, c, blk, ss, se, al);
        } else {
            try self.decodeAcRefine(br, c, blk, ss, se, al);
        }
    }

    fn decodeBaseline(self: *Decoder, br: *BitReader, c: *Component, blk: []i16) !void {
        const t = try br.decodeHuff(&self.hdc[c.td]);
        const diff = if (t != 0) br.receiveExtend(@intCast(t)) else 0;
        c.dc_pred += diff;
        blk[0] = @intCast(c.dc_pred);
        var k: usize = 1;
        while (k < 64) {
            const rs = try br.decodeHuff(&self.hac[c.ta]);
            const r = rs >> 4;
            const s: u5 = @intCast(rs & 0xF);
            if (s == 0) {
                if (r != 15) break; // EOB
                k += 16; // ZRL: 16 zeros
            } else {
                k += r;
                if (k > 63) break;
                blk[dezigzag[k]] = @intCast(br.receiveExtend(s));
                k += 1;
            }
        }
    }

    fn decodeAcFirst(self: *Decoder, br: *BitReader, c: *Component, blk: []i16, ss: u8, se: u8, al: u5) !void {
        if (self.eob_run > 0) {
            self.eob_run -= 1;
            return;
        }
        var k: usize = ss;
        while (k <= se) {
            const rs = try br.decodeHuff(&self.hac[c.ta]);
            const r: u5 = @intCast(rs >> 4);
            const s: u5 = @intCast(rs & 0xF);
            if (s == 0) {
                if (r < 15) {
                    self.eob_run = (@as(i32, 1) << r) - 1;
                    if (r != 0) self.eob_run += @intCast(br.getBits(r));
                    break;
                }
                k += 16; // r == 15: skip 16 zeros
            } else {
                k += r;
                if (k > se) break;
                blk[dezigzag[k]] = @intCast(br.receiveExtend(s) * (@as(i32, 1) << al));
                k += 1;
            }
        }
    }

    fn decodeAcRefine(self: *Decoder, br: *BitReader, c: *Component, blk: []i16, ss: u8, se: u8, al: u5) !void {
        const bit: i16 = @intCast(@as(i32, 1) << al);
        if (self.eob_run != 0) {
            // Inside an EOB run: only correction bits for already-nonzero coeffs.
            self.eob_run -= 1;
            var k: usize = ss;
            while (k <= se) : (k += 1) {
                const idx = dezigzag[k];
                if (blk[idx] != 0 and br.getBit() != 0 and (blk[idx] & bit) == 0) {
                    blk[idx] += if (blk[idx] > 0) bit else -bit;
                }
            }
            return;
        }
        var k: usize = ss;
        while (true) {
            const rs = try br.decodeHuff(&self.hac[c.ta]);
            var r: i32 = @intCast(rs >> 4);
            const s = rs & 0xF;
            var newval: i16 = 0;
            if (s == 0) {
                if (r < 15) {
                    self.eob_run = (@as(i32, 1) << @intCast(r)) - 1;
                    if (r != 0) self.eob_run += @intCast(br.getBits(@intCast(r)));
                    r = 64; // force end-of-block: refine remaining nonzeros, place none
                }
                // else r == 15: skip 16 zero coeffs (still refining nonzeros en route)
            } else {
                // s must be 1 in refinement: the sign of the newly nonzero coeff.
                newval = if (br.getBit() != 0) bit else -bit;
            }
            // Walk coefficients: refine nonzeros (correction bit), count zeros, and
            // place the new coefficient once `r` zeros have passed.
            while (k <= se) {
                const idx = dezigzag[k];
                k += 1;
                if (blk[idx] != 0) {
                    if (br.getBit() != 0 and (blk[idx] & bit) == 0) {
                        blk[idx] += if (blk[idx] > 0) bit else -bit;
                    }
                } else {
                    if (r == 0) {
                        if (newval != 0) blk[idx] = newval;
                        break;
                    }
                    r -= 1;
                }
            }
            if (k > se) break;
        }
    }

    /// Dequantise + inverse-DCT every block, then upsample and colour-convert into
    /// a fresh RGBA8 image. Component planes live at their own (subsampled) size.
    fn finish(self: *Decoder) !assets.Texture {
        const planes = try self.a.alloc([]u8, self.ncomp);
        defer {
            for (planes) |p| if (p.len != 0) self.a.free(p);
            self.a.free(planes);
        }
        for (planes) |*p| p.* = &.{};

        for (self.comps[0..self.ncomp], 0..) |*c, ci| {
            const pw = c.blocks_w * 8;
            const ph = c.blocks_h * 8;
            const plane = try self.a.alloc(u8, pw * ph);
            planes[ci] = plane;
            // Quant table in natural order (it's stored zigzag).
            var dq: [64]f32 = undefined;
            for (0..64) |k| dq[dezigzag[k]] = @floatFromInt(self.qt[c.tq][k]);
            var blk: [64]f32 = undefined;
            for (0..c.blocks_h) |by| {
                for (0..c.blocks_w) |bx| {
                    const src = c.coeff[(by * c.blocks_w + bx) * 64 ..][0..64];
                    for (0..64) |i| blk[i] = @as(f32, @floatFromInt(src[i])) * dq[i];
                    idct8x8(&blk);
                    for (0..8) |py| {
                        const row = (by * 8 + py) * pw + bx * 8;
                        for (0..8) |px| plane[row + px] = clampByte(blk[py * 8 + px] + 128.0);
                    }
                }
            }
        }

        const w: usize = self.width;
        const h: usize = self.height;
        const out = try self.a.alloc(u8, w * h * 4);
        errdefer self.a.free(out);
        for (0..h) |y| {
            for (0..w) |x| {
                const d = out[(y * w + x) * 4 ..][0..4];
                if (self.ncomp == 1) {
                    const yy = sample(planes[0], self.comps[0], self.hmax, self.vmax, x, y);
                    d.* = .{ yy, yy, yy, 255 };
                } else {
                    const yy: f32 = @floatFromInt(sample(planes[0], self.comps[0], self.hmax, self.vmax, x, y));
                    const cb: f32 = @as(f32, @floatFromInt(sample(planes[1], self.comps[1], self.hmax, self.vmax, x, y))) - 128.0;
                    const cr: f32 = @as(f32, @floatFromInt(sample(planes[2], self.comps[2], self.hmax, self.vmax, x, y))) - 128.0;
                    d.* = .{
                        clampByte(yy + 1.402 * cr),
                        clampByte(yy - 0.344136 * cb - 0.714136 * cr),
                        clampByte(yy + 1.772 * cb),
                        255,
                    };
                }
            }
        }
        return .{ .width = self.width, .height = self.height, .pixels = out };
    }
};

/// Sample a component plane at full-image pixel (x,y), replicating subsampled
/// chroma up to luma resolution (nearest — fine for a base-colour atlas).
fn sample(plane: []const u8, c: Component, hmax: u8, vmax: u8, x: usize, y: usize) u8 {
    const pw = c.blocks_w * 8;
    const ph = c.blocks_h * 8;
    var cx = (x * c.h) / hmax;
    var cy = (y * c.v) / vmax;
    if (cx >= pw) cx = pw - 1;
    if (cy >= ph) cy = ph - 1;
    return plane[cy * pw + cx];
}

fn clampByte(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(v);
}

/// Separable inverse DCT of an 8×8 block, in place.
fn idct8x8(b: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    // rows
    for (0..8) |r| {
        for (0..8) |x| {
            var s: f32 = 0;
            for (0..8) |u| s += idct_cu[u] * b[r * 8 + u] * idct_cos[x][u];
            tmp[r * 8 + x] = 0.5 * s;
        }
    }
    // columns
    for (0..8) |col| {
        for (0..8) |y| {
            var s: f32 = 0;
            for (0..8) |u| s += idct_cu[u] * tmp[u * 8 + col] * idct_cos[y][u];
            b[y * 8 + col] = 0.5 * s;
        }
    }
}

fn rewindToMarker(data: []const u8, from: usize) usize {
    var p = from;
    while (p > 0) : (p -= 1) {
        if (data[p - 1] == 0xFF) return p - 1;
    }
    return from;
}

/// Decode a JPEG byte slice into an allocator-owned RGBA8 `Texture`.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !assets.Texture {
    if (data.len < 2 or data[0] != 0xFF or data[1] != M_SOI) return Error.NotJpeg;
    var dec = Decoder{ .a = allocator };
    defer dec.deinit();

    var pos: usize = 2;
    var have_frame = false;
    while (pos + 1 < data.len) {
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }
        // Skip fill bytes.
        var mk = data[pos + 1];
        pos += 2;
        while (mk == 0xFF and pos < data.len) {
            mk = data[pos];
            pos += 1;
        }
        if (mk == M_EOI) break;
        if (mk == M_SOI or (mk >= 0xD0 and mk <= 0xD7)) continue; // standalone markers
        if (pos + 2 > data.len) return Error.Truncated;
        const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (seg_len < 2 or pos + seg_len > data.len) return Error.Truncated;
        const seg = data[pos + 2 .. pos + seg_len];

        switch (mk) {
            M_SOF0, M_SOF1, M_SOF2 => {
                dec.progressive = (mk == M_SOF2);
                try dec.parseFrame(seg);
                have_frame = true;
                pos += seg_len;
            },
            M_DHT => {
                try dec.parseHuffman(seg);
                pos += seg_len;
            },
            M_DQT => {
                try dec.parseQuant(seg);
                pos += seg_len;
            },
            M_DRI => {
                dec.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
                pos += seg_len;
            },
            M_SOS => {
                if (!have_frame) return Error.Unsupported;
                // The scan owns its header AND the entropy bytes that follow; let
                // the scan decoder consume both and report the next marker offset.
                const next = try dec.decodeScan(data[pos..]);
                pos += next;
            },
            0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return Error.Unsupported, // arithmetic / lossless / hierarchical
            else => pos += seg_len, // APPn, COM, DNL, … — skip
        }
    }
    if (!have_frame) return Error.Unsupported;
    return dec.finish();
}

test "rejects non-JPEG bytes" {
    const bad = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4 }; // PNG signature
    try std.testing.expectError(Error.NotJpeg, decode(std.testing.allocator, &bad));
}

test "EXTEND turns received bits into signed coefficients" {
    var br = BitReader{ .data = &.{ 0b10110000, 0 }, .pos = 0 };
    // 3 bits "101" = 5, in range [4,7] -> stays 5
    try std.testing.expectEqual(@as(i32, 5), br.receiveExtend(3));
    // next 3 bits "100" = 4 -> 4 >= 4 stays 4? value 100b=4, vt=4, 4<4 false -> 4
    try std.testing.expectEqual(@as(i32, 4), br.receiveExtend(3));
}
