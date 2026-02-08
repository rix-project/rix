pub mod eval;
pub mod value;

pub use eval::{eval, force_deep};
pub use value::{EvalError, Thunk, Value};

#[cfg(test)]
mod tests;
