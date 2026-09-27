//! svg-optimise: runs the OXVG optimiser (MIT) on one SVG and writes the
//! result to standard output.
//!
//!     svg-optimise [--config FILE] INPUT
//!
//! FILE is an oxvg configuration (`{"optimise": {"jobs": {…}}}`); without it
//! oxvg's default preset runs. Unlike the oxvg command, no configuration is
//! ever picked up from the working directory or the user's settings.
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

fn run(config: Option<&str>, input: &str) -> Result<(), String> {
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

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (config, input) = match args.as_slice() {
        [input] => (None, input),
        [flag, config, input] if flag == "--config" => (Some(config.as_str()), input),
        _ => {
            eprintln!("usage: svg-optimise [--config FILE] INPUT");
            return ExitCode::from(2);
        }
    };
    match run(config, input) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("svg-optimise: {message}");
            ExitCode::FAILURE
        }
    }
}
