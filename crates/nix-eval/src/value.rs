use nix_parser::ast;
use parking_lot::{Condvar, Mutex};
use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use derive_more::{Display, Error};

#[derive(Debug, Clone, Display, Error)]
pub enum EvalError {
    #[display("Type mismatch: {}", _0)]
    #[error(ignore)]
    TypeMismatch(String),
    #[display("Not found: {}", _0)]
    #[error(ignore)]
    NotFound(String),
    #[display("Infinite recursion detected")]
    InfiniteRecursion,
    #[display("User error: {}", _0)]
    #[error(ignore)]
    User(String),
    #[display("Error: {}", _0)]
    #[error(ignore)]
    Other(String),
}

#[derive(Clone)]
pub enum Value<'a> {
    True,
    False,
    Null,
    Int(i64),
    Float(f64),
    String(Arc<str>), // Owned string or Cow? Value usually owns its string representation.
    // If it comes from AST literal, it could borrow. But simplification: Arc<str>.
    List(Arc<[Thunk<'a>]>),
    Set(Arc<HashMap<String, Thunk<'a>>>),
    Closure(Arc<Closure<'a>>),
    Path(Arc<str>),
}

#[derive(Clone)]
pub struct Closure<'a> {
    pub env: Arc<Env<'a>>,
    pub pattern: ast::Pattern<'a>,
    pub body: ast::Expr<'a>,
}

pub type Env<'a> = HashMap<String, Thunk<'a>>;

#[derive(Clone)]
pub struct Thunk<'a> {
    inner: Arc<ThunkInner<'a>>,
}

struct ThunkInner<'a> {
    state: Mutex<ThunkState<'a>>,
    cond: Condvar,
}

enum ThunkState<'a> {
    Evaluated(Value<'a>),
    Suspended(Box<dyn Fn() -> Result<Value<'a>, EvalError> + Send + Sync + 'a>),
    Blackhole,
    Failed(EvalError),
}

impl<'a> Thunk<'a> {
    pub fn new<F>(f: F) -> Self
    where
        F: Fn() -> Result<Value<'a>, EvalError> + Send + Sync + 'a,
    {
        Thunk {
            inner: Arc::new(ThunkInner {
                state: Mutex::new(ThunkState::Suspended(Box::new(f))),
                cond: Condvar::new(),
            }),
        }
    }

    #[must_use]
    pub fn new_evaluated(v: Value<'a>) -> Self {
        Thunk {
            inner: Arc::new(ThunkInner {
                state: Mutex::new(ThunkState::Evaluated(v)),
                cond: Condvar::new(),
            }),
        }
    }

    pub fn force(&self) -> Result<Value<'a>, EvalError> {
        let mut state = self.inner.state.lock();
        loop {
            match &mut *state {
                ThunkState::Evaluated(v) => return Ok(v.clone()),
                ThunkState::Failed(e) => return Err(e.clone()),
                ThunkState::Blackhole => {
                    self.inner.cond.wait(&mut state);
                }
                ThunkState::Suspended(_) => {
                    // Extract closure
                    let ThunkState::Suspended(func) =
                        std::mem::replace(&mut *state, ThunkState::Blackhole)
                    else {
                        unreachable!()
                    };

                    drop(state); // Unlock to execute

                    let res = func();

                    let mut state = self.inner.state.lock();
                    match res {
                        Ok(v) => {
                            *state = ThunkState::Evaluated(v.clone());
                            self.inner.cond.notify_all();
                            return Ok(v);
                        }
                        Err(e) => {
                            *state = ThunkState::Failed(e.clone());
                            self.inner.cond.notify_all();
                            return Err(e);
                        }
                    }
                }
            }
        }
    }
}

impl PartialEq for Value<'_> {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::True, Value::True)
            | (Value::False, Value::False)
            | (Value::Null, Value::Null) => true,
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Float(a), Value::Float(b)) => a == b,
            (Value::String(a), Value::String(b)) | (Value::Path(a), Value::Path(b)) => a == b,
            (Value::List(a), Value::List(b)) => {
                if a.len() != b.len() {
                    return false;
                }
                a.iter().zip(b.iter()).all(|(ta, tb)| ta == tb)
            }
            (Value::Set(a), Value::Set(b)) => {
                if a.len() != b.len() {
                    return false;
                }
                // Keys must match and values must match
                for (k, v) in a.iter() {
                    if let Some(ov) = b.get(k) {
                        if v != ov {
                            return false;
                        }
                    } else {
                        return false;
                    }
                }
                true
            }
            (Value::Closure(a), Value::Closure(b)) => {
                Arc::ptr_eq(&a.env, &b.env) && std::ptr::eq(&raw const a.body, &raw const b.body)
            } // Weak eq
            _ => false,
        }
    }
}

impl PartialEq for Thunk<'_> {
    fn eq(&self, other: &Self) -> bool {
        // Deep equality requires forcing
        // We force both. If fails, panic or false?
        // For testing, we panic if force fails inside assert_eq.
        // In real Nix, `==` forces terms.
        let v1 = self.force().unwrap(); // TODO: handle error
        let v2 = other.force().unwrap();
        v1 == v2
    }
}

impl fmt::Debug for Value<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::True => write!(f, "true"),
            Value::False => write!(f, "false"),
            Value::Null => write!(f, "null"),
            Value::Int(i) => write!(f, "{i}"),
            Value::Float(n) => write!(f, "{n}"),
            Value::String(s) => write!(f, "{s:?}"),
            Value::List(l) => write!(f, "<list {}>", l.len()),
            Value::Set(s) => write!(f, "<set {}>", s.len()),
            Value::Closure(_) => write!(f, "<lambda>"),
            Value::Path(p) => write!(f, "<path {p}>"),
        }
    }
}

impl fmt::Display for Value<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::True => write!(f, "true"),
            Value::False => write!(f, "false"),
            Value::Null => write!(f, "null"),
            Value::Int(i) => write!(f, "{i}"),
            Value::Float(n) => write!(f, "{n}"),
            Value::String(s) => write!(f, "{s:?}"), // Quote string
            Value::Path(p) => write!(f, "{p}"),
            Value::Closure(_) => write!(f, "<LAMBDA>"),
            Value::List(items) => {
                write!(f, "[ ")?;
                for item in items.iter() {
                    // Try primitive force for display
                    match item.force() {
                        Ok(v) => write!(f, "{v} ")?,
                        Err(_) => write!(f, "<error> ")?,
                    }
                }
                write!(f, "]")
            }
            Value::Set(map) => {
                write!(f, "{{ ")?;
                for (k, v) in map.iter() {
                    write!(f, "{k} = ")?;
                    match v.force() {
                        Ok(val) => write!(f, "{val}; ")?,
                        Err(_) => write!(f, "<error>; ")?,
                    }
                }
                write!(f, "}}")
            }
        }
    }
}

impl fmt::Debug for Thunk<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Thunk")
    }
}
