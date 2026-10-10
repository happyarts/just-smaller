//! jxl-pixels — decodes a JPEG XL image to 8-bit RGB with jxl-rs.
//!
//!     jxl-pixels INPUT.jxl > OUTPUT.ppm
//!     jxl-pixels --orientation INPUT.jxl
//!
//! jxl-rs (BSD-3) is the decoder Chrome and Firefox use, written apart from
//! libjxl. The image is written to standard output as a binary PPM, as it is
//! stored — its orientation turned back — in the colour space it is coded
//! in: for a JPEG turned into JPEG XL that is the JPEG's own, so the pixels
//! can be compared with what a JPEG decoder makes of the JPEG (piped into
//! `jpegcmp --pixels JPEG -`). Only the first frame; alpha and other extra
//! channels are left out. With --orientation, only the header is read and
//! the orientation it states is printed (1–8, as in EXIF): "orientation 6".
//! Exit status: 0 written, 1 error.

use std::io::Write;
use std::process::ExitCode;

use jxl::api::{JxlDecoder, JxlDecoderOptions, JxlOutputBuffer, JxlPixelFormat, ProcessingResult, states};

/// No more samples than this (pixels × channels): a hostile file can't make
/// the decoder take all memory.
const SAMPLE_LIMIT: usize = 1 << 30;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [flag, input] if flag == "--orientation" => orientation(input),
        [input] => pixels(input),
        _ => {
            eprintln!("usage: jxl-pixels INPUT.jxl > OUTPUT.ppm\n       jxl-pixels --orientation INPUT.jxl");
            return ExitCode::from(1);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("jxl-pixels: {e}");
            ExitCode::from(1)
        }
    }
}

/// The decoder with the file's header read, and the rest of the file.
fn header(data: &[u8]) -> Result<(JxlDecoder<states::WithImageInfo>, &[u8]), String> {
    let mut rest = data;
    let mut options = JxlDecoderOptions::default();
    // Oriented pixels; turned back below. (jxl-rs 0.7 ignores this switch
    // and always orients, so it is set explicitly to what it does.)
    options.adjust_orientation = true;
    options.sample_limit = Some(SAMPLE_LIMIT);
    let decoder = JxlDecoder::<states::Initialized>::new(options);
    match decoder.process(&mut rest, None).map_err(|e| format!("{e:?}"))? {
        ProcessingResult::Complete { result } => Ok((result, rest)),
        ProcessingResult::NeedsMoreInput { .. } => Err("the file is incomplete".into()),
    }
}

fn read(input: &str) -> Result<Vec<u8>, String> {
    std::fs::read(input).map_err(|e| format!("can't read input: {e}"))
}

fn orientation(input: &str) -> Result<(), String> {
    let data = read(input)?;
    let (decoder, _) = header(&data)?;
    println!("orientation {}", decoder.basic_info().orientation as usize);
    Ok(())
}

fn pixels(input: &str) -> Result<(), String> {
    let data = read(input)?;
    let (mut decoder, mut rest) = header(&data)?;
    let extra = decoder.basic_info().extra_channels.len();
    let orientation = decoder.basic_info().orientation as usize;
    decoder.set_pixel_format(JxlPixelFormat::rgba8(extra)).map_err(|e| format!("{e:?}"))?;
    let frame = match decoder.process(&mut rest, None).map_err(|e| format!("{e:?}"))? {
        ProcessingResult::Complete { result } => result,
        ProcessingResult::NeedsMoreInput { .. } => return Err("the file is incomplete".into()),
    };
    let (width, height) = frame.frame_header().size;
    let mut rgba = vec![0u8; width.checked_mul(height).and_then(|n| n.checked_mul(4)).ok_or("image too large")?];
    {
        let mut buffers = [JxlOutputBuffer::new(&mut rgba, height, width * 4)];
        match frame.process(&mut rest, &mut buffers, None).map_err(|e| format!("{e:?}"))? {
            ProcessingResult::Complete { .. } => {}
            ProcessingResult::NeedsMoreInput { .. } => return Err("the file is incomplete".into()),
        }
    }
    // The stored image's size, and for each stored pixel where it is shown.
    let transposed = orientation >= 5;
    let (w, h) = if transposed { (height, width) } else { (width, height) };
    let shown = |x: usize, y: usize| -> (usize, usize) {
        match orientation {
            2 => (w - 1 - x, y),
            3 => (w - 1 - x, h - 1 - y),
            4 => (x, h - 1 - y),
            5 => (y, x),
            6 => (h - 1 - y, x),
            7 => (h - 1 - y, w - 1 - x),
            8 => (y, w - 1 - x),
            _ => (x, y),
        }
    };
    let write = || -> std::io::Result<()> {
        let mut out = std::io::BufWriter::new(std::io::stdout().lock());
        write!(out, "P6\n{w} {h}\n255\n")?;
        for y in 0..h {
            for x in 0..w {
                let (sx, sy) = shown(x, y);
                let i = (sy * width + sx) * 4;
                out.write_all(&rgba[i..i + 3])?;
            }
        }
        out.flush()
    };
    write().map_err(|e| format!("can't write output: {e}"))
}
