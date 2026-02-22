use derive_more::Display;
// src/lexer.rs
use logos::Logos;

#[derive(Logos, Debug, Clone, PartialEq, Display)]
#[logos(skip r"[ \t\n\f\r]+")] // Skip whitespace
#[logos(skip(r"#[^\n]*", allow_greedy = true))]
#[logos(skip r"/\*([^*]|\*+[^*/])*\*+/")] // Skip multi-line comments
pub enum Token {
    #[token("let")]
    Let,
    #[token("in")]
    In,
    #[token("if")]
    If,
    #[token("then")]
    Then,
    #[token("else")]
    Else,
    #[token("true")]
    True,
    #[token("false")]
    False,
    #[token("null")]
    Null,

    // Identifiers (e.g., myVar, my-var)
    #[regex(r"[a-zA-Z_][a-zA-Z0-9_'\-]*", |lex| lex.slice().to_string())]
    Ident(String),

    // Integers
    #[regex(r"[0-9]+", |lex| lex.slice().parse::<i64>().unwrap())]
    Int(i64),

    // FIX 2: Nix paths. We enforce that the character immediately after
    // the first slash is a valid path character, but NOT a slash.
    // This perfectly prevents the `//` (Update) overlap.
    #[regex(r"[a-zA-Z0-9._\-+~]*/[a-zA-Z0-9._\-+~][a-zA-Z0-9._\-+~/]*", |lex| lex.slice().to_string())]
    Path(String),

    // Strings (Simplified: no interpolation support in this example)
    #[regex(r#""([^"\\]|\\.)*""#, |lex| lex.slice().to_string())]
    Str(String),

    #[token("{")]
    LBrace,
    #[token("}")]
    RBrace,
    #[token("[")]
    LBracket,
    #[token("]")]
    RBracket,
    #[token("(")]
    LParen,
    #[token(")")]
    RParen,
    #[token(";")]
    Semi,
    #[token(":")]
    Colon,
    #[token(".")]
    Dot,
    #[token("=")]
    Assign,

    #[token("==")]
    Eq,
    #[token("!=")]
    Neq,
    #[token("&&")]
    And,
    #[token("||")]
    Or,
    #[token("!")]
    Not,
    #[token("+")]
    Plus,
    #[token("-")]
    Minus,
    #[token("*")]
    Star,
    #[token("/")]
    Slash,
    #[token("//")]
    Update,
}

// Format required by LALRPOP
pub type Spanned<Tok, Loc, Error> = Result<(Loc, Tok, Loc), Error>;

pub struct Lexer<'input> {
    lexer: logos::Lexer<'input, Token>,
}

impl<'input> Lexer<'input> {
    pub fn new(text: &'input str) -> Self {
        Lexer {
            lexer: Token::lexer(text),
        }
    }
}

impl<'input> Iterator for Lexer<'input> {
    type Item = Spanned<Token, usize, String>;

    fn next(&mut self) -> Option<Self::Item> {
        self.lexer.next().map(|result| {
            let span = self.lexer.span();
            match result {
                Ok(token) => Ok((span.start, token, span.end)),
                Err(_) => Err(format!("Lexical error at {}..{}", span.start, span.end)),
            }
        })
    }
}
