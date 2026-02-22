use lalrpop_util::lalrpop_mod;

mod ast;
mod lexer;

lalrpop_mod!(
    #[allow(clippy::ptr_arg)]
    #[rustfmt::skip]
    nix
);

pub use ast::{BinOp, Binding, Expr, PrefixOp};
pub use lexer::{Lexer, Spanned, Token};
pub use nix::ExprParser;
