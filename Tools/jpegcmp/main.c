// jpegcmp — proves that two JPEG files hold the same image data.
//
//     jpegcmp ORIGINAL RESULT
//     jpegcmp --check FILE
//
// Reads both files' quantized DCT coefficients with libjpeg (the same call
// jpegtran uses) and compares them block by block, together with the frame
// geometry, the sampling factors and the quantization tables. Equal
// coefficients and tables decode to the same pixels in every conforming
// decoder; this is a stronger proof than comparing one decoder's output.
//
// With --check, only reads FILE.
//
// Exit status: 0 identical, 1 different, 2 unreadable, 3 the result reads
// only with warnings (damaged data, bytes where a marker belongs).

#include <setjmp.h>
#include <stdio.h>
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

int main(int argc, char **argv) {
    int check_only = argc == 3 && strcmp(argv[1], "--check") == 0;
    if (argc != 3) {
        fprintf(stderr, "usage: jpegcmp ORIGINAL RESULT\n       jpegcmp --check FILE\n");
        return 2;
    }
    FILE *fa = check_only ? NULL : fopen(argv[1], "rb"), *fb = fopen(argv[2], "rb");
    if ((!check_only && !fa) || !fb) {
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
