use std::fmt;

pub struct Tracker<T> {
    root: T,
}

pub enum Kind {
    Local,
    Github,
}

pub trait Fetch {
    fn fetch(&self, r: &str) -> String;
}

impl<T: fmt::Display> Fetch for Tracker<T> {
    fn fetch(&self, r: &str) -> String {
        format!("{}/{}", self.root, r)
    }
}

impl Kind {
    pub fn name(&self) -> &'static str {
        "local"
    }

    pub(crate) async fn load(&self) {}
}

mod tests {}

pub fn parse(text: &str) -> &str {
    text.trim()
}
