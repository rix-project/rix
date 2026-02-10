use crate::{Value, eval};
use nix_parser::parse;
use std::collections::HashMap;

fn run(input: &str) -> Value<'_> {
    let expr = parse(input).expect("Parse error");
    eval(expr, HashMap::new()).expect("Eval error")
}

#[test]
fn test_eval_literals() {
    assert_eq!(run("true"), Value::True);
    assert_eq!(run("false"), Value::False);
    assert_eq!(run("null"), Value::Null);
    assert_eq!(run("123"), Value::Int(123));
    assert_eq!(run("\"hello\""), Value::String("hello".into()));
}

#[test]
fn test_eval_list() {
    let v = run("[ 1 2 ]");
    match v {
        Value::List(l) => {
            assert_eq!(l.len(), 2);
            assert_eq!(l[0].force().unwrap(), Value::Int(1));
            assert_eq!(l[1].force().unwrap(), Value::Int(2));
        }
        _ => panic!("Expected list"),
    }
}

#[test]
fn test_eval_set() {
    let v = run("{ x = 1; }");
    match v {
        Value::Set(s) => {
            assert_eq!(s.get("x").unwrap().force().unwrap(), Value::Int(1));
        }
        _ => panic!("Expected set"),
    }
}

#[test]
fn test_eval_let() {
    assert_eq!(run("let x = 1; in x"), Value::Int(1));
    // Simple shadowing (sequential)
    assert_eq!(run("let x = 1; y = x; in y"), Value::Int(1));
}

#[test]
fn test_eval_if() {
    assert_eq!(run("if true then 1 else 2"), Value::Int(1));
    assert_eq!(run("if false then 1 else 2"), Value::Int(2));
}

#[test]
fn test_eval_app() {
    assert_eq!(run("(x: x) 1"), Value::Int(1));
    assert_eq!(run("(x: y: x) 1 2"), Value::Int(1));
    assert_eq!(run("(x: y: y) 1 2"), Value::Int(2));
}

#[test]
fn test_eval_with() {
    assert_eq!(run("with { x = 1; }; x"), Value::Int(1));
}

#[test]
fn test_eval_assert() {
    assert_eq!(run("assert true; 1"), Value::Int(1));
}

// Test laziness
#[test]
fn test_lazy() {
    // If we force this, it would fail (assert false)
    // [ (assert false; 1) ]
    // The list is evaluated to a List of Thunks.
    // We do NOT force the element.
    let v = run("[ (assert false; 1) ]");
    if let Value::List(l) = v {
        assert_eq!(l.len(), 1);
        // Should not panic yet.
    } else {
        panic!("Expected list");
    }
}
