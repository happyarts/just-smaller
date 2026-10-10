// jxl-transcode — turns a JPEG into a JPEG XL file without loss, and back.
//
//     jxl-transcode encode [--effort 1..10] [--compress-boxes] INPUT.jpg OUTPUT.jxl
//     jxl-transcode decode INPUT.jxl OUTPUT.jpg
//
// encode hands the JPEG to libjxl as it is (JxlEncoderAddJPEGFrame): its
// quantized DCT coefficients are coded anew, and everything else — markers,
// Huffman tables, scan script, the bytes around the image — goes into a
// reconstruction box (jbrd), so decode rebuilds the very same file, byte for
// byte. EXIF and XMP are stored as metadata boxes other readers understand,
// Brotli-compressed only with --compress-boxes. Chroma from luma stays off:
// with it, a JPEG XL decoder shows a 4:4:4 JPEG's colours slightly
// differently than a JPEG decoder does, although the rebuilt file is the same.
//
// decode only rebuilds the JPEG from the reconstruction box; without one it
// fails rather than writing a new JPEG from pixels. An image larger than any
// JPEG can be (65535 pixels a side) is refused before anything is decoded.
//
// Exit status: 0 written, 1 failed (unreadable input, damaged file),
// 3 encode: a JPEG libjxl can't take without loss (arithmetic coding,
// 12-bit, CMYK, too much data after the image …), 4 decode: no
// reconstruction box.

#include <jxl/decode.h>
#include <jxl/encode.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static bool read_file(const char *path, std::vector<uint8_t> *out) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    uint8_t buffer[1 << 16];
    size_t n;
    while ((n = std::fread(buffer, 1, sizeof buffer, f)) > 0) out->insert(out->end(), buffer, buffer + n);
    bool ok = !std::ferror(f);
    std::fclose(f);
    return ok;
}

// Says why it failed (a full disk, say).
static bool write_file(const char *path, const uint8_t *data, size_t size) {
    FILE *f = std::fopen(path, "wb");
    bool ok = f && std::fwrite(data, 1, size, f) == size;
    int error = errno;
    if (f && std::fclose(f) != 0 && ok) { ok = false; error = errno; }
    if (!ok) {
        std::fprintf(stderr, "jxl-transcode: can't write output: %s\n", std::strerror(error));
        if (f) std::remove(path);
    }
    return ok;
}

static int fail(int status, const char *message) {
    std::fprintf(stderr, "jxl-transcode: %s\n", message);
    return status;
}

static int encode(const char *in, const char *out, int effort, bool compress_boxes) {
    std::vector<uint8_t> jpeg;
    if (!read_file(in, &jpeg) || jpeg.empty()) return fail(1, "can't read input");
    JxlEncoder *encoder = JxlEncoderCreate(nullptr);
    if (!encoder) return fail(1, "out of memory");
    struct Done { JxlEncoder *e; ~Done() { JxlEncoderDestroy(e); } } done{encoder};

    JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
    if (JxlEncoderUseContainer(encoder, JXL_TRUE) != JXL_ENC_SUCCESS
        || JxlEncoderStoreJPEGMetadata(encoder, JXL_TRUE) != JXL_ENC_SUCCESS
        || JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS
        || JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_BROTLI_EFFORT, 9) != JXL_ENC_SUCCESS
        || JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_JPEG_RECON_CFL, 0) != JXL_ENC_SUCCESS
        || JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_JPEG_COMPRESS_BOXES, compress_boxes ? 1 : 0)
               != JXL_ENC_SUCCESS)
        return fail(1, "can't configure the encoder");
    if (JxlEncoderAddJPEGFrame(settings, jpeg.data(), jpeg.size()) != JXL_ENC_SUCCESS)
        return fail(3, JxlEncoderGetError(encoder) == JXL_ENC_ERR_JBRD
                           ? "this JPEG can't be stored so that it can be rebuilt (CMYK, or too much data after the image?)"
                           : "this JPEG can't be transcoded without loss");
    JxlEncoderCloseInput(encoder);

    std::vector<uint8_t> jxl(jpeg.size() + 65536);
    uint8_t *next = jxl.data();
    size_t available = jxl.size();
    JxlEncoderStatus status;
    while ((status = JxlEncoderProcessOutput(encoder, &next, &available)) == JXL_ENC_NEED_MORE_OUTPUT) {
        size_t used = next - jxl.data();
        jxl.resize(jxl.size() * 2);
        next = jxl.data() + used;
        available = jxl.size() - used;
    }
    if (status != JXL_ENC_SUCCESS) return fail(1, "encoding failed");
    return write_file(out, jxl.data(), next - jxl.data()) ? 0 : 1;
}

static int decode(const char *in, const char *out) {
    std::vector<uint8_t> jxl;
    if (!read_file(in, &jxl) || jxl.empty()) return fail(1, "can't read input");
    JxlDecoder *decoder = JxlDecoderCreate(nullptr);
    if (!decoder) return fail(1, "out of memory");
    struct Done { JxlDecoder *d; ~Done() { JxlDecoderDestroy(d); } } done{decoder};

    if (JxlDecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO | JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE)
            != JXL_DEC_SUCCESS
        || JxlDecoderSetInput(decoder, jxl.data(), jxl.size()) != JXL_DEC_SUCCESS)
        return fail(1, "can't configure the decoder");
    JxlDecoderCloseInput(decoder);

    std::vector<uint8_t> jpeg(jxl.size() * 2 + 65536);
    bool reconstructing = false;
    for (;;) {
        switch (JxlDecoderProcessInput(decoder)) {
        case JXL_DEC_BASIC_INFO: {
            JxlBasicInfo info;
            if (JxlDecoderGetBasicInfo(decoder, &info) != JXL_DEC_SUCCESS) return fail(1, "the file can't be decoded");
            if (info.xsize > 65535 || info.ysize > 65535) return fail(4, "larger than any JPEG");
            break;
        }
        case JXL_DEC_JPEG_RECONSTRUCTION:
            reconstructing = true;
            if (JxlDecoderSetJPEGBuffer(decoder, jpeg.data(), jpeg.size()) != JXL_DEC_SUCCESS)
                return fail(1, "can't set the JPEG buffer");
            break;
        case JXL_DEC_JPEG_NEED_MORE_OUTPUT: {
            size_t used = jpeg.size() - JxlDecoderReleaseJPEGBuffer(decoder);
            jpeg.resize(jpeg.size() * 2);
            if (JxlDecoderSetJPEGBuffer(decoder, jpeg.data() + used, jpeg.size() - used) != JXL_DEC_SUCCESS)
                return fail(1, "can't set the JPEG buffer");
            break;
        }
        case JXL_DEC_NEED_IMAGE_OUT_BUFFER: // only asked for when there is nothing to rebuild from
            return fail(4, "no JPEG reconstruction data in this file");
        case JXL_DEC_FULL_IMAGE: {
            if (!reconstructing) return fail(4, "no JPEG reconstruction data in this file");
            size_t size = jpeg.size() - JxlDecoderReleaseJPEGBuffer(decoder);
            // A rebuilt JPEG is one frame; anything after it doesn't belong to it.
            return write_file(out, jpeg.data(), size) ? 0 : 1;
        }
        case JXL_DEC_SUCCESS:
            return fail(1, "no image in this file");
        case JXL_DEC_NEED_MORE_INPUT:
            return fail(1, "the file is incomplete");
        default:
            return fail(1, "the file can't be decoded");
        }
    }
}

int main(int argc, char **argv) {
    if (argc == 4 && std::strcmp(argv[1], "decode") == 0) return decode(argv[2], argv[3]);
    if (argc >= 4 && std::strcmp(argv[1], "encode") == 0) {
        int effort = 7;
        bool compress_boxes = false;
        int i = 2;
        for (; i < argc - 2; i++) {
            if (std::strcmp(argv[i], "--compress-boxes") == 0) {
                compress_boxes = true;
            } else if (std::strcmp(argv[i], "--effort") == 0 && i + 1 < argc - 2) {
                char *end;
                long value = std::strtol(argv[++i], &end, 10);
                if (*end || value < 1 || value > 10) return fail(1, "--effort must be 1 to 10");
                effort = (int)value;
            } else {
                break;
            }
        }
        if (i == argc - 2) return encode(argv[i], argv[i + 1], effort, compress_boxes);
    }
    std::fprintf(stderr, "usage: jxl-transcode encode [--effort 1..10] [--compress-boxes] INPUT.jpg OUTPUT.jxl\n"
                         "       jxl-transcode decode INPUT.jxl OUTPUT.jpg\n");
    return 1;
}
