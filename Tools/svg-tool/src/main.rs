//! svg-tool: the two things Just Smaller does with SVGs, in one small program.
//!
//!     svg-tool optimise [--config FILE] INPUT
//!         Runs the OXVG optimiser (MIT) and writes the result to stdout.
//!         FILE is an oxvg configuration (`{"optimise": {"jobs": {…}}}`);
//!         without it oxvg's default preset runs. Unlike the oxvg command, no
//!         configuration is ever picked up from the working directory or the
//!         user's settings.
//!
//!     svg-tool render INPUT OUTPUT.png [--canvas W H]
//!         Renders with resvg (MIT/Apache) on white. Without --canvas the
//!         picture has the SVG's own proportions, its longer side the SVG's
//!         own size but at least 1024 and at most 4096 pixels; with --canvas
//!         it is scaled to fit W×H and centred. Content resvg can't draw the
//!         way a browser would (unsupported features, resources that don't
//!         load) is printed to stderr as a line starting with "unsupported:";
//!         other warnings start with "note:".
//!
//! Exit status: 0 done, 1 error, 2 usage.

use std::io::{BufWriter, Write};
use std::process::ExitCode;

use oxvg_ast::{
    parse::roxmltree::parse_with_options,
    serialize::Node as _,
    visitor::Info,
    xmlwriter::{Indent, Options, Space},
};
use oxvg_optimiser::{Extends, Jobs};
use roxmltree::ParsingOptions;
use serde::Deserialize;

#[derive(Deserialize, Default)]
struct Config {
    optimise: Option<Optimise>,
}

#[derive(Deserialize)]
struct Optimise {
    extends: Option<Extends>,
    #[serde(default = "Jobs::none")]
    jobs: Jobs,
    omit: Option<Vec<String>>,
}

impl Optimise {
    // Same as oxvg's own config::Optimise::resolve_jobs.
    fn resolve_jobs(&self) -> Jobs {
        let Some(extends) = &self.extends else { return self.jobs.clone() };
        let mut result = extends.extend(&self.jobs);
        for omit in self.omit.iter().flatten() {
            result.omit(omit);
        }
        result
    }
}

fn optimise(config: Option<&str>, input: &str) -> Result<(), String> {
    let config: Config = match config {
        Some(path) => {
            let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
            serde_json::from_reader(file).map_err(|e| format!("{path}: {e}"))?
        }
        None => Config::default(),
    };
    let jobs = config.optimise.as_ref().map(Optimise::resolve_jobs).unwrap_or_default();
    let source = std::fs::read_to_string(input).map_err(|e| format!("{input}: {e}"))?;
    let options = Options { indent: Indent::None, trim_whitespace: Space::Auto, ..Options::default() };

    parse_with_options(&source, ParsingOptions { allow_dtd: true, ..ParsingOptions::default() }, |dom, allocator| {
        let info = Info { path: Some(input.into()), multipass_count: 0, allocator };
        jobs.run(dom, &info).map_err(|e| e.to_string())?;
        let mut out = BufWriter::new(std::io::stdout().lock());
        dom.serialize_into(&mut out, options).map_err(|e| e.to_string())?;
        out.flush().map_err(|e| e.to_string())
    })
    .map_err(|e| e.to_string())?
}

/// Warnings that mean resvg leaves out something a browser would draw.
/// Most others are about invalid values, which browsers ignore just the same.
const UNSUPPORTED: [&str; 6] = ["not supported", "isn't supported", "Failed to load", "Selector skipped",
                                "is not a PNG, JPEG, GIF, WebP", "is not a valid filter primitive"];

struct Warnings;
impl log::Log for Warnings {
    fn enabled(&self, m: &log::Metadata) -> bool { m.level() <= log::Level::Warn }
    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) { return }
        let message = r.args().to_string();
        let kind = if UNSUPPORTED.iter().any(|u| message.contains(u)) { "unsupported" } else { "note" };
        eprintln!("{kind}: {message}");
    }
    fn flush(&self) {}
}
static WARNINGS: Warnings = Warnings;

fn render(input: &str, output: &str, canvas: Option<(u32, u32)>) -> Result<(), String> {
    use resvg::{tiny_skia, usvg};
    log::set_logger(&WARNINGS).ok();
    log::set_max_level(log::LevelFilter::Warn);
    let data = std::fs::read(input).map_err(|e| format!("{input}: {e}"))?;
    let mut options = usvg::Options::default();
    options.resources_dir = std::path::Path::new(input).parent().map(|p| p.to_path_buf());
    // Loading the system fonts takes a noticeable moment; only text needs them.
    if data.windows(4).any(|w| w == b"text") {
        let fonts = options.fontdb_mut();
        fonts.load_system_fonts();
        // Safari's generic families.
        fonts.set_serif_family("Times");
        fonts.set_sans_serif_family("Helvetica");
        fonts.set_monospace_family("Courier");
    }
    options.font_family = "Times".into();
    let tree = usvg::Tree::from_data(&data, &options).map_err(|e| format!("{input}: {e}"))?;

    let s = tree.size();
    let (w, h) = canvas.unwrap_or_else(|| {
        let side = s.width().max(s.height()).ceil().clamp(1024.0, 4096.0);
        let k = side / s.width().max(s.height());
        (((s.width() * k).round() as u32).max(1), ((s.height() * k).round() as u32).max(1))
    });
    let scale = (w as f32 / s.width()).min(h as f32 / s.height());
    let (dx, dy) = ((w as f32 - s.width() * scale) / 2.0, (h as f32 - s.height() * scale) / 2.0);
    let mut pixmap = tiny_skia::Pixmap::new(w, h).ok_or("image too large")?;
    pixmap.fill(tiny_skia::Color::WHITE);
    resvg::render(&tree, tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, dx, dy), &mut pixmap.as_mut());
    pixmap.save_png(output).map_err(|e| format!("{output}: {e}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["optimise", input] => optimise(None, input),
        ["optimise", "--config", config, input] => optimise(Some(config), input),
        ["render", input, output] => render(input, output, None),
        ["render", input, output, "--canvas", w, h] => match (w.parse(), h.parse()) {
            (Ok(w), Ok(h)) if (1..=8192).contains(&w) && (1..=8192).contains(&h) => render(input, output, Some((w, h))),
            _ => return usage(),
        },
        _ => return usage(),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("svg-tool: {message}");
            ExitCode::FAILURE
        }
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: svg-tool optimise [--config FILE] INPUT\n       svg-tool render INPUT OUTPUT.png [--canvas W H]");
    ExitCode::from(2)
}
