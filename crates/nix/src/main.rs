use clap::Parser;
use rootcause::Report;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Args {
    /// Interpret expression from arguments
    #[arg(short, long, group = "input")]
    expr: Option<String>,

    /// Interpret expression from file
    #[arg(short, long, group = "input")]
    file: Option<PathBuf>,
}

fn main() -> Result<(), Report> {
    let args = Args::parse();

    let input = if let Some(expr) = args.expr {
        expr
    } else if let Some(file) = args.file {
        fs::read_to_string(file)?
    } else {
        // Read from stdin?
        // Default to stdin if no file/expr provided?
        // For now, require one or the other or check `input` group.
        // Or if nothing, maybe REPL?
        // Let's implement reading from stdin if nothing else provided.
        use std::io::Read;
        let mut buffer = String::new();
        std::io::stdin().read_to_string(&mut buffer)?;
        buffer
    };

    match nix_parser::parse(&input) {
        Ok(expr) => {
            match nix_eval::eval(expr, HashMap::new()) {
                Ok(value) => {
                    // Force the value deep to ensure everything is computed
                    match nix_eval::force_deep(&value) {
                        Ok(()) => println!("{value}"), // Uses Display impl of Value
                        Err(e) => eprintln!("Runtime error (forcing): {e}"),
                    }
                }
                Err(e) => eprintln!("Runtime error: {e}"),
            }
        }
        Err(e) => eprintln!("Parse error: {e}"),
    }

    Ok(())
}
