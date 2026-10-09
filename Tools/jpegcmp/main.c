// jpegcmp — proves that two JPEG files hold the same image data.
//
//     jpegcmp ORIGINAL RESULT
//     jpegcmp --check FILE
//     jpegcmp --check-headers FILE
//     jpegcmp --pixels JPEG PPM
//
// Reads both files' quantized DCT coefficients with libjpeg (the same call
// jpegtran uses) and compares them block by block, together with the frame
// geometry, the sampling factors and the quantization tables. Equal
// coefficients and tables decode to the same pixels in every conforming
// decoder; this is a stronger proof than comparing one decoder's output.
//
// With --check, only reads FILE; with --check-headers, only its headers up
// to the first scan.
//
// With --pixels, decodes JPEG to RGB (libjpeg-turbo's defaults, without
// applying an orientation) and compares it with an 8-bit binary PPM of the
// same size, as another decoder (of another format holding the same image)
// produced it. Prints the mean absolute difference, the largest mean of any
// 8x8 block and the largest single difference, in 8-bit steps:
// "mean 0.46 block 0.93 max 5". Exit status 0 compared, 1 different size.
//
// Exit status: 0 identical, 1 different, 2 unreadable, 3 the result reads
// only with warnings (damaged data, bytes where a marker belongs).

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "jpeglib.h"

struct error_manager {
    struct jpeg_error_mgr pub;
    jmp_buf *jump; // of the function currently calling into libjpeg
};

static void on_error(j_common_ptr info) {
    longjmp(*((struct error_manager *)info->err)->jump, 1);
}

static void silent(j_common_ptr info) { (void)info; }

static const char *difference(j_decompress_ptr a, jvirt_barray_ptr *ca,
                              j_decompress_ptr b, jvirt_barray_ptr *cb) {
    if (a->image_width != b->image_width || a->image_height != b->image_height)
        return "dimensions";
    if (a->num_components != b->num_components || a->jpeg_color_space != b->jpeg_color_space)
        return "colour components";
    for (int c = 0; c < a->num_components; c++) {
        jpeg_component_info *x = &a->comp_info[c], *y = &b->comp_info[c];
        // With a single component the sampling factors carry no meaning
        // (jpegtran normalizes 2x2 to 1x1 in grayscale files); the block grid
        // is what counts.
        if ((a->num_components > 1 && (x->h_samp_factor != y->h_samp_factor || x->v_samp_factor != y->v_samp_factor))
            || x->width_in_blocks != y->width_in_blocks || x->height_in_blocks != y->height_in_blocks)
            return "sampling";
        if (!x->quant_table || !y->quant_table
            || memcmp(x->quant_table->quantval, y->quant_table->quantval, sizeof x->quant_table->quantval) != 0)
            return "quantization tables";
        for (JDIMENSION row = 0; row < x->height_in_blocks; row++) {
            JBLOCKARRAY ra = (*a->mem->access_virt_barray)((j_common_ptr)a, ca[c], row, 1, FALSE);
            JBLOCKARRAY rb = (*b->mem->access_virt_barray)((j_common_ptr)b, cb[c], row, 1, FALSE);
            if (memcmp(ra[0], rb[0], x->width_in_blocks * sizeof(JBLOCK)) != 0)
                return "coefficients";
        }
    }
    return NULL;
}

/// Reads the whole file, to EOI; false on an error. Warnings (corrupt data
/// libjpeg works around, data after the image) are counted in num_warnings.
static int read_all(j_decompress_ptr info, FILE *file, jvirt_barray_ptr **coefficients) {
    jmp_buf here;
    ((struct error_manager *)info->err)->jump = &here;
    if (setjmp(here)) return 0;
    jpeg_stdio_src(info, file);
    jpeg_read_header(info, TRUE);
    *coefficients = jpeg_read_coefficients(info);
    return 1;
}

static int finish(j_decompress_ptr info) {
    jmp_buf here;
    ((struct error_manager *)info->err)->jump = &here;
    if (setjmp(here)) return 0;
    jpeg_finish_decompress(info);
    return 1;
}

/// Reads only the headers up to the first scan; false on an error.
static int read_headers(j_decompress_ptr info, FILE *file) {
    jmp_buf here;
    ((struct error_manager *)info->err)->jump = &here;
    if (setjmp(here)) return 0;
    jpeg_stdio_src(info, file);
    jpeg_read_header(info, TRUE);
    return 1;
}

/// Reads an 8-bit binary PPM ("P6 width height 255", one whitespace
/// character, then the samples). Returns the samples, or NULL.
static unsigned char *read_ppm(FILE *file, unsigned *width, unsigned *height) {
    unsigned maxval;
    if (fscanf(file, "P6 %u %u %u", width, height, &maxval) != 3 || maxval != 255 || fgetc(file) == EOF) return NULL;
    if (*width == 0 || *height == 0 || *width > 65535 || *height > 65535) return NULL;
    size_t size = (size_t)*width * *height * 3;
    unsigned char *samples = malloc(size);
    if (samples && fread(samples, 1, size, file) != size) { free(samples); return NULL; }
    return samples;
}

static int compare_pixels(const char *jpeg_path, const char *ppm_path) {
    FILE *fj = fopen(jpeg_path, "rb"), *fp = fopen(ppm_path, "rb");
    if (!fj || !fp) {
        fprintf(stderr, "jpegcmp: can't open input\n");
        return 2;
    }
    unsigned width, height;
    unsigned char *other = read_ppm(fp, &width, &height);
    fclose(fp);
    if (!other) {
        fclose(fj);
        fprintf(stderr, "jpegcmp: unreadable PPM\n");
        return 2;
    }
    struct jpeg_decompress_struct info;
    struct error_manager errors;
    info.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = on_error;
    errors.pub.output_message = silent;
    jpeg_create_decompress(&info);
    // Per block row: summed differences of each 8x8 block in the row.
    double *blocks = NULL;
    unsigned char *row = NULL;
    jmp_buf here;
    errors.jump = &here;
    if (setjmp(here)) {
        fprintf(stderr, "jpegcmp: unreadable JPEG\n");
        jpeg_destroy_decompress(&info);
        fclose(fj);
        free(other); free(blocks); free(row);
        return 2;
    }
    jpeg_stdio_src(&info, fj);
    jpeg_read_header(&info, TRUE);
    info.out_color_space = JCS_RGB;
    jpeg_start_decompress(&info);
    if (info.output_width != width || info.output_height != height || info.output_components != 3) {
        printf("different size\n");
        jpeg_destroy_decompress(&info);
        fclose(fj);
        free(other);
        return 1;
    }
    unsigned columns = (width + 7) / 8;
    blocks = calloc(columns, sizeof *blocks);
    row = malloc((size_t)width * 3);
    double total = 0, worst = 0;
    int largest = 0;
    while (info.output_scanline < height) {
        unsigned y = info.output_scanline;
        JSAMPROW rows[1] = {row};
        jpeg_read_scanlines(&info, rows, 1);
        const unsigned char *theirs = other + (size_t)y * width * 3;
        for (unsigned x = 0; x < width * 3; x++) {
            int d = abs((int)row[x] - (int)theirs[x]);
            total += d;
            blocks[x / 24] += d;
            if (d > largest) largest = d;
        }
        // A block row ends every 8 lines and at the image's last line.
        if (y % 8 == 7 || y + 1 == height) {
            unsigned lines = y % 8 + 1;
            for (unsigned c = 0; c < columns; c++) {
                unsigned span = (c + 1) * 8 <= width ? 8 : width - c * 8;
                double mean = blocks[c] / (span * lines * 3);
                if (mean > worst) worst = mean;
                blocks[c] = 0;
            }
        }
    }
    jpeg_finish_decompress(&info);
    jpeg_destroy_decompress(&info);
    fclose(fj);
    printf("mean %.3f block %.3f max %d\n", total / ((double)width * height * 3), worst, largest);
    free(other); free(blocks); free(row);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--pixels") == 0) return compare_pixels(argv[2], argv[3]);
    int check_only = argc == 3 && strcmp(argv[1], "--check") == 0;
    int headers_only = argc == 3 && strcmp(argv[1], "--check-headers") == 0;
    if (argc != 3) {
        fprintf(stderr, "usage: jpegcmp ORIGINAL RESULT\n       jpegcmp --check FILE\n       jpegcmp --check-headers FILE\n       jpegcmp --pixels JPEG PPM\n");
        return 2;
    }
    FILE *fa = check_only || headers_only ? NULL : fopen(argv[1], "rb"), *fb = fopen(argv[2], "rb");
    if ((!check_only && !headers_only && !fa) || !fb) {
        fprintf(stderr, "jpegcmp: can't open input\n");
        return 2;
    }
    struct jpeg_decompress_struct a, b;
    struct error_manager ea, eb;
    a.err = jpeg_std_error(&ea.pub);
    b.err = jpeg_std_error(&eb.pub);
    ea.pub.error_exit = eb.pub.error_exit = on_error;
    ea.pub.output_message = eb.pub.output_message = silent;
    jpeg_create_decompress(&a);
    jpeg_create_decompress(&b);
    if (headers_only) {
        int ok = read_headers(&b, fb) && eb.pub.num_warnings == 0;
        jpeg_destroy_decompress(&a);
        jpeg_destroy_decompress(&b);
        fclose(fb);
        return ok ? 0 : 3;
    }
    jvirt_barray_ptr *ca = NULL, *cb = NULL;
    if ((!check_only && !read_all(&a, fa, &ca)) || !read_all(&b, fb, &cb)) {
        fprintf(stderr, "jpegcmp: unreadable JPEG\n");
        return 2;
    }
    const char *what = NULL;
    if (!check_only) {
        jmp_buf here;
        ea.jump = eb.jump = &here;
        if (setjmp(here)) {
            fprintf(stderr, "jpegcmp: unreadable JPEG\n");
            return 2;
        }
        what = difference(&a, ca, &b, cb);
    }
    if (what) printf("different %s\n", what);
    // The result must also read to its end without a single warning.
    int clean = finish(&b) && eb.pub.num_warnings == 0;
    if (!what && !clean) printf("decoder warnings\n");
    jpeg_destroy_decompress(&a);
    jpeg_destroy_decompress(&b);
    if (fa) fclose(fa);
    fclose(fb);
    return what ? 1 : clean ? 0 : 3;
}
