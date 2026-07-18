//! Fuzzy subsequence matching, backed by `nucleo-matcher`.
//! Returns 1-based codepoint positions for highlighting matched characters.

use maki_lua_macro::{lua_fn, lua_table};
use mlua::{Lua, Result as LuaResult, Table};

use nucleo_matcher::pattern::{Atom, AtomKind, CaseMatching, Normalization};
use nucleo_matcher::{Config, Matcher, Utf32Str};

/// Fuzzy-match {query} against each string in {strings}. Returns a list of
/// matches in input order. Each match is a table with `index` (1-based into
/// {strings}), `score` (u16, higher is better), and `positions` (1-based
/// codepoint offsets for highlighting). Empty {query} matches every string
/// with empty `positions`; empty strings never match.
///
/// @param query string Subsequence to search for. Smart case.
/// @param strings string[] Candidate strings.
/// @return (table) List of match tables.
/// @example
/// local m = maki.fuzzy.match("abc", {"axbyc", "xyz"})
/// -- m[1].index == 1, m[1].positions == {1, 3, 5}
#[lua_fn]
fn r#match(lua: &Lua, query: String, strings: Vec<String>) -> LuaResult<Table> {
    let out = lua.create_table()?;
    let push_match = |out: &Table, i: usize, score: u16, positions: &[u32]| -> LuaResult<()> {
        let m = lua.create_table()?;
        m.set("index", i + 1)?;
        m.set("score", score)?;
        let pos = lua.create_table()?;
        for &p in positions {
            pos.push(p as i64 + 1)?;
        }
        m.set("positions", pos)?;
        out.push(m)
    };

    if query.is_empty() {
        for (i, _) in strings.iter().enumerate() {
            push_match(&out, i, 0, &[])?;
        }
        return Ok(out);
    }

    let atom = Atom::new(
        &query,
        CaseMatching::Smart,
        Normalization::Smart,
        AtomKind::Fuzzy,
        false,
    );
    let mut matcher = Matcher::new(Config::DEFAULT);
    let mut buf = Vec::new();
    let mut indices = Vec::new();

    for (i, text) in strings.iter().enumerate() {
        if text.is_empty() {
            continue;
        }
        buf.clear();
        indices.clear();
        let haystack = Utf32Str::new(text, &mut buf);
        if let Some(score) = atom.indices(haystack, &mut matcher, &mut indices) {
            push_match(&out, i, score, &indices)?;
        }
    }
    Ok(out)
}

lua_table! {
    /// Fuzzy matching utilities.
    ///
    /// ```lua
    /// local m = maki.fuzzy.match("abc", {"axbyc", "xyz"})
    /// ```
    "maki.fuzzy" => pub(crate) fn create_fuzzy_table(), DOCS [
        r#match,
    ]
}

#[cfg(test)]
mod tests {
    use mlua::Lua;

    fn lua_with_fuzzy() -> Lua {
        let lua = Lua::new();
        let fuzzy = super::create_fuzzy_table(&lua).unwrap();
        lua.globals().set("fuzzy", fuzzy).unwrap();
        lua
    }

    #[test]
    fn matches_subsequence() {
        let lua = lua_with_fuzzy();
        let count: i64 = lua
            .load(r#"return #fuzzy.match("abc", {"axbyc", "xyz"})"#)
            .eval()
            .unwrap();
        assert_eq!(count, 1, "only axbyc should match abc");
    }

    #[test]
    fn returns_one_based_index() {
        let lua = lua_with_fuzzy();
        let idx: i64 = lua
            .load(r#"local m = fuzzy.match("b", {"a", "b", "c"}); return m[1].index"#)
            .eval()
            .unwrap();
        assert_eq!(idx, 2, "b is at 1-based index 2");
    }

    #[test]
    fn positions_are_one_based_and_char_offsets() {
        let lua = lua_with_fuzzy();
        let positions: Vec<i64> = lua
            .load(r#"local m = fuzzy.match("ac", {"axc"}); return m[1].positions"#)
            .eval()
            .unwrap();
        assert_eq!(positions, vec![1, 3], "a at pos 1, c at pos 3 in 'axc'");
    }

    #[test]
    fn empty_query_matches_all_with_no_positions() {
        let lua = lua_with_fuzzy();
        let (count, pos_count): (i64, i64) = lua
            .load(r#"local m = fuzzy.match("", {"a", "bb"}); return #m, #m[1].positions"#)
            .eval()
            .unwrap();
        assert_eq!(count, 2, "empty query matches all");
        assert_eq!(pos_count, 0, "no highlight positions for empty query");
    }

    #[test]
    fn empty_strings_skipped() {
        let lua = lua_with_fuzzy();
        let count: i64 = lua
            .load(r#"return #fuzzy.match("x", {"", "x", ""})"#)
            .eval()
            .unwrap();
        assert_eq!(count, 1, "empty strings never match");
    }

    #[test]
    fn no_matches_returns_empty_table() {
        let lua = lua_with_fuzzy();
        let count: i64 = lua
            .load(r#"return #fuzzy.match("zzz", {"abc", "def"})"#)
            .eval()
            .unwrap();
        assert_eq!(count, 0, "no matches");
    }

    #[test]
    fn empty_input_returns_empty() {
        let lua = lua_with_fuzzy();
        let count: i64 = lua.load(r#"return #fuzzy.match("x", {})"#).eval().unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn smart_case_matches_lowercase_query_in_mixed_case() {
        let lua = lua_with_fuzzy();
        let count: i64 = lua
            .load(r#"return #fuzzy.match("abc", {"AxBxC"})"#)
            .eval()
            .unwrap();
        assert_eq!(
            count, 1,
            "smart-case should match lowercase query in mixed case"
        );
    }
}
