use crate::ast::{Binding, Entry, Expr, Pattern};
use derive_more::Display;
use rootcause::Report;
use winnow::prelude::*;
use winnow::{
    ascii::{digit1, multispace0},
    combinator::{alt, delimited, fail, peek, preceded, repeat},
    error::ContextError,
    token::{one_of, take_while},
};

#[derive(Debug, Display)]
pub enum ParseError {
    #[display("Invalid syntax at offset {_0}:\n{_1}")]
    SyntaxError(usize, String),
    #[display("Unexpected character: {_0}")]
    UnexpectedChar(char),
    #[display("Expected {_0}")]
    Expected(String),
}

impl std::error::Error for ParseError {}

impl From<String> for ParseError {
    fn from(s: String) -> Self {
        ParseError::SyntaxError(0, s)
    }
}

type PResult<'a, O> = winnow::Result<O, ContextError>;

pub fn parse(input: &str) -> Result<Expr<'_>, Report<ParseError>> {
    match expr.parse(input) {
        Ok(e) => Ok(e),
        Err(e) => {
            let offset = e.offset();
            // Calculate line and column
            let (line_num, col_num): (usize, usize) =
                input[..offset].chars().fold((1, 1), |(line, col), c| {
                    if c == '\n' {
                        (line + 1, 1)
                    } else {
                        (line, col + 1)
                    }
                });

            // Get the line content
            let lines: Vec<&str> = input.lines().collect();
            let line_content = if line_num <= lines.len() {
                lines[line_num - 1]
            } else {
                ""
            };

            // Format valid context
            let line_prefix = format!("{line_num} | ");
            let pointer_prefix = format!("{} | ", " ".repeat(format!("{line_num}").len()));
            let pad = " ".repeat(col_num.saturating_sub(1));
            let context = format!("{line_prefix}{line_content}\n{pointer_prefix}{pad}^");
            let msg = format!("{e}\n{context}");

            Err(Report::new(ParseError::SyntaxError(offset, msg)))
        }
    }
}

fn ws<'a, F, O>(inner: F) -> impl Parser<&'a str, O, ContextError>
where
    F: Parser<&'a str, O, ContextError>,
{
    delimited(multispace0, inner, multispace0)
}

fn expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    let _ = multispace0(input)?;
    alt((let_expr, if_expr, with_expr, assert_expr, lambda_or_app)).parse_next(input)
}

fn lambda_or_app<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    let start = term.parse_next(input)?;

    let check: Result<(&str, char), ContextError> = (multispace0, ':').parse_next(input);

    if check.is_ok() {
        match start {
            Expr::Ident(name) => {
                let body = expr.parse_next(input)?;
                return Ok(Expr::Lambda(Pattern::Ident(name), Box::new(body)));
            }
            _ => {
                return fail.parse_next(input);
            }
        }
    }

    let mut func = start;
    loop {
        let _ = multispace0(input)?;
        if input.is_empty() {
            break;
        }

        let c = input.chars().next().unwrap();
        if ")=];,".contains(c) {
            break;
        }

        if let Ok(arg) = term.parse_next(input) {
            func = Expr::App(Box::new(func), Box::new(arg));
        } else {
            break;
        }
    }

    Ok(func)
}

fn term<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    alt((
        parens, set_expr, list_expr, lit_bool, lit_null, lit_int, lit_string, ident_expr,
    ))
    .parse_next(input)
}

fn parens<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    delimited('(', ws(expr), ')').parse_next(input)
}

fn let_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    preceded(
        (ws("let"), multispace0),
        (repeat(0.., ws(binding)), (ws("in"), multispace0), expr),
    )
    .map(|(bindings, _, body)| Expr::Let(bindings, Box::new(body)))
    .parse_next(input)
}

fn binding<'a>(input: &mut &'a str) -> PResult<'a, Binding<'a>> {
    (
        ws(ident),
        (ws('='), multispace0),
        expr,
        (ws(';'), multispace0),
    )
        .map(|(name, _, val, _)| Binding {
            name: vec![name],
            value: val,
        })
        .parse_next(input)
}

fn if_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    (
        (ws("if"), multispace0),
        expr,
        (ws("then"), multispace0),
        expr,
        (ws("else"), multispace0),
        expr,
    )
        .map(|(_, cond, _, t, _, f)| Expr::If(Box::new(cond), Box::new(t), Box::new(f)))
        .parse_next(input)
}

fn with_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    (
        (ws("with"), multispace0),
        expr,
        (ws(';'), multispace0),
        expr,
    )
        .map(|(_, env, _, body)| Expr::With(Box::new(env), Box::new(body)))
        .parse_next(input)
}

fn assert_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    (
        (ws("assert"), multispace0),
        expr,
        (ws(';'), multispace0),
        expr,
    )
        .map(|(_, cond, _, body)| Expr::Assert(Box::new(cond), Box::new(body)))
        .parse_next(input)
}

fn ident_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    ident.map(Expr::Ident).parse_next(input)
}

fn ident<'a>(input: &mut &'a str) -> PResult<'a, &'a str> {
    // Check start char using peek
    let _ = peek(one_of(|c: char| c.is_alphabetic() || c == '_')).parse_next(input)?;

    // consume valid ident chars
    take_while(1.., |c: char| {
        c.is_alphanumeric() || c == '_' || c == '-' || c == '\''
    })
    .verify(|s: &str| !KEYWORDS.contains(&s))
    .parse_next(input)
}

const KEYWORDS: &[&str] = &[
    "if", "then", "else", "let", "in", "with", "assert", "rec", "inherit", "true", "false", "null",
];

fn lit_bool<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    alt(("true".value(Expr::True), "false".value(Expr::False))).parse_next(input)
}

fn lit_null<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    "null".value(Expr::Null).parse_next(input)
}

fn lit_int<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    digit1.try_map(str::parse).map(Expr::Int).parse_next(input)
}

fn lit_string<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    delimited('"', take_while(0.., |c| c != '"' && c != '\\'), '"')
        .map(|s: &str| Expr::String(s.into()))
        .parse_next(input)
}

fn list_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    delimited('[', repeat(0.., ws(term)), ']')
        .map(Expr::List)
        .parse_next(input)
}

fn set_expr<'a>(input: &mut &'a str) -> PResult<'a, Expr<'a>> {
    delimited('{', repeat(0.., ws(binding)), '}')
        .map(|bindings: Vec<Binding>| {
            let entries = bindings
                .into_iter()
                .map(|b| (Entry::Field(b.name, b.value), None))
                .collect();
            Expr::Set(entries)
        })
        .parse_next(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_literals() {
        assert_eq!(parse("true").unwrap(), Expr::True);
        assert_eq!(parse("false").unwrap(), Expr::False);
        assert_eq!(parse("null").unwrap(), Expr::Null);
        assert_eq!(parse("123").unwrap(), Expr::Int(123));
        assert_eq!(parse("\"hello\"").unwrap(), Expr::String("hello".into()));
    }

    #[test]
    fn test_parse_ident() {
        assert_eq!(parse("foo").unwrap(), Expr::Ident("foo"));
        assert_eq!(parse("foo-bar").unwrap(), Expr::Ident("foo-bar"));
        assert_eq!(parse("foo'").unwrap(), Expr::Ident("foo'"));
        assert_eq!(parse("_foo").unwrap(), Expr::Ident("_foo"));
    }

    #[test]
    fn test_parse_list() {
        let input = "[ 1 2 true \"hi\" ]";
        let expected = Expr::List(vec![
            Expr::Int(1),
            Expr::Int(2),
            Expr::True,
            Expr::String("hi".into()),
        ]);
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_set() {
        let input = "{ x = 1; y = true; }";
        let expected = Expr::Set(vec![
            (Entry::Field(vec!["x"], Expr::Int(1)), None),
            (Entry::Field(vec!["y"], Expr::True), None),
        ]);
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_app() {
        let input = "f x y";
        let expected = Expr::App(
            Box::new(Expr::App(
                Box::new(Expr::Ident("f")),
                Box::new(Expr::Ident("x")),
            )),
            Box::new(Expr::Ident("y")),
        );
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_lambda() {
        let input = "x: x";
        let expected = Expr::Lambda(Pattern::Ident("x"), Box::new(Expr::Ident("x")));
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_let() {
        let input = "let x = 1; y = 2; in x";
        let expected = Expr::Let(
            vec![
                Binding {
                    name: vec!["x"],
                    value: Expr::Int(1),
                },
                Binding {
                    name: vec!["y"],
                    value: Expr::Int(2),
                },
            ],
            Box::new(Expr::Ident("x")),
        );
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_if() {
        let input = "if true then 1 else 0";
        let expected = Expr::If(
            Box::new(Expr::True),
            Box::new(Expr::Int(1)),
            Box::new(Expr::Int(0)),
        );
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_with() {
        let input = "with x; y";
        let expected = Expr::With(Box::new(Expr::Ident("x")), Box::new(Expr::Ident("y")));
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_parse_assert() {
        let input = "assert true; x";
        let expected = Expr::Assert(Box::new(Expr::True), Box::new(Expr::Ident("x")));
        assert_eq!(parse(input).unwrap(), expected);
    }

    #[test]
    fn test_nested() {
        let input = "let f = x: x; in f 1";
        let expected = Expr::Let(
            vec![Binding {
                name: vec!["f"],
                value: Expr::Lambda(Pattern::Ident("x"), Box::new(Expr::Ident("x"))),
            }],
            Box::new(Expr::App(
                Box::new(Expr::Ident("f")),
                Box::new(Expr::Int(1)),
            )),
        );
        assert_eq!(parse(input).unwrap(), expected);
    }
}
