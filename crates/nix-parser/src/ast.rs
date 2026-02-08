use derive_more::Display;

#[derive(Debug, Clone, PartialEq, Display)]
pub enum Expr<'a> {
    #[display("true")]
    True,
    #[display("false")]
    False,
    #[display("null")]
    Null,
    #[display("{}", _0)]
    Int(i64),
    #[display("{}", _0)]
    Float(f64),
    #[display("{:?}", _0)]
    String(Box<str>),
    #[display("{}", _0)]
    Ident(&'a str),
    #[display("{}", _0)]
    Path(&'a str),
    #[display("[{:?}]", _0)]
    List(Vec<Expr<'a>>),
    #[display("{:?}", _0)]
    Set(Vec<(Entry<'a>, Option<Expr<'a>>)>), // Not implementing rec for now simplicity
    #[display("let {:?} in {}", _0, _1)]
    Let(Vec<Binding<'a>>, Box<Expr<'a>>),
    #[display("with {}; {}", _0, _1)]
    With(Box<Expr<'a>>, Box<Expr<'a>>),
    #[display("if {} then {} else {}", _0, _1, _2)]
    If(Box<Expr<'a>>, Box<Expr<'a>>, Box<Expr<'a>>),
    #[display("assert {}; {}", _0, _1)]
    Assert(Box<Expr<'a>>, Box<Expr<'a>>),
    #[display("{} {}", _0, _1)]
    App(Box<Expr<'a>>, Box<Expr<'a>>),
    #[display("{}: {}", _0, _1)] // Simplified lambda display
    Lambda(Pattern<'a>, Box<Expr<'a>>),
    #[display("({} {} {})", _1, _0, _2)]
    BinOp(BinOp, Box<Expr<'a>>, Box<Expr<'a>>),
    #[display("({} {})", _0, _1)]
    UnaryOp(UnaryOp, Box<Expr<'a>>),
    #[display("{} or {}", _0, _1)]
    Select(Box<Expr<'a>>, Box<Expr<'a>>, Option<Box<Expr<'a>>>),
}

#[derive(Debug, Clone, PartialEq, Display)]
pub enum Entry<'a> {
    #[display("inherit {:?}", _0)]
    Inherit(Vec<&'a str>),
    #[display("{:?} = {}", _0, _1)]
    Field(AttrPath<'a>, Expr<'a>),
}

#[derive(Debug, Clone, PartialEq, Display)]
#[display("{:?} = {};", name, value)]
pub struct Binding<'a> {
    pub name: AttrPath<'a>,
    pub value: Expr<'a>,
}

pub type AttrPath<'a> = Vec<&'a str>;

#[derive(Debug, Clone, PartialEq, Display)]
pub enum Pattern<'a> {
    #[display("{}", _0)]
    Ident(&'a str),
    #[display("{{ {:?} }}", _0)]
    Set(Vec<PatEntry<'a>>),
}

#[derive(Debug, Clone, PartialEq, Display)]
#[display("{}", name)]
pub struct PatEntry<'a> {
    pub name: &'a str,
    pub default: Option<Expr<'a>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum BinOp {
    #[display("+")]
    Add,
    #[display("-")]
    Sub,
    #[display("*")]
    Mul,
    #[display("/")]
    Div,
    #[display("==")]
    Eq,
    #[display("!=")]
    Neq,
    #[display("<")]
    Lt,
    #[display(">")]
    Gt,
    #[display("<=")]
    Le,
    #[display(">=")]
    Ge,
    #[display("&&")]
    And,
    #[display("||")]
    Or,
    #[display("->")]
    Impl,
    #[display("//")]
    Update,
    #[display("++")]
    Concat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum UnaryOp {
    #[display("!")]
    Not,
    #[display("-")]
    Neg,
}
