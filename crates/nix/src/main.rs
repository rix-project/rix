use clap::{Parser, Subcommand};
use nix_parser::{ExprParser, Lexer};
use rootcause::Report;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Args {
    #[clap(subcommand)]
    subcommand: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Eval {
        /// Interpret expression from arguments
        #[arg(short, long, group = "input")]
        expr: Option<String>,

        /// Interpret expression from file
        #[arg(short, long, group = "input")]
        file: Option<PathBuf>,
    },
}

fn main() -> Result<(), Report> {
    let args = Args::parse();

    match args.subcommand {
        Commands::Eval { expr, file } => {
            let input = if let Some(expr) = expr {
                expr
            } else if let Some(file) = file {
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

            let lexer = Lexer::new(&input);
            let parser = ExprParser::new();
            let expr = parser.parse(lexer)?;
            println!("{expr:?}");

            // match nix_parser::parse(&input) {
            //     Ok(expr) => {
            //         match nix_eval::eval(expr, HashMap::new()) {
            //             Ok(value) => {
            //                 // Force the value deep to ensure everything is computed
            //                 match nix_eval::force_deep(&value) {
            //                     Ok(()) => println!("{value}"), // Uses Display impl of Value
            //                     Err(e) => eprintln!("Runtime error (forcing): {e}"),
            //                 }
            //             }
            //             Err(e) => eprintln!("Runtime error: {e}"),
            //         }
            //     }
            //     Err(e) => eprintln!("Parse error: {e}"),
            // }
        }
    }

    Ok(())
}
