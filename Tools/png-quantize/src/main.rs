//! png-quantize — reduces a PNG to a palette of at most 256 colours.
//!
//!     png-quantize INPUT OUTPUT [--colors N] [--dither 0..1]
//!
//! Uses quantizr (MIT) for the palette and dithering. The colour metadata of
//! the input — ICC profile, sRGB intent, gamma, chromaticities and physical
//! pixel size — is written to the output, so the colours are interpreted the
//! same way, including a cICP chunk. HDR images (PQ or HLG transfer, or mDCV
//! and cLLI chunks) are left alone: a palette of 8-bit colours can't hold them.
//! Exit status: 0 written, 1 error, 97 HDR image left alone, 98 input already
//! has a palette.

use std::borrow::Cow;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(e) => {
            eprintln!("png-quantize: {e}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<ExitCode, Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut paths = Vec::new();
    let (mut colors, mut dither) = (256i32, 1.0f32);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--colors" => { i += 1; colors = args.get(i).ok_or("--colors needs a value")?.parse()?; }
            "--dither" => { i += 1; dither = args.get(i).ok_or("--dither needs a value")?.parse()?; }
            other => paths.push(other.to_string()),
        }
        i += 1;
    }
    let [input, output] = paths.as_slice() else {
        return Err("usage: png-quantize INPUT OUTPUT [--colors N] [--dither 0..1]".into());
    };

    let raw = std::fs::read(input)?;
    let cicp = chunk(&raw, b"cICP");
    // cICP data: colour primaries, transfer function, matrix, full range; 16 = PQ, 18 = HLG
    let hdr_transfer = cicp.is_some_and(|c| c.len() >= 10 && matches!(c[9], 16 | 18));
    if hdr_transfer || chunk(&raw, b"mDCV").is_some() || chunk(&raw, b"cLLI").is_some() {
        return Ok(ExitCode::from(97));
    }
    let mut decoder = png::Decoder::new(File::open(input)?);
    decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
    let mut reader = decoder.read_info()?;
    if reader.info().color_type == png::ColorType::Indexed {
        return Ok(ExitCode::from(98));
    }
    let source = reader.info().clone();
    let mut buffer = vec![0; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer)?;
    let (w, h) = (frame.width as usize, frame.height as usize);
    let rgba: Vec<u8> = match frame.color_type {
        png::ColorType::Rgba => buffer[..w * h * 4].to_vec(),
        png::ColorType::GrayscaleAlpha => buffer[..w * h * 2].chunks(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Rgb => buffer[..w * h * 3].chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::Grayscale => buffer[..w * h].iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => unreachable!(),
    };

    let image = quantizr::Image::new(&rgba, w, h)?;
    let mut options = quantizr::Options::default();
    options.set_max_colors(colors)?;
    let mut result = quantizr::QuantizeResult::quantize(&image, &options);
    result.set_dithering_level(dither)?;
    let mut indices = vec![0u8; w * h];
    result.remap_image(&image, &mut indices)?;

    let palette = result.get_palette();
    let entries = &palette.entries[..palette.count as usize];
    let mut info = png::Info::with_size(w as u32, h as u32);
    info.color_type = png::ColorType::Indexed;
    info.bit_depth = png::BitDepth::Eight;
    info.palette = Some(Cow::Owned(entries.iter().flat_map(|c| [c.r, c.g, c.b]).collect()));
    if entries.iter().any(|c| c.a != 255) {
        info.trns = Some(Cow::Owned(entries.iter().map(|c| c.a).collect()));
    }
    // Keep how the colours are to be interpreted.
    info.icc_profile = source.icc_profile.clone();
    info.srgb = source.srgb;
    info.source_gamma = source.source_gamma;
    info.source_chromaticities = source.source_chromaticities;
    info.pixel_dims = source.pixel_dims;

    let mut encoded = Vec::new();
    png::Encoder::with_info(&mut encoded, info)?.write_header()?.write_image_data(&indices)?;
    // The png crate can't write cICP; it belongs right after IHDR (signature 8 + IHDR 25 bytes).
    if let Some(cicp) = cicp {
        encoded.splice(33..33, cicp.iter().copied());
    }
    BufWriter::new(File::create(output)?).write_all(&encoded)?;
    Ok(ExitCode::SUCCESS)
}

/// The complete chunk (length, type, data, CRC) of the given type before the image data.
fn chunk<'a>(data: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    let mut i = 8;
    while i + 8 <= data.len() {
        let length = u32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]) as usize;
        let end = i.checked_add(12 + length).filter(|&e| e <= data.len())?;
        match &data[i + 4..i + 8] {
            t if t == kind => return Some(&data[i..end]),
            b"IDAT" | b"IEND" => return None,
            _ => i = end,
        }
    }
    None
}
