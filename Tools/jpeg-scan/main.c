// jpeg-scan — rewrites a JPEG's entropy coding as small as it can, without
// touching the image: the quantized DCT coefficients stay exactly as they are.
//
//     jpeg-scan [--effort fast|balanced|thorough|maximum] [--report] INPUT OUTPUT
//
// A progressive JPEG can split its coefficients into scans in many ways:
// which frequency bands go together, how many bits are held back for later
// refinement passes, whether the colour components share a DC scan. Each
// scan gets its own optimal Huffman table, so each costs what its own symbols
// cost. jpeg-scan reads the coefficients once and counts, for every candidate
// scan, exactly the symbols libjpeg would write (the same run lengths, EOB
// runs, correction bits and edge padding), prices them with libjpeg's own
// table builder, and picks the cheapest combination: dynamic programming
// over the band boundaries, per component and refinement level. libjpeg-turbo
// then writes the file with that scan script. The model only decides which
// script is written; it can never damage an image (and every result is
// checked by jpegcmp anyway).
//
// Exit status: 0 written, 2 unreadable or failed, 3 not supported (12-bit
// or lossless JPEG, damaged image data): the caller keeps the input.

#include <dispatch/dispatch.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "jpeglib.h"

// libjpeg's optimal Huffman table builder (jchuff.c, exported but not
// declared in jpeglib.h). Using the very same function makes the model's
// prices the ones the encoder will pay.
extern void jpeg_gen_optimal_table(j_compress_ptr cinfo, JHUFF_TBL *htbl, long freq[]);

// "fast" searches like balanced: writing the file takes most of the time.
enum { EFFORT_BALANCED, EFFORT_THOROUGH, EFFORT_MAXIMUM };

// Up to this many blocks (about 0.8 megapixels in colour) an image gets the
// full search and a real-encode check at every effort: milliseconds there,
// and a few bytes matter more on a small file.
#define SMALL_IMAGE_BLOCKS 20000

// Zigzag position -> natural (row-major) position.
static const int natural[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

// MARK: - Errors

struct error_manager {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
};

static void on_error(j_common_ptr info) { longjmp(((struct error_manager *)info->err)->jump, 1); }
static void silent(j_common_ptr info) { (void)info; }

static void *checked_malloc(size_t n) {
    void *p = calloc(1, n ? n : 1);
    if (!p) {
        fprintf(stderr, "jpeg-scan: out of memory\n");
        exit(2);
    }
    return p;
}

// MARK: - Coefficients

typedef struct {
    int h, v;               // sampling factors
    int wb, hb;             // width and height in blocks
    int dc_table;           // 0 for the first component, 1 for the others (libjpeg's default)
    short *dc;              // per block: the DC coefficient
    // The nonzero AC coefficients, block after block, in zigzag order: most
    // are zero, so the model only ever looks at these. Block b's are
    // nz[off[b]] .. nz[off[b + 1] - 1].
    size_t *off;
    unsigned char *pos;     // zigzag index, 1..63
    unsigned short *mag;    // absolute value
} Component;

typedef struct {
    int ncomp;
    Component comp[4];
    int mcus_per_row, mcu_rows;   // for interleaved scans
    int blocks_in_mcu;
} Image;

static void load(Image *img, j_decompress_ptr src, jvirt_barray_ptr *coefs) {
    img->ncomp = src->num_components;
    int max_h = 1, max_v = 1;
    for (int c = 0; c < img->ncomp; c++) {
        jpeg_component_info *ci = &src->comp_info[c];
        if (ci->h_samp_factor > max_h) max_h = ci->h_samp_factor;
        if (ci->v_samp_factor > max_v) max_v = ci->v_samp_factor;
    }
    img->mcus_per_row = (int)((src->image_width + max_h * 8 - 1) / (max_h * 8));
    img->mcu_rows = (int)((src->image_height + max_v * 8 - 1) / (max_v * 8));
    img->blocks_in_mcu = 0;
    for (int c = 0; c < img->ncomp; c++) {
        jpeg_component_info *ci = &src->comp_info[c];
        Component *k = &img->comp[c];
        k->h = ci->h_samp_factor;
        k->v = ci->v_samp_factor;
        k->wb = (int)ci->width_in_blocks;
        k->hb = (int)ci->height_in_blocks;
        k->dc_table = c == 0 ? 0 : 1;
        img->blocks_in_mcu += k->h * k->v;
        size_t blocks = (size_t)k->wb * k->hb, count = 0, capacity = blocks * 8 + 64;
        k->dc = checked_malloc(blocks * sizeof(short));
        k->off = checked_malloc((blocks + 1) * sizeof(size_t));
        k->pos = checked_malloc(capacity);
        k->mag = checked_malloc(capacity * sizeof(unsigned short));
        for (int row = 0; row < k->hb; row++) {
            JBLOCKARRAY buf = (*src->mem->access_virt_barray)((j_common_ptr)src, coefs[c], (JDIMENSION)row, 1, FALSE);
            for (int col = 0; col < k->wb; col++) {
                size_t b = (size_t)row * k->wb + col;
                const JCOEF *z = buf[0][col];
                k->dc[b] = z[0];
                k->off[b] = count;
                if (count + 63 > capacity) {
                    capacity *= 2;
                    k->pos = realloc(k->pos, capacity);
                    k->mag = realloc(k->mag, capacity * sizeof(unsigned short));
                    if (!k->pos || !k->mag) { fprintf(stderr, "jpeg-scan: out of memory\n"); exit(2); }
                }
                for (int i = 1; i < 64; i++) {
                    int v = z[natural[i]];
                    if (!v) continue;
                    k->pos[count] = (unsigned char)i;
                    k->mag[count] = (unsigned short)(v < 0 ? -v : v);
                    count++;
                }
            }
        }
        k->off[blocks] = count;
    }
}

static long total_blocks(const Image *img) {
    long blocks = 0;
    for (int c = 0; c < img->ncomp; c++) blocks += (long)img->comp[c].wb * img->comp[c].hb;
    return blocks;
}

// MARK: - Symbol statistics

typedef struct {
    long freq[257];
    long extra;             // raw bits that are not Huffman coded
} Stats;

static int nbits(int v) {
    int n = 0;
    while (v) { n++; v >>= 1; }
    return n;
}

// An EOB run: symbol (n << 4) followed by n bits, n = floor(log2(run)).
static void flush_eobrun(Stats *s, long *eobrun, long *be) {
    if (*eobrun > 0) {
        int n = nbits((int)*eobrun) - 1;
        s->freq[n << 4]++;
        s->extra += n + *be;
        *eobrun = 0;
        *be = 0;
    }
}

// AC first pass (jcphuff.c encode_mcu_AC_first) over one component.
static void stats_ac_first(const Component *k, int ss, int se, int al, Stats *s) {
    long eobrun = 0, be = 0;
    size_t blocks = (size_t)k->wb * k->hb;
    for (size_t b = 0; b < blocks; b++) {
        int prev = ss - 1;  // last position coded in this band
        for (size_t j = k->off[b]; j < k->off[b + 1]; j++) {
            int i = k->pos[j];
            if (i < ss) continue;
            if (i > se) break;
            int v = k->mag[j] >> al;
            if (!v) continue;
            int r = i - prev - 1;
            prev = i;
            flush_eobrun(s, &eobrun, &be);
            while (r > 15) { s->freq[0xF0]++; r -= 16; }
            int n = nbits(v);
            s->freq[(r << 4) + n]++;
            s->extra += n;
        }
        if (prev < se) {  // trailing zeros: one more block in the EOB run
            if (++eobrun == 0x7FFF) flush_eobrun(s, &eobrun, &be);
        }
    }
    flush_eobrun(s, &eobrun, &be);
}

// AC refinement (jcphuff.c encode_mcu_AC_refine): Ah = al + 1. Coefficients
// that were nonzero before (value > 1 now) only add a correction bit and
// don't end a zero run.
static void stats_ac_refine(const Component *k, int ss, int se, int al, Stats *s) {
    long eobrun = 0, be = 0;
    size_t blocks = (size_t)k->wb * k->hb;
    for (size_t b = 0; b < blocks; b++) {
        size_t first = k->off[b], end = k->off[b + 1];
        while (first < end && k->pos[first] < ss) first++;
        // Position of the last newly nonzero coefficient, relative to ss; 0
        // if none (as libjpeg: it only limits where ZRLs are written).
        int eob = 0;
        for (size_t j = first; j < end && k->pos[j] <= se; j++)
            if ((k->mag[j] >> al) == 1) eob = k->pos[j] - ss;
        int r = 0, br = 0, prev = ss - 1;
        for (size_t j = first; j < end; j++) {
            int i = k->pos[j];
            if (i > se) break;
            int t = k->mag[j] >> al;
            if (!t) continue;
            r += i - prev - 1;
            prev = i;
            while (r > 15 && i - ss <= eob) {
                flush_eobrun(s, &eobrun, &be);
                s->freq[0xF0]++;
                r -= 16;
                s->extra += br;
                br = 0;
            }
            if (t > 1) { br++; continue; }
            flush_eobrun(s, &eobrun, &be);
            s->freq[(r << 4) + 1]++;
            s->extra += 1 + br;
            br = 0;
            r = 0;
        }
        r += se - prev;
        if (r > 0 || br > 0) {
            eobrun++;
            be += br;
            if (eobrun == 0x7FFF || be > 1000 - 64 + 1) flush_eobrun(s, &eobrun, &be);
        }
    }
    flush_eobrun(s, &eobrun, &be);
}

// DC first pass over the given components; interleaved scans walk MCUs,
// with the padding blocks libjpeg adds at the right and bottom edges (their
// DC repeats the previous block's, so they cost one "difference 0" symbol).
// Returns the number of blocks coded, for the refinement pass's bit count.
static long stats_dc_first(const Image *img, const int *comps, int n, int al, Stats *tables) {
    long blocks = 0;
    if (n == 1) {
        const Component *k = &img->comp[comps[0]];
        Stats *s = &tables[k->dc_table];
        int last = 0;
        for (size_t b = 0; b < (size_t)k->wb * k->hb; b++) {
            int v = k->dc[b] >> al;
            int d = v - last;
            last = v;
            int m = nbits(d < 0 ? -d : d);
            s->freq[m]++;
            s->extra += m;
        }
        return (long)k->wb * k->hb;
    }
    int last[4] = {0, 0, 0, 0};
    for (int mr = 0; mr < img->mcu_rows; mr++) {
        for (int mc = 0; mc < img->mcus_per_row; mc++) {
            for (int j = 0; j < n; j++) {
                const Component *k = &img->comp[comps[j]];
                Stats *s = &tables[k->dc_table];
                for (int y = 0; y < k->v; y++) {
                    for (int x = 0; x < k->h; x++) {
                        int row = mr * k->v + y, col = mc * k->h + x;
                        blocks++;
                        if (row >= k->hb || col >= k->wb) { s->freq[0]++; continue; }
                        int v = k->dc[(size_t)row * k->wb + col] >> al;
                        int d = v - last[j];
                        last[j] = v;
                        int m = nbits(d < 0 ? -d : d);
                        s->freq[m]++;
                        s->extra += m;
                    }
                }
            }
        }
    }
    return blocks;
}

// Sequential (baseline) coding of everything in one interleaved scan
// (jchuff.c encode_one_block), with libjpeg's default table assignment.
static void stats_baseline(const Image *img, Stats *dc, Stats *ac) {
    int last[4] = {0, 0, 0, 0};
    int single = img->ncomp == 1;
    for (int mr = 0; mr < (single ? 1 : img->mcu_rows); mr++) {
        for (int mc = 0; mc < (single ? 1 : img->mcus_per_row); mc++) {
            for (int c = 0; c < img->ncomp; c++) {
                const Component *k = &img->comp[c];
                int t = k->dc_table;
                int ny = single ? k->hb : k->v, nx = single ? k->wb : k->h;
                for (int y = 0; y < ny; y++) {
                    for (int x = 0; x < nx; x++) {
                        int row = single ? y : mr * k->v + y, col = single ? x : mc * k->h + x;
                        if (row >= k->hb || col >= k->wb) { dc[t].freq[0]++; ac[t].freq[0]++; continue; }
                        size_t b = (size_t)row * k->wb + col;
                        int d = k->dc[b] - last[c];
                        last[c] = k->dc[b];
                        int m = nbits(d < 0 ? -d : d);
                        dc[t].freq[m]++;
                        dc[t].extra += m;
                        int prev = 0;
                        for (size_t j = k->off[b]; j < k->off[b + 1]; j++) {
                            int r = k->pos[j] - prev - 1;
                            prev = k->pos[j];
                            while (r > 15) { ac[t].freq[0xF0]++; r -= 16; }
                            int n = nbits(k->mag[j]);
                            ac[t].freq[(r << 4) + n]++;
                            ac[t].extra += n;
                        }
                        if (prev < 63) ac[t].freq[0]++;
                    }
                }
            }
        }
    }
}

// MARK: - Prices

// Bits for the symbols and the extra bits, and the bytes of the table.
static void price(const Stats *s, double *bits, long *table_bytes) {
    long freq[257];
    int any = 0;
    for (int i = 0; i < 256; i++) { freq[i] = s->freq[i]; any |= freq[i] != 0; }
    freq[256] = 0;
    if (!any) { *bits = (double)s->extra; *table_bytes = 0; return; }
    JHUFF_TBL tbl;
    memset(&tbl, 0, sizeof tbl);
    // libjpeg reports an impossible table by jumping out; this runs on
    // worker threads, so each call catches its own. Such a table can't be
    // written either: the scan costs "infinitely" much.
    struct jpeg_compress_struct cinfo;
    struct error_manager errors;
    cinfo.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = on_error;
    errors.pub.output_message = silent;
    if (setjmp(errors.jump)) {
        *bits = 1e18;
        *table_bytes = 0;
        return;
    }
    jpeg_gen_optimal_table(&cinfo, &tbl, freq);
    // Symbols in huffval order get the code lengths bits[] lists.
    double total = (double)s->extra;
    int p = 0, count = 0;
    for (int len = 1; len <= 16; len++) {
        for (int j = 0; j < tbl.bits[len]; j++, p++) total += (double)s->freq[tbl.huffval[p]] * len;
        count += tbl.bits[len];
    }
    *bits = total;
    *table_bytes = 2 + 2 + 1 + 16 + count; // DHT marker, length, class/id, counts, symbols
}

// Bytes of a scan: its header, its tables and its data. 0xFF bytes in the
// data are followed by a stuffed 0x00; about one in 256.
static double scan_bytes(int ncomp, double bits, long tables) {
    double data = (bits + 7) / 8;
    return 2 + 2 + 1 + 2 * ncomp + 3 + tables + data + data / 256;
}

static double price_scan(const Stats *s, int nstats) {
    double bits = 0;
    long tables = 0;
    for (int i = 0; i < nstats; i++) {
        double b;
        long t;
        price(&s[i], &b, &t);
        bits += b;
        tables += t;
    }
    return bits > 0 || tables > 0 ? scan_bytes(1, bits, tables) : 0;
}

// MARK: - Search

typedef struct {
    int comps_in_scan, comp[4], ss, se, ah, al;
} Scan;

typedef struct {
    Scan scans[4 + 4 * 63 * 4 + 4 * 3];
    int n;
    double bytes;   // predicted size of all scans
} Plan;

static void add(Plan *p, int ncomp, const int *comps, int ss, int se, int ah, int al) {
    Scan *s = &p->scans[p->n++];
    s->comps_in_scan = ncomp;
    for (int i = 0; i < ncomp; i++) s->comp[i] = comps[i];
    s->ss = ss;
    s->se = se;
    s->ah = ah;
    s->al = al;
}

static unsigned long long bits_from_to(int lo, int hi) { // positions lo..hi, inclusive
    if (hi < lo) return 0;
    return (hi == 63 ? ~0ULL : (1ULL << (hi + 1)) - 1) & ~((1ULL << lo) - 1);
}

// What each band [cuts[i], cuts[j] - 1] costs in a first pass at `al`, for
// all i < j at once. For a fixed band start, a coefficient's symbol (its run
// of zeros since the band start or the previous coefficient) doesn't depend
// on where the band ends, so the symbols are counted once per start and
// summed up to each end. Only the EOB runs depend on the end: a block adds
// to the run when the coefficient at the band's last position is zero, and
// ends the run when it has any coefficient in the band. That walk only needs
// the blocks with a coefficient at or after the start.
static void first_pass_costs(const Component *k, int al, const int *cuts, int ncuts, double cost[64][64]) {
    size_t blocks = (size_t)k->wb * k->hb;
    unsigned long long *mask = checked_malloc(blocks * sizeof *mask);
    // The blocks with a coefficient at or after the band start, packed: their
    // masks, and how many empty blocks come before each.
    unsigned long long *act = checked_malloc(blocks * sizeof *act);
    long *gap = checked_malloc(blocks * sizeof *gap);
    for (size_t b = 0; b < blocks; b++) {
        unsigned long long m = 0;
        for (size_t j = k->off[b]; j < k->off[b + 1]; j++)
            if (k->mag[j] >> al) m |= 1ULL << k->pos[j];
        mask[b] = m;
    }
    Stats *at = checked_malloc(64 * sizeof *at); // symbols of the coefficients at each position
    for (int i = 0; i + 1 < ncuts; i++) {
        int ss = cuts[i];
        memset(at, 0, 64 * sizeof *at);
        size_t nactive = 0, done = 0;
        for (size_t b = 0; b < blocks; b++) {
            if (!(mask[b] >> ss)) continue;
            act[nactive] = mask[b];
            gap[nactive++] = (long)(b - done);
            done = b + 1;
            int prev = ss - 1;
            for (size_t j = k->off[b]; j < k->off[b + 1]; j++) {
                int p = k->pos[j];
                if (p < ss) continue;
                int v = k->mag[j] >> al;
                if (!v) continue;
                int r = p - prev - 1;
                prev = p;
                at[p].freq[0xF0] += r >> 4;
                int n = nbits(v);
                at[p].freq[((r & 15) << 4) + n]++;
                at[p].extra += n;
            }
        }
        Stats sum;
        memset(&sum, 0, sizeof sum);
        int next = ss;
        for (int j = i + 1; j < ncuts; j++) {
            int se = cuts[j] - 1;
            for (; next <= se; next++) {
                for (int sym = 0; sym < 256; sym++) sum.freq[sym] += at[next].freq[sym];
                sum.extra += at[next].extra;
            }
            Stats st = sum;
            unsigned long long band = bits_from_to(ss, se);
            long eobrun = 0, be = 0;
            for (size_t a = 0; a < nactive; a++) {
                // Blocks without coefficients here only lengthen the run.
                for (eobrun += gap[a]; eobrun >= 0x7FFF; eobrun -= 0x7FFF) {
                    st.freq[14 << 4]++;
                    st.extra += 14;
                }
                if (act[a] & band) flush_eobrun(&st, &eobrun, &be);
                if (!(act[a] >> se & 1) && ++eobrun == 0x7FFF) flush_eobrun(&st, &eobrun, &be);
            }
            for (eobrun += (long)(blocks - done); eobrun >= 0x7FFF; eobrun -= 0x7FFF) {
                st.freq[14 << 4]++;
                st.extra += 14;
            }
            flush_eobrun(&st, &eobrun, &be);
            cost[i][j] = price_scan(&st, 1);
        }
    }
    free(mask);
    free(act);
    free(gap);
    free(at);
}

// An EOB run's symbol and its length bits, where the correction bits it
// carries are already counted with their coefficients.
static void flush_run(Stats *s, long *eobrun, long *be) {
    if (*eobrun > 0) {
        int n = nbits((int)*eobrun) - 1;
        s->freq[n << 4]++;
        s->extra += n;
        *eobrun = 0;
        *be = 0;
    }
}

// The same for refinement passes (from bit al + 1 to al), all bands at once.
// A newly nonzero coefficient's symbol carries the zeros since the previous
// newly nonzero one (coefficients already nonzero don't count as zeros),
// sixteen at a time as ZRLs; every correction bit is written sooner or
// later, so it counts where its coefficient is. What depends on the band's
// end is the EOB run: a block joins it unless its last position is newly
// nonzero, bringing the correction bits after its last newly nonzero
// coefficient along, and the run is written early once those pass 937 bits
// (libjpeg's buffer limit) or the run reaches 32767 blocks.
static void refine_costs(const Component *k, int al, const int *cuts, int ncuts, double cost[64][64]) {
    size_t blocks = (size_t)k->wb * k->hb;
    unsigned long long *fresh = checked_malloc(blocks * sizeof *fresh), *old = checked_malloc(blocks * sizeof *old);
    unsigned long long *actf = checked_malloc(blocks * sizeof *actf), *acto = checked_malloc(blocks * sizeof *acto);
    long *gap = checked_malloc(blocks * sizeof *gap);
    for (size_t b = 0; b < blocks; b++) {
        unsigned long long f = 0, o = 0;
        for (size_t j = k->off[b]; j < k->off[b + 1]; j++) {
            int t = k->mag[j] >> al;
            if (t == 1) f |= 1ULL << k->pos[j];
            else if (t > 1) o |= 1ULL << k->pos[j];
        }
        fresh[b] = f;
        old[b] = o;
    }
    Stats *at = checked_malloc(64 * sizeof *at);
    for (int i = 0; i + 1 < ncuts; i++) {
        int ss = cuts[i];
        memset(at, 0, 64 * sizeof *at);
        size_t nactive = 0, done = 0;
        for (size_t b = 0; b < blocks; b++) {
            unsigned long long m = (fresh[b] | old[b]) >> ss << ss;
            if (!m) continue;
            actf[nactive] = fresh[b];
            acto[nactive] = old[b];
            gap[nactive++] = (long)(b - done);
            done = b + 1;
            int prev = ss - 1;
            while (m) {
                int p = __builtin_ctzll(m);
                m &= m - 1;
                at[p].extra++; // the sign bit, or the correction bit
                if (old[b] >> p & 1) continue;
                int zeros = p - prev - 1 - __builtin_popcountll(old[b] & bits_from_to(prev + 1, p - 1));
                at[p].freq[0xF0] += zeros >> 4;
                at[p].freq[((zeros & 15) << 4) + 1]++;
                prev = p;
            }
        }
        Stats sum;
        memset(&sum, 0, sizeof sum);
        int next = ss;
        for (int j = i + 1; j < ncuts; j++) {
            int se = cuts[j] - 1;
            for (; next <= se; next++) {
                for (int sym = 0; sym < 256; sym++) sum.freq[sym] += at[next].freq[sym];
                sum.extra += at[next].extra;
            }
            Stats st = sum;
            unsigned long long band = bits_from_to(ss, se);
            long eobrun = 0, be = 0;
            for (size_t a = 0; a < nactive; a++) {
                for (eobrun += gap[a]; eobrun >= 0x7FFF; eobrun -= 0x7FFF) {
                    st.freq[14 << 4]++;
                    st.extra += 14;
                    be = 0;
                }
                unsigned long long f = actf[a] & band;
                if (f) flush_run(&st, &eobrun, &be);
                if (!(actf[a] >> se & 1)) {
                    int last = f ? 63 - __builtin_clzll(f) : ss - 1;
                    eobrun++;
                    be += __builtin_popcountll(acto[a] & bits_from_to(last + 1, se));
                    if (eobrun == 0x7FFF || be > 1000 - 64 + 1) flush_run(&st, &eobrun, &be);
                }
            }
            for (eobrun += (long)(blocks - done); eobrun >= 0x7FFF; eobrun -= 0x7FFF) {
                st.freq[14 << 4]++;
                st.extra += 14;
            }
            flush_run(&st, &eobrun, &be);
            cost[i][j] = price_scan(&st, 1);
        }
    }
    free(fresh);
    free(old);
    free(actf);
    free(acto);
    free(gap);
    free(at);
}

// The cheapest way to cover each prefix of the coefficients with bands:
// best[j] covers cuts[0] .. cuts[j] - 1 (best[0] = 0, nothing), from[j] is
// where its last band starts. Dynamic programming over the boundaries.
static void prefix_bands(double cost[64][64], int ncuts, double *best, int *from) {
    best[0] = 0;
    for (int j = 1; j < ncuts; j++) {
        best[j] = 1e300;
        for (int i = 0; i < j; i++) {
            double c = best[i] + cost[i][j];
            if (c < best[j]) { best[j] = c; from[j] = i; }
        }
    }
}

// One pass of one component at one point transform: a first pass at `al`,
// or a refinement from al + 1 to al. Keeps its band prices for the search.
typedef struct {
    const Component *k;
    int refine, al;
    double (*cost)[64];
    double best[64];
    int from[64];
} Pass;

// Every component's passes are independent, so they run in parallel.
static void solve_passes(Pass *passes, size_t n, const int *cuts, int ncuts) {
    dispatch_apply(n, DISPATCH_APPLY_AUTO, ^(size_t i) {
        Pass *p = &passes[i];
        p->cost = checked_malloc(64 * sizeof *p->cost);
        if (p->refine) refine_costs(p->k, p->al, cuts, ncuts, p->cost);
        else first_pass_costs(p->k, p->al, cuts, ncuts, p->cost);
        prefix_bands(p->cost, ncuts, p->best, p->from);
    });
}

// A component's AC plan: first-pass bands, each with its own point
// transform, then refinement bands per level.
typedef struct {
    int nbands, start[64], al[64];      // first pass: band starts (start[nbands] = 64) and their Al
    int nref[4], ref[4][65];            // refinement from a + 1 to a: band starts, ref[a][nref[a]] = end + 1
    double bytes;
} ACPlan;

// The same, in indices into the boundary list: band m is cuts[lo] .. cuts[hi] - 1.
typedef struct {
    int nbands, lo[64], hi[64], al[64];
    int nref[4], rlo[4][64], rhi[4][64];
    double bytes;
} Profile;

// The point transform may differ per band as long as it doesn't rise from
// the low to the high frequencies. Refinement at level a then covers exactly
// the prefix of bands whose Al is above a, split into its own cheapest
// bands. Dynamic programming over (band end, Al of the last band): when Al
// drops from a' to a at a boundary, the refinements of levels a .. a'-1 end
// there. A single Al for all bands is one of the profiles.
static Profile falling_profile(double (*const *first)[64], const double (*ref_best)[64], const int (*ref_from)[64],
                               int ncuts, int max_al) {
    enum { N = 64, L = 4 };
    double f[N][L];
    int from_i[N][L], from_al[N][L];
    for (int j = 1; j < ncuts; j++) {
        for (int al = 0; al <= max_al; al++) {
            f[j][al] = 1e300;
            for (int i = 0; i < j; i++) {
                for (int prev = al; prev <= max_al; prev++) {
                    // Before the first band: a virtual band at the top Al.
                    double base = i == 0 ? (prev == max_al ? 0 : 1e300) : f[i][prev];
                    if (base >= 1e300) continue;
                    double c = base + first[al][i][j];
                    for (int a = al; a < prev; a++) c += ref_best[a][i];
                    if (c < f[j][al]) { f[j][al] = c; from_i[j][al] = i; from_al[j][al] = prev; }
                }
            }
        }
    }
    Profile p;
    memset(&p, 0, sizeof p);
    p.bytes = 1e300;
    int last = ncuts - 1, last_al = 0;
    for (int al = 0; al <= max_al; al++) {
        double c = f[last][al];
        for (int a = 0; a < al; a++) c += ref_best[a][last];
        if (c < p.bytes) { p.bytes = c; last_al = al; }
    }
    // Walk back: the first-pass bands, and where each refinement level ends.
    int ends[L] = {0, 0, 0, 0};
    for (int a = 0; a < last_al; a++) ends[a] = last;
    int n = 0, lo[N], hi[N], al_of[N];
    for (int j = last, al = last_al; j > 0;) {
        int i = from_i[j][al], prev = from_al[j][al];
        lo[n] = i;
        hi[n] = j;
        al_of[n++] = al;
        if (i > 0) for (int a = al; a < prev; a++) ends[a] = i;
        j = i;
        al = prev;
    }
    p.nbands = n;
    for (int m = 0; m < n; m++) {
        p.lo[m] = lo[n - 1 - m];
        p.hi[m] = hi[n - 1 - m];
        p.al[m] = al_of[n - 1 - m];
    }
    for (int a = 0; a < max_al; a++) {
        int k = 0, path[N];
        for (int j = ends[a]; j > 0; j = ref_from[a][j]) path[k++] = j;
        p.nref[a] = k;
        for (int m = 0; m < k; m++) {
            p.rhi[a][m] = path[k - 1 - m];
            p.rlo[a][m] = ref_from[a][path[k - 1 - m]];
        }
    }
    return p;
}

// The best profile in either direction: Al falling with the frequency, or
// rising (found by running the same search on the mirrored boundary list;
// refinements then cover suffixes). The cheaper one wins.
static ACPlan plan_ac(const Pass *first, const Pass *refine, const int *cuts, int ncuts, int max_al) {
    double (*fcost[4])[64], (*rcost[4])[64];
    double ref_best[4][64];
    int ref_from[4][64];
    for (int al = 0; al <= max_al; al++) fcost[al] = first[al].cost;
    for (int a = 0; a < max_al; a++) {
        memcpy(ref_best[a], refine[a].best, sizeof ref_best[a]);
        memcpy(ref_from[a], refine[a].from, sizeof ref_from[a]);
    }
    Profile fall = falling_profile(fcost, ref_best, ref_from, ncuts, max_al);

    // Mirror: boundary index i becomes ncuts - 1 - i.
    int n = ncuts - 1;
    for (int al = 0; al <= max_al; al++) {
        fcost[al] = checked_malloc(64 * sizeof *fcost[al]);
        for (int i = 0; i < ncuts; i++)
            for (int j = i + 1; j < ncuts; j++) fcost[al][i][j] = first[al].cost[n - j][n - i];
    }
    for (int a = 0; a < max_al; a++) {
        rcost[a] = checked_malloc(64 * sizeof *rcost[a]);
        for (int i = 0; i < ncuts; i++)
            for (int j = i + 1; j < ncuts; j++) rcost[a][i][j] = refine[a].cost[n - j][n - i];
        prefix_bands(rcost[a], ncuts, ref_best[a], ref_from[a]);
    }
    Profile rise = falling_profile(fcost, ref_best, ref_from, ncuts, max_al);
    for (int al = 0; al <= max_al; al++) free(fcost[al]);
    for (int a = 0; a < max_al; a++) free(rcost[a]);

    Profile best = fall;
    if (rise.bytes < fall.bytes) {
        // Back from the mirror, in ascending order.
        best = rise;
        for (int m = 0; m < rise.nbands; m++) {
            int k = rise.nbands - 1 - m;
            best.lo[m] = n - rise.hi[k];
            best.hi[m] = n - rise.lo[k];
            best.al[m] = rise.al[k];
        }
        for (int a = 0; a < max_al; a++)
            for (int m = 0; m < rise.nref[a]; m++) {
                int k = rise.nref[a] - 1 - m;
                best.rlo[a][m] = n - rise.rhi[a][k];
                best.rhi[a][m] = n - rise.rlo[a][k];
            }
    }

    ACPlan plan;
    memset(&plan, 0, sizeof plan);
    plan.bytes = best.bytes;
    plan.nbands = best.nbands;
    for (int m = 0; m < best.nbands; m++) {
        plan.start[m] = cuts[best.lo[m]];
        plan.al[m] = best.al[m];
    }
    plan.start[best.nbands] = 64;
    for (int a = 0; a < max_al; a++) {
        plan.nref[a] = best.nref[a];
        for (int m = 0; m < best.nref[a]; m++) plan.ref[a][m] = cuts[best.rlo[a][m]];
        plan.ref[a][best.nref[a]] = best.nref[a] ? cuts[best.rhi[a][best.nref[a] - 1]] : 1;
    }
    return plan;
}

typedef struct {
    int interleaved, al;
    double bytes;
} DCPlan;

static double price_dc(const Image *img, int interleaved, int al) {
    double total = 0;
    int all[4] = {0, 1, 2, 3};
    if (interleaved) {
        Stats t[2];
        memset(t, 0, sizeof t);
        long blocks = stats_dc_first(img, all, img->ncomp, al, t);
        double bits = 0;
        long tables = 0;
        for (int i = 0; i < 2; i++) {
            double b;
            long tb;
            price(&t[i], &b, &tb);
            bits += b;
            tables += tb;
        }
        total += scan_bytes(img->ncomp, bits, tables);
        if (al > 0) total += al * scan_bytes(img->ncomp, (double)blocks, 0);
    } else {
        for (int c = 0; c < img->ncomp; c++) {
            Stats t[2];
            memset(t, 0, sizeof t);
            long blocks = stats_dc_first(img, &all[c], 1, al, t);
            total += price_scan(&t[img->comp[c].dc_table], 1);
            if (al > 0) total += al * scan_bytes(1, (double)blocks, 0);
        }
    }
    return total;
}

static DCPlan plan_dc(const Image *img, int max_al) {
    DCPlan best = {0, 0, 1e300};
    int can_interleave = img->ncomp > 1 && img->blocks_in_mcu <= 10;
    for (int inter = 0; inter <= can_interleave; inter++) {
        for (int al = 0; al <= max_al; al++) {
            double b = price_dc(img, inter, al);
            if (b < best.bytes) best = (DCPlan){inter, al, b};
        }
    }
    return best;
}

static Plan progressive_plan(const Image *img, int effort) {
    static const int balanced_cuts[] = {1, 2, 3, 6, 9, 14, 21, 64};
    // Each set contains the smaller ones, so more effort never finds less.
    static const int thorough_cuts[] = {1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 14, 16, 19, 21, 24, 28, 33, 40, 48, 64};
    int thorough_n = sizeof thorough_cuts / sizeof *thorough_cuts;
    int all_cuts[64];
    for (int i = 0; i < 63; i++) all_cuts[i] = i + 1;
    all_cuts[63] = 64;
    const int *cuts = balanced_cuts;
    int ncuts = sizeof balanced_cuts / sizeof *cuts, max_al = 3;
    if (effort >= EFFORT_THOROUGH) { cuts = thorough_cuts; ncuts = thorough_n; }
    // Every boundary costs time in proportion to the image; beyond this it
    // stops being worth the wait.
    long blocks = total_blocks(img);
    if ((effort == EFFORT_MAXIMUM && blocks <= 200000) || blocks <= SMALL_IMAGE_BLOCKS) {
        cuts = all_cuts;
        ncuts = 64;
        max_al = 3;
    }

    Plan p;
    memset(&p, 0, sizeof p);
    DCPlan dc = plan_dc(img, 1);
    ACPlan ac[4];
    // Per component: first passes at 0..max_al, then refinements 0..max_al-1.
    int per = 2 * max_al + 1;
    Pass passes[4 * 7];
    for (int c = 0; c < img->ncomp; c++)
        for (int j = 0; j < per; j++)
            passes[c * per + j] = (Pass){.k = &img->comp[c], .refine = j > max_al, .al = j > max_al ? j - max_al - 1 : j};
    solve_passes(passes, (size_t)(img->ncomp * per), cuts, ncuts);
    for (int c = 0; c < img->ncomp; c++) ac[c] = plan_ac(&passes[c * per], &passes[c * per + max_al + 1], cuts, ncuts, max_al);
    for (int i = 0; i < img->ncomp * per; i++) free(passes[i].cost);

    int all[4] = {0, 1, 2, 3};
    // DC first pass, then every component's first AC pass, then refinements
    // from the highest level down.
    if (dc.interleaved) add(&p, img->ncomp, all, 0, 0, 0, dc.al);
    else for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 0, 0, 0, dc.al);
    for (int c = 0; c < img->ncomp; c++)
        for (int b = 0; b < ac[c].nbands; b++)
            add(&p, 1, &all[c], ac[c].start[b], ac[c].start[b + 1] - 1, 0, ac[c].al[b]);
    for (int bit = dc.al - 1; bit >= 0; bit--) {
        if (dc.interleaved) add(&p, img->ncomp, all, 0, 0, bit + 1, bit);
        else for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 0, 0, bit + 1, bit);
    }
    for (int a = max_al - 1; a >= 0; a--)
        for (int c = 0; c < img->ncomp; c++)
            for (int b = 0; b < ac[c].nref[a]; b++)
                add(&p, 1, &all[c], ac[c].ref[a][b], ac[c].ref[a][b + 1] - 1, a + 1, a);
    p.bytes = dc.bytes;
    for (int c = 0; c < img->ncomp; c++) p.bytes += ac[c].bytes;
    return p;
}

static double baseline_bytes(const Image *img) {
    Stats dc[2], ac[2];
    memset(dc, 0, sizeof dc);
    memset(ac, 0, sizeof ac);
    stats_baseline(img, dc, ac);
    double bits = 0;
    long tables = 0;
    for (int i = 0; i < 2; i++) {
        double b;
        long t;
        price(&dc[i], &b, &t);
        bits += b;
        tables += t;
        price(&ac[i], &b, &t);
        bits += b;
        tables += t;
    }
    return scan_bytes(img->ncomp, bits, tables);
}

// libjpeg's own progressive script (jpeg_simple_progression), priced.
static Plan simple_plan(const Image *img) {
    Plan p;
    memset(&p, 0, sizeof p);
    int all[4] = {0, 1, 2, 3};
    int ycc = img->ncomp == 3;
    // libjpeg can interleave at most 10 blocks per MCU.
    int interleave = img->ncomp == 1 || img->blocks_in_mcu <= 10;
    if (interleave) add(&p, img->ncomp, all, 0, 0, 0, 1);
    else for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 0, 0, 0, 1);
    if (ycc) {
        add(&p, 1, &all[0], 1, 5, 0, 2);
        add(&p, 1, &all[2], 1, 63, 0, 1);
        add(&p, 1, &all[1], 1, 63, 0, 1);
        add(&p, 1, &all[0], 6, 63, 0, 2);
        add(&p, 1, &all[0], 1, 63, 2, 1);
        if (interleave) add(&p, img->ncomp, all, 0, 0, 1, 0);
        else for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 0, 0, 1, 0);
        add(&p, 1, &all[2], 1, 63, 1, 0);
        add(&p, 1, &all[1], 1, 63, 1, 0);
        add(&p, 1, &all[0], 1, 63, 1, 0);
    } else {
        for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 1, 5, 0, 2);
        for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 6, 63, 0, 2);
        for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 1, 63, 2, 1);
        if (interleave) add(&p, img->ncomp, all, 0, 0, 1, 0);
        else for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 0, 0, 1, 0);
        for (int c = 0; c < img->ncomp; c++) add(&p, 1, &all[c], 1, 63, 1, 0);
    }
    return p;
}

// Prices any plan scan by scan (for comparing with the searched one).
static double price_plan(const Image *img, const Plan *p) {
    double total = 0;
    for (int i = 0; i < p->n; i++) {
        const Scan *s = &p->scans[i];
        if (s->ss == 0) {
            if (s->ah == 0) {
                Stats t[2];
                memset(t, 0, sizeof t);
                stats_dc_first(img, s->comp, s->comps_in_scan, s->al, t);
                double bits = 0;
                long tables = 0;
                for (int j = 0; j < 2; j++) {
                    double b;
                    long tb;
                    price(&t[j], &b, &tb);
                    bits += b;
                    tables += tb;
                }
                total += scan_bytes(s->comps_in_scan, bits, tables);
            } else {
                Stats t[2];
                memset(t, 0, sizeof t);
                long blocks = stats_dc_first(img, s->comp, s->comps_in_scan, 0, t);
                total += scan_bytes(s->comps_in_scan, (double)blocks, 0);
            }
        } else {
            Stats t;
            memset(&t, 0, sizeof t);
            if (s->ah == 0) stats_ac_first(&img->comp[s->comp[0]], s->ss, s->se, s->al, &t);
            else stats_ac_refine(&img->comp[s->comp[0]], s->ss, s->se, s->al, &t);
            total += price_scan(&t, 1);
        }
    }
    return total;
}

// MARK: - Writing

typedef struct {
    unsigned char *data;
    unsigned long size;
} Buffer;

// libjpeg writes every Huffman and quantization table into a marker of its
// own; one DHT or DQT marker may hold several tables. Merging neighbouring
// ones saves four bytes (marker and length) per table. Walks the whole file:
// progressive files define new tables between scans.
static void merge_tables(Buffer *buf) {
    unsigned char *b = buf->data, *out = checked_malloc(buf->size);
    size_t n = buf->size, i = 2, o = 2;
    memcpy(out, b, 2);
    long open = -1;      // where the length of the marker being extended is
    int open_marker = 0;
    while (i + 4 <= n && b[i] == 0xFF) {
        int marker = b[i + 1];
        size_t length = (size_t)b[i + 2] << 8 | b[i + 3];
        if (marker == 0xD9 || length < 2 || i + 2 + length > n) break;
        if ((marker == 0xC4 || marker == 0xDB) && marker == open_marker) {
            size_t total = ((size_t)out[open] << 8 | out[open + 1]) + length - 2;
            if (total <= 0xFFFF) {
                memcpy(out + o, b + i + 4, length - 2);
                o += length - 2;
                out[open] = (unsigned char)(total >> 8);
                out[open + 1] = (unsigned char)(total & 0xFF);
                i += 2 + length;
                continue;
            }
        }
        memcpy(out + o, b + i, 2 + length);
        open = (long)o + 2;
        open_marker = marker;
        o += 2 + length;
        i += 2 + length;
        if (marker == 0xDA) {
            // Entropy-coded data up to the next marker that isn't a stuffed
            // zero or a restart marker.
            size_t j = i;
            while (j + 1 < n && !(b[j] == 0xFF && b[j + 1] != 0 && !(b[j + 1] >= 0xD0 && b[j + 1] <= 0xD7))) j++;
            memcpy(out + o, b + i, j - i);
            o += j - i;
            i = j;
            open_marker = 0;
        }
    }
    memcpy(out + o, b + i, n - i); // EOI (or anything unexpected, as it was)
    o += n - i;
    free(buf->data);
    buf->data = out;
    buf->size = o;
}

// Writes the coefficients with the plan's scans (NULL: sequential) into memory.
static int encode(j_decompress_ptr src, jvirt_barray_ptr *coefs, const Plan *plan, Buffer *out) {
    struct jpeg_compress_struct dst;
    struct error_manager errors;
    dst.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = on_error;
    errors.pub.output_message = silent;
    jpeg_scan_info *volatile script = NULL; // read after a longjmp
    out->data = NULL;
    out->size = 0;
    jpeg_create_compress(&dst);
    if (setjmp(errors.jump)) {
        jpeg_destroy_compress(&dst);
        free(script);
        free(out->data);
        out->data = NULL;
        return 0;
    }
    jpeg_mem_dest(&dst, &out->data, &out->size);
    jpeg_copy_critical_parameters(src, &dst);
    // A JFIF marker only if the input had one (camera files carry EXIF
    // instead). The input's Adobe marker is copied where it was, so EXIF
    // stays first; libjpeg writes its own only where the input had none.
    dst.write_JFIF_header = src->saw_JFIF_marker;
    if (src->saw_Adobe_marker) dst.write_Adobe_marker = FALSE;
    dst.optimize_coding = TRUE;
    if (plan) {
        script = checked_malloc(sizeof(jpeg_scan_info) * (size_t)plan->n);
        for (int i = 0; i < plan->n; i++) {
            const Scan *s = &plan->scans[i];
            script[i].comps_in_scan = s->comps_in_scan;
            for (int c = 0; c < s->comps_in_scan; c++) script[i].component_index[c] = s->comp[c];
            script[i].Ss = s->ss;
            script[i].Se = s->se;
            script[i].Ah = s->ah;
            script[i].Al = s->al;
        }
        dst.scan_info = script;
        dst.num_scans = plan->n;
    }
    jpeg_write_coefficients(&dst, coefs);
    // Every marker the input had, as jpegtran -copy all does, except the
    // JFIF marker libjpeg writes itself.
    for (jpeg_saved_marker_ptr m = src->marker_list; m; m = m->next) {
        if (dst.write_JFIF_header && m->marker == JPEG_APP0 && m->data_length >= 5 && !memcmp(m->data, "JFIF", 5))
            continue;
        jpeg_write_marker(&dst, m->marker, m->data, m->data_length);
    }
    jpeg_finish_compress(&dst);
    jpeg_destroy_compress(&dst);
    free(script);
    merge_tables(out);
    return 1;
}

static void print_plan(const char *name, const Plan *p) {
    fprintf(stderr, "%s:", name);
    for (int i = 0; i < p->n; i++) {
        const Scan *s = &p->scans[i];
        fprintf(stderr, " [");
        for (int c = 0; c < s->comps_in_scan; c++) fprintf(stderr, "%s%d", c ? "," : "", s->comp[c]);
        fprintf(stderr, " %d-%d %d/%d]", s->ss, s->se, s->ah, s->al);
    }
    fprintf(stderr, "\n");
}

// Development check: the all-ends costing must match counting each band
// on its own, for every band and point transform.
static int selftest(const Image *img) {
    static const int cuts[] = {1, 2, 3, 5, 6, 9, 14, 21, 40, 63, 64};
    int n = sizeof cuts / sizeof *cuts, bad = 0;
    static double fast[64][64];
    for (int c = 0; c < img->ncomp; c++) {
        for (int al = 0; al <= 3; al++) {
            first_pass_costs(&img->comp[c], al, cuts, n, fast);
            for (int i = 0; i + 1 < n; i++)
                for (int j = i + 1; j < n; j++) {
                    Stats s;
                    memset(&s, 0, sizeof s);
                    stats_ac_first(&img->comp[c], cuts[i], cuts[j] - 1, al, &s);
                    double slow = price_scan(&s, 1);
                    if (slow != fast[i][j]) {
                        fprintf(stderr, "mismatch c%d al%d %d-%d: %.1f vs %.1f\n", c, al, cuts[i], cuts[j] - 1, slow, fast[i][j]);
                        bad++;
                    }
                }
            refine_costs(&img->comp[c], al, cuts, n, fast);
            for (int i = 0; i + 1 < n; i++)
                for (int j = i + 1; j < n; j++) {
                    Stats s;
                    memset(&s, 0, sizeof s);
                    stats_ac_refine(&img->comp[c], cuts[i], cuts[j] - 1, al, &s);
                    double slow = price_scan(&s, 1);
                    if (slow != fast[i][j]) {
                        fprintf(stderr, "refine mismatch c%d al%d %d-%d: %.1f vs %.1f\n", c, al, cuts[i], cuts[j] - 1, slow, fast[i][j]);
                        bad++;
                    }
                }
        }
    }
    fprintf(stderr, "selftest: %d mismatches\n", bad);
    return bad ? 1 : 0;
}

int main(int argc, char **argv) {
    int effort = EFFORT_BALANCED, report = 0, test = 0, arg = 1;
    for (; arg < argc && !strncmp(argv[arg], "--", 2); arg++) {
        if (!strcmp(argv[arg], "--report")) report = 1;
        else if (!strcmp(argv[arg], "--selftest")) test = 1;
        else if (!strcmp(argv[arg], "--effort") && arg + 1 < argc) {
            const char *e = argv[++arg];
            effort = !strcmp(e, "thorough") ? EFFORT_THOROUGH
                   : !strcmp(e, "maximum") ? EFFORT_MAXIMUM : EFFORT_BALANCED;
        } else break;
    }
    if (argc - arg != 2) {
        fprintf(stderr, "usage: jpeg-scan [--effort fast|balanced|thorough|maximum] [--report] INPUT OUTPUT\n");
        return 2;
    }
    FILE *in = fopen(argv[arg], "rb");
    if (!in) {
        fprintf(stderr, "jpeg-scan: can't open input\n");
        return 2;
    }
    struct jpeg_decompress_struct src;
    struct error_manager errors;
    src.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = on_error;
    errors.pub.output_message = silent;
    jpeg_create_decompress(&src);
    // 0: reading the header, 1: reading the coefficients, 2: after that.
    volatile int stage = 0;
    if (setjmp(errors.jump)) {
        // Reading the coefficients fails only for what can't be transcoded
        // (lossless JPEG has no DCT coefficients); anything else is an error.
        fprintf(stderr, "jpeg-scan: %s\n", stage == 1 ? "not supported" : "unreadable JPEG or internal error");
        return stage == 1 ? 3 : 2;
    }
    jpeg_stdio_src(&src, in);
    jpeg_save_markers(&src, JPEG_COM, 0xFFFF);
    for (int m = 0; m < 16; m++) jpeg_save_markers(&src, JPEG_APP0 + m, 0xFFFF);
    jpeg_read_header(&src, TRUE);
    // Arithmetic-coded input is read and written with Huffman coding, which
    // every viewer can show; it only counts if it comes out smaller.
    if (src.data_precision != 8 || src.num_components > 4) {
        fprintf(stderr, "jpeg-scan: not supported (precision %d)\n", src.data_precision);
        return 3;
    }
    stage = 1;
    jvirt_barray_ptr *coefs = jpeg_read_coefficients(&src);
    stage = 2;
    // libjpeg only warns about damaged data and fills in what's missing; a
    // rewrite would make that filling permanent, where a better decoder
    // might still recover more from the original.
    if (src.err->num_warnings > 0) {
        fprintf(stderr, "jpeg-scan: damaged image data, left alone\n");
        return 3;
    }

    Image img;
    memset(&img, 0, sizeof img);
    load(&img, &src, coefs);
    if (test) return selftest(&img);

    // Candidates, cheapest first by the model: sequential, libjpeg's
    // standard progression, and the searched plan.
    Plan simple = simple_plan(&img), searched;
    simple.bytes = price_plan(&img, &simple);
    // Sequential coding interleaves every component: at most 10 blocks per MCU.
    int can_baseline = img.ncomp == 1 || img.blocks_in_mcu <= 10;
    double baseline = can_baseline ? baseline_bytes(&img) : 1e300;
    const Plan *best = baseline <= simple.bytes ? NULL : &simple;
    double best_bytes = baseline <= simple.bytes ? baseline : simple.bytes;
    searched = progressive_plan(&img, effort);
    if (searched.bytes < best_bytes) { best = &searched; best_bytes = searched.bytes; }

    Buffer out;
    if (effort == EFFORT_MAXIMUM || total_blocks(&img) <= SMALL_IMAGE_BLOCKS) {
        // Write all three for real and keep the smallest (the model's byte
        // stuffing is an estimate; on small files it can tip the choice).
        const Plan *cands[3] = {&simple, &searched, NULL};
        Buffer b;
        out.data = NULL;
        for (int i = 0; i < 2 + can_baseline; i++) {
            if (!encode(&src, coefs, cands[i], &b)) continue;
            if (!out.data || b.size < out.size) { free(out.data); out = b; best = cands[i]; }
            else free(b.data);
        }
        if (!out.data) { fprintf(stderr, "jpeg-scan: writing failed\n"); return 2; }
    } else if (!encode(&src, coefs, best, &out)) {
        fprintf(stderr, "jpeg-scan: writing failed\n");
        return 2;
    }

    if (report) {
        fprintf(stderr, "model: baseline %.0f, simple %.0f", baseline, simple.bytes);
        fprintf(stderr, ", searched %.0f", searched.bytes);
        fprintf(stderr, "; chose %s; file %lu\n", best == NULL ? "baseline" : best == &simple ? "simple" : "searched", out.size);
        if (best) print_plan("scans", best);
    }

    FILE *o = fopen(argv[arg + 1], "wb");
    if (!o || fwrite(out.data, 1, out.size, o) != out.size || fclose(o) != 0) {
        fprintf(stderr, "jpeg-scan: can't write output\n");
        return 2;
    }
    free(out.data);
    jpeg_finish_decompress(&src);
    jpeg_destroy_decompress(&src);
    fclose(in);
    return 0;
}
