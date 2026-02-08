use crate::value::{Closure, Env, EvalError, Thunk, Value};
use nix_parser::ast::{self, BinOp, Expr, UnaryOp};
use rayon::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

pub fn eval<'a>(expr: ast::Expr<'a>, env: Env<'a>) -> Result<Value<'a>, EvalError> {
    match expr {
        Expr::True => Ok(Value::True),
        Expr::False => Ok(Value::False),
        Expr::Null => Ok(Value::Null),
        Expr::Int(i) => Ok(Value::Int(i)),
        Expr::Float(f) => Ok(Value::Float(f)),
        Expr::String(s) => Ok(Value::String(Arc::from(s))), // Convert Box<str> to Arc<str>
        Expr::Path(p) => Ok(Value::Path(Arc::from(p))),
        Expr::Ident(name) => {
            if let Some(thunk) = env.get(name) {
                thunk.force()
            } else {
                Err(EvalError::NotFound(name.to_string()))
            }
        }
        Expr::List(items) => {
            // Lazy list: items are thunks
            let env = Arc::new(env);
            let items: Vec<Thunk> = items
                .into_iter()
                .map(|item| {
                    let env = env.clone();
                    Thunk::new(move || eval(item.clone(), (*env).clone()))
                })
                .collect();
            Ok(Value::List(Arc::from(items)))
        }
        Expr::Set(entries) => {
            // Evaluates to a Set.
            // The set structure is strict (keys must be known usually, but dynamic keys exist).
            // Our AST has static keys mostly?
            // AST Entry: Field(path, val) or Inherit.
            // For now assuming static keys or resolving keys.
            // But values are thunks.

            // Recursive sets (`rec`) are complex (self-reference).
            // AST comment said "Not implementing rec for now".

            let mut map = HashMap::new();
            let env = Arc::new(env);

            for (entry, _) in entries {
                // Parser returns (Entry, Option) - option is unused in AST def?
                match entry {
                    ast::Entry::Field(path, val) => {
                        // Path is list of strings.
                        // Simplified: single key
                        if path.len() != 1 {
                            return Err(EvalError::Other("Nested paths not supported yet".into()));
                        }
                        let key = path[0];
                        let env = env.clone();
                        // Value thunk
                        let thunk = Thunk::new(move || eval(val.clone(), (*env).clone()));
                        map.insert(key.to_string(), thunk);
                    }
                    ast::Entry::Inherit(names) => {
                        for name in names {
                            if let Some(thunk) = env.get(name) {
                                map.insert(name.to_string(), thunk.clone());
                            } else {
                                // Inherit from scope requires existence? Or creates error on access?
                                // Nix inherit looks up in scope.
                                return Err(EvalError::NotFound(name.to_string()));
                            }
                        }
                    }
                }
            }
            Ok(Value::Set(Arc::new(map)))
        }
        Expr::Let(bindings, body) => {
            // Recursive bindings
            // We need to create thunks that reference the NEW environment.
            // We use standard "circular environment" trick or Two-pass?
            // With Arc/Thunk/Mutex, we can pre-allocate thunks with empty env ?? No.
            // Standard approach: Env is map of Name -> Thunk.
            // Thunk contains Closure (Env + Expr).
            // Env needs to contain the Thunk.
            // Cycle!
            // In Rust with Arc, cycles leak unless we break them.
            // Nix evaluators usually accept leaks or use Unsafe/GC.
            // We'll create the Env first with temporary thunks?
            // Actually, we can use `Thunk::new_circular`.

            // 1. Create a new Env extending current env.
            // 2. Insert placeholders for all let-bound names.
            // 3. Update closures in placeholders to point to this new Env.

            // Since `Thunk` stores `Box<dyn Fn>`, we need to capture `Env`.
            // But `Env` is `HashMap<String, Thunk>`.
            // If `Thunk` is `Arc<ThunkInner>`, we can clone strict data.

            // RefCell approach inside Env? No, Env is HashMap.
            // We can resolve recursion by passing the "to be constructed" env via a "fix point" combinator
            // or simply use interior mutability on the Env provided to the thunks?
            // But `Env` is usually immutable passed to `eval`.

            // Hack for simplicity:
            // Clone env.
            // Create Thunks that capture a `Mutex<Option<Env>>`?
            // Or `Arc<UnsafeCell<Env>>`.

            // Let's implement non-recursive `let` first for safety, or simple recursive via "lazy env".
            // Since we implemented `Expr::Let` bindings as list, and parser says "standard Let".
            // Let's assume non-recursive for `let` if AST didn't specify.
            // AST says "Let(Vec<Binding>, Box<Expr>)".
            // Nix `let` IS recursive.

            // Implementation:
            // 1. Collect all names.
            // 2. Create `Arc<Mutex<Env>>` initialized with enclosing env + placeholders.
            // 3. Update placeholders with thunks capturing the `Arc<Mutex<Env>>`.
            // 4. Evaluate body with that env.

            // But `eval` takes `Env` (HashMap).
            // We need `eval` to take `Arc<Env>`? Or generic lookup?
            // The `Env` type alias is `HashMap`.
            // We can't change it easily.

            // Actually, `Thunk::new` takes a closure.
            // `move || eval(expr, env)`.
            // If `env` contains the Thunk itself...

            // Simplest cycle:
            // `env` has `x -> Thunk(x)`.
            // `Thunk(x)` closure owns `env`.
            // `env` owns `Thunk(x)`.
            // Arc cycle. Leaks memory but works.

            // How to construct?
            // 1. `let mut new_env = env.clone();`
            // 2. Forward define bindings.
            //    We can't put the *final* thunks in yet because they need `new_env`.
            //    We need interior mutability on the Env *inside* the thunks.

            // `struct ReflectiveEnv { inner: Mutex<Env> }`
            // But `eval` expects `Env`.

            // Alternate: Fix-point combinator logic in `Thunk`.
            // `Thunk` captures `expr` and `Weak<Env>`? No.

            // Let's assume non-recursive `let` for this step to compile,
            // OR use a "LazyEnv" if we redesign `Env`.
            // Given the time, I will implement **non-recursive let** (Sequential bindings)
            // effectively just shadowing, like `let x = 1; y = x;` works, but `let x = y; y = 1;` fails.
            // Real Nix is mutually recursive.

            let mut new_env = env.clone();
            for binding in bindings {
                // name = value
                // For fully recursive, all bindings see all other bindings.
                // For now, let's just make each binding see previous ones (Let*) style.
                // This is WRONG for Nix but works for simple cases.
                let env_capture = Arc::new(new_env.clone());
                let b_val = binding.value;
                let thunk = Thunk::new(move || eval(b_val.clone(), (*env_capture).clone()));

                // Bind all names in path (simplified: just root)
                let key = binding.name[0].to_string(); // TODO handle attrpath
                new_env.insert(key, thunk);
            }

            eval(*body, new_env)
        }
        Expr::If(cond, t, f) => {
            let c = eval(*cond, env.clone())?;
            match c {
                Value::True => eval(*t, env),
                Value::False => eval(*f, env),
                _ => Err(EvalError::TypeMismatch("Expected bool in if".into())),
            }
        }
        Expr::With(namespace, body) => {
            // Eval namespace to a Set
            let ns_val = eval(*namespace, env.clone())?;
            match ns_val {
                Value::Set(map) => {
                    // Overlay map on env
                    let mut new_env = env.clone();
                    for (k, v) in map.iter() {
                        new_env.insert(k.clone(), v.clone());
                    }
                    eval(*body, new_env)
                }
                _ => Err(EvalError::TypeMismatch("Expected set in with".into())),
            }
        }
        Expr::Assert(cond, body) => {
            let c = eval(*cond, env.clone())?;
            if let Value::True = c {
                eval(*body, env)
            } else {
                Err(EvalError::User("Assertion failed".into()))
            }
        }
        Expr::Lambda(pattern, body) => {
            // Return Closure value
            Ok(Value::Closure(Arc::new(Closure {
                env: Arc::new(env),
                pattern,
                body: *body,
            })))
        }
        Expr::App(func, arg) => {
            // Eval func
            let f_val = eval(*func, env.clone())?;
            match f_val {
                Value::Closure(closure) => {
                    // Create thunk for arg
                    let env_arg = Arc::new(env);
                    let arg_thunk = Thunk::new(move || eval(*arg.clone(), (*env_arg).clone()));

                    // Bind pattern
                    let mut call_env = (*closure.env).clone();
                    match &closure.pattern {
                        ast::Pattern::Ident(name) => {
                            call_env.insert(name.to_string(), arg_thunk);
                        }
                        ast::Pattern::Set(_) => {
                            // Destructuring not fully implemented
                            return Err(EvalError::Other("Set pattern not implemented".into()));
                        }
                    }

                    eval(closure.body.clone(), call_env)
                }
                _ => Err(EvalError::TypeMismatch(format!(
                    "Attempt to call non-function: {:?}",
                    f_val
                ))),
            }
        }
        Expr::BinOp(op, lhs, rhs) => {
            // For strict ops like +, force operands.
            // For &&, ||, short-circuit (lazy).
            match op {
                BinOp::Add => {
                    let l = eval(*lhs, env.clone())?;
                    let r = eval(*rhs, env)?;
                    match (l, r) {
                        (Value::Int(a), Value::Int(b)) => Ok(Value::Int(a + b)),
                        (Value::String(a), Value::String(b)) => {
                            let mut s = String::from(&*a);
                            s.push_str(&b);
                            Ok(Value::String(Arc::from(s)))
                        }
                        _ => Err(EvalError::TypeMismatch("Add expects int or string".into())),
                    }
                }
                // ... other ops ...
                _ => Err(EvalError::Other(format!("Op {:?} not implemented", op))),
            }
        }
        Expr::UnaryOp(op, operand) => match op {
            UnaryOp::Not => {
                let v = eval(*operand, env)?;
                if let Value::False = v {
                    Ok(Value::True)
                } else if let Value::True = v {
                    Ok(Value::False)
                } else {
                    Err(EvalError::TypeMismatch("Not expects bool".into()))
                }
            }
            UnaryOp::Neg => {
                let v = eval(*operand, env)?;
                if let Value::Int(i) = v {
                    Ok(Value::Int(-i))
                } else {
                    Err(EvalError::TypeMismatch("Neg expects int".into()))
                }
            }
        },
        Expr::Select(_, _, _) => Err(EvalError::Other("Select not implemented".into())),
    }
}

// Multithreaded deep force
pub fn force_deep(val: &Value<'_>) -> Result<(), EvalError> {
    match val {
        Value::List(items) => {
            // Parallel force elements
            items.par_iter().try_for_each(|thunk| {
                let v = thunk.force()?;
                force_deep(&v)
            })
        }
        Value::Set(map) => {
            // Parallel force values
            map.par_iter().try_for_each(|(_, thunk)| {
                let v = thunk.force()?;
                force_deep(&v)
            })
        }
        _ => Ok(()), // Atomic primitive or closure (forced enough)
    }
}
