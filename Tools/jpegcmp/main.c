// jpegcmp — proves that two JPEG files hold the same image data.
//
//     jpegcmp ORIGINAL RESULT
//
// Reads both files' quantized DCT coefficients with libjpeg (the same call
// jpegtran uses) and compares them block by block, together with the frame
// geometry, the sampling factors and the quantization tables. Equal
// coefficients and tables decode to the same pixels in every conforming
// decoder; this is a stronger proof than comparing one decoder's output.
//
// Exit status: 0 identical, 1 different, 2 unreadable.

#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include "jpeglib.h"

struct error_manager {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
};

static void on_error(j_common_ptr info) {
    longjmp(((struct error_manager *)info->err)->jump, 1);
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

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: jpegcmp ORIGINAL RESULT\n");
        return 2;
    }
    FILE *fa = fopen(argv[1], "rb"), *fb = fopen(argv[2], "rb");
    if (!fa || !fb) {
        fprintf(stderr, "jpegcmp: can't open input\n");
        return 2;
    }
    struct jpeg_decompress_struct a, b;
    struct error_manager errors; // shared, so one setjmp covers both decoders
    a.err = b.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = on_error;
    errors.pub.output_message = silent;
    jpeg_create_decompress(&a);
    jpeg_create_decompress(&b);
    if (setjmp(errors.jump)) {
        fprintf(stderr, "jpegcmp: unreadable JPEG\n");
        return 2;
    }
    jpeg_stdio_src(&a, fa);
    jpeg_stdio_src(&b, fb);
    jpeg_read_header(&a, TRUE);
    jpeg_read_header(&b, TRUE);
    jvirt_barray_ptr *ca = jpeg_read_coefficients(&a);
    jvirt_barray_ptr *cb = jpeg_read_coefficients(&b);
    const char *what = difference(&a, ca, &b, cb);
    if (what) printf("different %s\n", what);
    jpeg_destroy_decompress(&a);
    jpeg_destroy_decompress(&b);
    fclose(fa);
    fclose(fb);
    return what ? 1 : 0;
}
