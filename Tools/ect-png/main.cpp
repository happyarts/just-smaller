// ect-png: the PNG part of the Efficient Compression Tool (ECT) on its own.
//
// ECT (https://github.com/fhanau/Efficient-Compression-Tool, Apache-2.0,
// Copyright (c) 2014-2026 Felix Hanau) also handles JPEG, gzip and zip, which
// pulls in mozjpeg and miniz. Just Smaller only needs PNG, so this small
// driver replaces ECT's main.cpp and is linked against ECT's PNG sources
// only. OptimizePNG below follows ECT's own function of the same name.
//
//     ect-png -LEVEL [--strict] [--strip] [--allfilters | --allfilters-b | --segmented] [--mt-deflate=N] FILE
//
// --segmented chooses the PNG filters section by section from all of ECT's
// heuristics (patches/2-segmented-filters.patch) instead of one heuristic
// for the whole image.
//
// Like ECT, it rewrites FILE in place; it is only ever run on a copy.
// Exit status: 0 done, 1 error (unreadable or invalid PNG), 2 usage.

#include "main.h"
#include "support.h"
#include "lodepng/lodepng.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static int OptimizePNG(const char *file, unsigned level, bool strict, bool strip,
                       bool allFilters, bool allFiltersBrute, bool segmented, unsigned threads) {
    unsigned mode = level % 10000 > 9 ? 9 : level % 10000;
    unsigned quiet = 1;
    if (filesize(file) < 0) return 1;

    int x = 1;
    if (mode == 9 && !allFilters) {
        x = Zopflipng(strip, file, strict, 3, 0, threads, quiet);
        if (x < 0) return 1;
    }
    int filter = 0;
    if (segmented && mode > 1) {
        // OptiPNG would only suggest a filter here (above level 1 it leaves
        // the file alone), and --segmented chooses them itself.
        filter = LFS_SEGMENTED;
    } else if (!allFilters) {
        filter = Optipng(mode, file, false, strict || mode > 1);
        if (filter == -1) return 1;
        if (segmented) filter = LFS_SEGMENTED;
    }
    if (mode != 1) {
        if (allFilters) {
            static const int filters[] = {6, 0, 5, 1, 2, 3, 4, 7, 8, 11, 12, 13};
            static const int brute[] = {9, 10, 14};
            for (int f : filters) {
                x = Zopflipng(strip, file, strict, level, f, threads, quiet);
                if (x < 0) return 1;
            }
            if (allFiltersBrute)
                for (int f : brute)
                    if (Zopflipng(strip, file, strict, level, f, threads, quiet) < 0) return 1;
        } else {
            x = Zopflipng(strip, file, strict, level, filter, threads, quiet);
            if (x < 0) return 1;
        }
    }
    if (strip && x) Optipng(0, file, false, 0);
    return 0;
}

int main(int argc, const char *argv[]) {
    unsigned level = 3, threads = 0;
    bool strict = false, strip = false, allFilters = false, brute = false, segmented = false;
    const char *file = nullptr;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a[0] == '-' && a[1] >= '0' && a[1] <= '9') { level = atoi(a + 1); if (!level) level = 1; }
        else if (!strcmp(a, "--strict")) strict = true;
        else if (!strcmp(a, "--strip")) strip = true;
        else if (!strcmp(a, "--allfilters")) allFilters = true;
        else if (!strcmp(a, "--allfilters-b")) allFilters = brute = true;
        else if (!strcmp(a, "--segmented")) segmented = true;
        else if (!strncmp(a, "--mt-deflate=", 13)) threads = atoi(a + 13);
        else if (a[0] != '-' && !file) file = a;
        else { fprintf(stderr, "ect-png: unknown argument %s\n", a); return 2; }
    }
    if (!file) { fprintf(stderr, "usage: ect-png -LEVEL [--strict] [--strip] [--allfilters | --allfilters-b | --segmented] FILE\n"); return 2; }
    if (segmented && allFilters) { fprintf(stderr, "ect-png: --segmented and --allfilters exclude each other\n"); return 2; }
    return OptimizePNG(file, level, strict, strip, allFilters, brute, segmented, threads);
}
