#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Ident(String),
    Int(i64),
    String(String),
    Bool(bool),
    Null,
    Path(String),
    List(Vec<Box<Expr>>),
    AttrSet(Vec<Binding>),
    LetIn(Vec<Binding>, Box<Expr>),
    IfThenElse(Box<Expr>, Box<Expr>, Box<Expr>),
    Lambda(String, Box<Expr>),
    Apply(Box<Expr>, Box<Expr>),
    BinOp(Box<Expr>, BinOp, Box<Expr>),
    Prefix(PrefixOp, Box<Expr>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Binding {
    pub name: String,
    pub value: Box<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Eq,
    Neq,
    And,
    Or,
    Update,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PrefixOp {
    Not,
    Neg,
}
