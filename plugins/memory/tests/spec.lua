local h = require("memory_helpers")

local fnv1a_64 = h.fnv1a_64
local project_id = h.project_id
local safe_resolve = h.safe_resolve
local normalize_tag = h.normalize_tag
local parse_frontmatter = h.parse_frontmatter
local extract_tags = h.extract_tags
local tags_for_file = h.tags_for_file
local format_tag_line = h.format_tag_line
local encode_frontmatter = h.encode_frontmatter
local format_list = h.format_list
local format_read = h.format_read
local validate_write_tags = h.validate_write_tags
local validate_input = h.validate_input

local failures = {}

local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    table.insert(failures, name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "") .. "\nexpected: " .. tostring(expected) .. "\n  actual: " .. tostring(actual))
  end
end

local _tmpdir_counter = 0
local function mktmpdir()
  _tmpdir_counter = _tmpdir_counter + 1
  local name = "/tmp/maki_spec_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. _tmpdir_counter
  maki.fs.mkdir(name)
  return name
end

local function rmtree(dir)
  local entries = maki.fs.dir(dir)
  if entries then
    for _, e in ipairs(entries) do
      local p = maki.fs.joinpath(dir, e[1])
      if e[2] == "directory" then
        rmtree(p)
      else
        maki.fs.rm(p)
      end
    end
  end
  maki.fs.rm(dir)
end

local function write_mem(dir, name, tags, body)
  local content = encode_frontmatter(tags) .. body
  maki.fs.write(maki.fs.joinpath(dir, name), content)
end

case("fnv1a_known_vectors", function()
  local vectors = {
    { "", "cbf29ce484222325" },
    { "a", "af63dc4c8601ec8c" },
    { "/home/user/my-project", "fc6e8b528feefa1c" },
  }
  for _, v in ipairs(vectors) do
    eq(fnv1a_64(v[1]), v[2], "input: " .. ("%q"):format(v[1]))
  end
end)

case("fnv1a_high_bytes_no_overflow", function()
  local result = fnv1a_64(string.rep("\xff", 64))
  eq(#result, 16, "should always produce 16 hex chars")
  assert(result:match("^%x+$"), "should be valid hex")
end)

case("safe_resolve_rejects_bad_paths", function()
  local bad = {
    { nil, "required" },
    { "", "required" },
    { "/etc/passwd", "must be relative" },
    { "bad\0path", "must be relative" },
    { "..", "traversal" },
    { "../escape", "traversal" },
    { "a/../../escape", "traversal" },
    { "inside/../../../etc/shadow", "traversal" },
    { "C:\\foo", "must be relative" },
    { "c:foo", "must be relative" },
    { "\\escape", "must be relative" },
  }
  for _, v in ipairs(bad) do
    local _, err = safe_resolve("/tmp/mem", v[1])
    assert(
      err and err:find(v[2]),
      "input " .. tostring(v[1]) .. " should match '" .. v[2] .. "', got: " .. tostring(err)
    )
  end
end)

case("safe_resolve_accepts_good_paths", function()
  local s = "[/\\\\]"
  local good = {
    { "notes.md", "notes%.md" },
    { "sub/deep/notes.md", "sub" .. s .. "deep" .. s .. "notes%.md" },
    { "./notes.md", "notes%.md" },
  }
  for _, v in ipairs(good) do
    local p, err = safe_resolve("/tmp/mem", v[1])
    assert(p, "input " .. v[1] .. " should be accepted, got error: " .. tostring(err))
    assert(p:find(v[2]), "result should match pattern '" .. v[2] .. "', got: " .. p)
  end
end)

case("project_id", function()
  local id = project_id("/home/user/my-project")
  assert(id:match("^my%-project%-%x+$"), "should be basename-hex, got: " .. id)
  eq(#id:match("%-(%x+)$"), 16, "hash should be 16 hex chars")

  local root_id = project_id("/")
  assert(root_id:match("^root%-"), "/ should use 'root' as basename")

  local id1 = project_id("/home/alice/myapp")
  local id2 = project_id("/home/bob/myapp")
  assert(id1 ~= id2, "different full paths should produce different IDs")
end)

case("format_list_empty_or_missing_returns_nil", function()
  local tmpdir = mktmpdir()
  eq(format_list(tmpdir), nil)
  eq(format_list("/tmp/maki_test_does_not_exist_" .. _tmpdir_counter), nil)
  rmtree(tmpdir)
end)

case("format_list_groups_by_tag_sorted_by_freq", function()
  local tmpdir = mktmpdir()
  write_mem(tmpdir, "a.md", { "rare" }, "A")
  write_mem(tmpdir, "b.md", { "common" }, "B")
  write_mem(tmpdir, "c.md", { "common" }, "C")
  write_mem(tmpdir, "d.md", { "common" }, "D")

  local result = format_list(tmpdir)
  local common_pos = result:find("common %(3%)")
  local rare_pos = result:find("rare %(1%)")
  assert(common_pos, "should show common with count 3")
  assert(rare_pos, "should show rare with count 1")
  assert(common_pos < rare_pos, "common (freq 3) before rare (freq 1)")
  assert(result:find("  %- b%.md %(%d+ bytes%)"), "should list files under tag")
  rmtree(tmpdir)
end)

case("format_list_includes_stem_pseudo_tag", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "notes.md"), "no tags")
  local result = format_list(tmpdir)
  assert(result:find("notes %(1%)"), "stem pseudo-tag should appear")
  assert(result:find("  %- notes%.md %(%d+ bytes%)"), "file should appear under stem tag")
  rmtree(tmpdir)
end)

case("format_list_no_tags_returns_full_grouped_index", function()
  local tmpdir = mktmpdir()
  write_mem(tmpdir, "a.md", { "auth" }, "A body")
  write_mem(tmpdir, "b.md", { "sessions" }, "B body")
  write_mem(tmpdir, "c.md", { "auth", "sessions" }, "C body")

  local result, err = format_list(tmpdir, nil)
  eq(err, nil)
  assert(result:find("auth %(2%)"), "auth group has count 2 (a, c)")
  assert(result:find("sessions %(2%)"), "sessions group has count 2 (b, c)")
  assert(not result:find("A body"), "no bodies in index")
  rmtree(tmpdir)
end)

case("format_list_with_tags_filters_to_matching_groups", function()
  local tmpdir = mktmpdir()
  write_mem(tmpdir, "a.md", { "auth" }, "A")
  write_mem(tmpdir, "b.md", { "sessions" }, "B")
  write_mem(tmpdir, "c.md", { "storage" }, "C")

  local result, err = format_list(tmpdir, { "auth", "sessions" })
  eq(err, nil)
  assert(result:find("a%.md"), "auth matches a")
  assert(result:find("b%.md"), "sessions matches b")
  assert(not result:find("c%.md"), "storage filtered out")
  rmtree(tmpdir)
end)

case("format_list_no_matches", function()
  local tmpdir = mktmpdir()
  write_mem(tmpdir, "a.md", { "auth" }, "A")
  eq(
    format_list(tmpdir, { "storage" }),
    "no memory files matched any of the given tags; use `list` to see available tags"
  )
  rmtree(tmpdir)
end)

case("format_list_all_invalid_tags_errors", function()
  local tmpdir = mktmpdir()
  local result, err = format_list(tmpdir, { "!!!", "", "  " })
  eq(result, nil)
  assert(err:find("no valid tags"), "should error on all-invalid tags")
  assert(err:find("rejected:"), "error should list rejected raw values")
  assert(err:find("!!!", 1, true), "error should include the raw rejected value")
  rmtree(tmpdir)
end)

case("format_list_warns_on_partial_invalid_tags", function()
  local tmpdir = mktmpdir()
  write_mem(tmpdir, "a.md", { "auth" }, "A")
  local result, err = format_list(tmpdir, { "auth", "bad!tag" })
  eq(err, nil)
  local wpos = result:find("warning: ignored invalid tag")
  local bpos = result:find("a%.md")
  assert(wpos, "should warn about rejected tags")
  assert(bpos, "should still match valid tag")
  assert(wpos < bpos, "warning should precede matched body")
  assert(result:find("bad!tag"), "warning should name the rejected tag")
  rmtree(tmpdir)
end)

case("format_list_matches_stem_pseudo_tag", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "notes.md"), "no frontmatter")
  local result, err = format_list(tmpdir, { "notes" })
  eq(err, nil)
  assert(result:find("notes %(1%)"), "stem pseudo-tag appears as a group")
  assert(result:find("notes%.md %(%d+ bytes%)"), "file lists under stem tag")
  rmtree(tmpdir)
end)

case("format_rejected_nil_for_empty", function()
  eq(h.format_rejected({}), nil)
  eq(h.format_rejected(nil), nil)
end)

case("format_rejected_lists_tags", function()
  local w = h.format_rejected({ "bad!tag", "" })
  assert(w:find("bad!tag"), "should include rejected tag names")
end)

case("format_rejected_truncates_long_input", function()
  local long = string.rep("x", 200)
  local w = h.format_rejected({ long })
  eq(#w, 64 + 3, "truncated to 64 chars plus ellipsis")
  eq(w:sub(-3), "...", "should end with ellipsis")
end)

case("normalize_tag_lowercases_and_snake_cases", function()
  eq(normalize_tag("Auth Flow"), "auth_flow")
  eq(normalize_tag("auth-flow"), "auth_flow")
  eq(normalize_tag("  AUTH_FLOW  "), "auth_flow")
  eq(normalize_tag("auth--flow"), "auth_flow", "collapse repeated separators")
  eq(normalize_tag("auth__flow"), "auth_flow", "collapse interior underscores")
  eq(normalize_tag(nil), nil, "nil input returns nil")
  eq(normalize_tag("   "), nil, "whitespace-only returns nil")
  eq(normalize_tag(""), nil, "empty returns nil")
  eq(normalize_tag("auth!flow"), nil, "punctuation rejected")
  eq(normalize_tag("a,b"), nil, "comma rejected")
end)

case("normalize_tag_rejects_oversized", function()
  local long = string.rep("a", 65)
  eq(normalize_tag(long), nil, "over 64 chars rejected")
  eq(normalize_tag(string.rep("a", 64)), string.rep("a", 64), "exactly 64 ok")
end)

case("normalize_tags_dedupes_ordered", function()
  local out, rejected = h.normalize_tags({ "Auth Flow", "auth_flow", "Sessions", "", "auth-flow" })
  eq(#out, 2)
  eq(out[1], "auth_flow")
  eq(out[2], "sessions")
  eq(#rejected, 1, "empty string rejected")
end)

case("normalize_tags_reports_rejected", function()
  local out, rejected = h.normalize_tags({ "valid", "bad!tag", "also-valid", "" })
  eq(#out, 2)
  eq(out[1], "valid")
  eq(out[2], "also_valid")
  eq(#rejected, 2)
  eq(rejected[1], "bad!tag")
  eq(rejected[2], "")
end)

case("normalize_tags_empty_input", function()
  eq(#h.normalize_tags({}), 0)
  eq(#h.normalize_tags({ "", "  ", "!" }), 0, "all-invalid drops to empty")
end)

case("validate_write_tags_accepts_valid", function()
  local tags, err = validate_write_tags({ "Auth Flow", "sessions" })
  eq(err, nil)
  eq(tags[1], "auth_flow")
  eq(tags[2], "sessions")
end)

case("validate_write_tags_accepts_empty", function()
  local tags, err = validate_write_tags({})
  eq(err, nil, "empty tag list is valid for write")
  eq(#tags, 0)
end)

case("validate_write_tags_errors_on_any_rejected", function()
  local ERR_PREFIX = "invalid tag(s) rejected: "
  local tags, err = validate_write_tags({ "good", "bad!tag", "also-bad!" })
  eq(tags, nil, "returns no tags when any rejected")
  eq(err:sub(1, #ERR_PREFIX), ERR_PREFIX, "uses the write-reject prefix")
  assert(err:find("bad!tag", 1, true), "includes first rejected tag")
  assert(err:find("also-bad!", 1, true), "includes second rejected tag")
  assert(not err:find("good", 1, true), "does not include valid tag")
end)

case("parse_frontmatter_extracts_tags_and_body", function()
  local input = "---\ntags:\n  - auth\n  - sessions\n---\n# Body\nText"
  local fm, body = parse_frontmatter(input)
  eq(type(fm.tags), "table")
  eq(fm.tags[1], "auth")
  eq(fm.tags[2], "sessions")
  eq(body, "# Body\nText")
end)

case("parse_frontmatter_no_frontmatter_returns_content", function()
  local fm, body = parse_frontmatter("Just content")
  eq(next(fm), nil, "frontmatter empty")
  eq(body, "Just content")
end)

case("parse_frontmatter_empty_tags_list", function()
  local input = "---\ntags: []\n---\nbody text"
  local fm, body = parse_frontmatter(input)
  eq(body, "body text")
  local tags = extract_tags(fm)
  eq(tags, nil, "empty tags list extracts to nil -> stem fallback")
end)

case("parse_frontmatter_malformed_yaml_falls_back", function()
  local input = "---\ntags: [unterminated\n---\nbody"
  local fm, body = parse_frontmatter(input)
  eq(body, "body", "body still extracted when YAML decode fails")
  eq(extract_tags(fm), nil, "malformed frontmatter yields no tags")
end)

case("parse_frontmatter_body_with_horizontal_rule_preserved", function()
  local input = "---\ntags:\n  - a\n---\npara1\n---\npara2"
  local fm, body = parse_frontmatter(input)
  eq(body, "para1\n---\npara2", "mid-body thematic rule is not mistaken for a fence")
  eq(fm.tags[1], "a")
end)

case("parse_frontmatter_adjacent_fences_treated_as_no_frontmatter", function()
  local input = "---\n---\nbody"
  local fm, body = parse_frontmatter(input)
  eq(body, input, "leading adjacent fences fall back to whole-content body")
  eq(next(fm), nil, "no frontmatter parsed")
end)

case("parse_frontmatter_no_closing_fence_returns_content", function()
  local input = "---\ntags:\n  - a\nbody without close"
  local fm, body = parse_frontmatter(input)
  eq(body, input, "unclosed frontmatter falls back to whole content")
  eq(next(fm), nil)
end)

case("extract_tags_normalizes_and_dedupes", function()
  local tags = extract_tags({ tags = { "Auth Flow", "auth_flow", "Sessions", "" } })
  eq(#tags, 2, "auth_flow variants dedupe to one, empty dropped")
  eq(tags[1], "auth_flow")
  eq(tags[2], "sessions")
end)

case("extract_tags_string_coerces_to_list", function()
  local tags = extract_tags({ tags = "single_tag" })
  eq(#tags, 1)
  eq(tags[1], "single_tag")
end)

case("extract_tags_absent_returns_nil", function()
  eq(extract_tags({}), nil)
  eq(extract_tags(nil), nil)
  eq(extract_tags({ tags = 42 }), nil, "non-table/string ignored")
end)

case("tags_for_file_uses_frontmatter", function()
  local content = "---\ntags:\n  - architecture\n  - rust\n---\nMicroservices"
  local tags = tags_for_file("arch.md", content)
  eq(#tags, 2)
  eq(tags[1], "architecture")
  eq(tags[2], "rust")
end)

case("tags_for_file_falls_back_to_stem", function()
  local tags = tags_for_file("architecture.md", "no frontmatter here")
  eq(#tags, 1)
  eq(tags[1], "architecture", "stem without extension as pseudo-tag")
end)

case("tags_for_file_multi_dot_stem_normalizes", function()
  local tags = tags_for_file("config.local.md", "no tags")
  eq(#tags, 1)
  eq(tags[1], "config_local", "dotless stem with dots collapsed to underscore")
end)

case("tags_for_file_dotfile_falls_back_to_basename", function()
  local tags = tags_for_file(".bashrc", "no tags")
  eq(#tags, 1)
  eq(tags[1], "bashrc", "dotfile uses basename, leading dot dropped")
end)

case("tags_for_file_all_symbols_uses_untagged", function()
  local tags = tags_for_file("...md", "no tags")
  eq(#tags, 1)
  eq(tags[1], "untagged", "stem with no alphanumerics falls back to untagged")
end)

case("tags_for_file_empty_frontmatter_uses_stem", function()
  local content = "---\ntags: []\n---\nbody"
  local tags = tags_for_file("notes.md", content)
  eq(#tags, 1)
  eq(tags[1], "notes")
end)

case("tags_for_file_nil_content_uses_stem", function()
  local tags, err = tags_for_file("deep/nested/Notes.md", nil)
  eq(#tags, 1)
  eq(tags[1], "notes", "basename stem, lowercased")
  eq(err, "read error", "nil content propagates read error")
end)

case("tags_for_file_passes_explicit_read_err", function()
  local tags, err = tags_for_file("deep/nested/Notes.md", nil, "disk error")
  eq(#tags, 1)
  eq(tags[1], "notes", "stem fallback")
  eq(err, "disk error", "explicit read_err propagates to second return")
end)

case("format_tag_line_empty_dir_returns_nil", function()
  local tmpdir = mktmpdir()
  eq(format_tag_line(tmpdir, 50), nil)
  rmtree(tmpdir)
end)

case("format_tag_line_sorted_by_freq_then_name", function()
  local tmpdir = mktmpdir()
  local rev = tmpdir

  maki.fs.write(maki.fs.joinpath(rev, "a.md"), "---\ntags:\n  - rare\n---\nA")
  maki.fs.write(maki.fs.joinpath(rev, "b.md"), "---\ntags:\n  - common\n---\nB")
  maki.fs.write(maki.fs.joinpath(rev, "c.md"), "---\ntags:\n  - common\n---\nC")
  maki.fs.write(maki.fs.joinpath(rev, "d.md"), "---\ntags:\n  - common\n---\nD")
  maki.fs.write(maki.fs.joinpath(rev, "untagged.md"), "no tags")

  local line = format_tag_line(tmpdir, 50)
  local common_pos = line:find("common", 1, true)
  local rare_pos = line:find("rare", 1, true)
  local untagged_pos = line:find("untagged", 1, true)
  assert(common_pos, "common should appear")
  assert(rare_pos, "rare should appear")
  assert(untagged_pos, "untagged stem pseudo-tag should appear")
  assert(common_pos < rare_pos, "common (freq 3) before rare (freq 1)")
  rmtree(tmpdir)
end)

case("format_tag_line_truncates_above_cap", function()
  local tmpdir = mktmpdir()
  for i = 1, 5 do
    maki.fs.write(maki.fs.joinpath(tmpdir, "f" .. i .. ".md"), "---\ntags:\n  - tag" .. i .. "\n---\n" .. tostring(i))
  end

  local line = format_tag_line(tmpdir, 3)
  assert(line:find("use `list` to see all"), "should include new truncation hint")
  assert(line:find("2 tags omitted"), "should report omitted count")
  assert(line:find("%.%.%."), "should contain ellipsis")
  assert(line:find("^tag1, tag2, tag3 "), "first three tags shown in order before ellipsis")
  rmtree(tmpdir)
end)

case("encode_frontmatter_empty_tags", function()
  local fm = encode_frontmatter({})
  assert(fm:find("^%-%-%-\n"), "starts with frontmatter fence")
  assert(fm:find("\n%-%-%-\n$"), "ends with fence and newline")
  local parsed = extract_tags(parse_frontmatter(fm))
  eq(parsed, nil, "empty frontmatter tags round-trip to nil (stem fallback)")
end)

case("encode_frontmatter_with_tags", function()
  local fm = encode_frontmatter({ "auth", "sessions" })
  assert(fm:find("auth"), "contains auth tag")
  assert(fm:find("sessions"), "contains sessions tag")
  assert(fm:find("^%-%-%-\n"), "starts with fence")
  assert(fm:find("\n%-%-%-\n$"), "ends with fence and newline")
end)

case("format_read_union_match_single_tag", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - auth\n---\nA body")
  maki.fs.write(maki.fs.joinpath(tmpdir, "b.md"), "---\ntags:\n  - sessions\n---\nB body")
  maki.fs.write(maki.fs.joinpath(tmpdir, "c.md"), "---\ntags:\n  - auth\n  - sessions\n---\nC body")

  local result, err = format_read(tmpdir, { "auth" })
  eq(err, nil)
  assert(result:find("a%.md %(%d+ bytes%) %[auth%]"), "a matches auth, shows its tags")
  assert(not result:find("b%.md"), "b does not match auth")
  assert(result:find("c%.md %(%d+ bytes%) %[auth, sessions%]"), "c matches auth, shows all tags")
  assert(result:find("A body"), "a body included")
  assert(not result:find("^%-%-%-"), "frontmatter stripped")
  rmtree(tmpdir)
end)

case("format_read_union_match_multi_tags", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - auth\n---\nA")
  maki.fs.write(maki.fs.joinpath(tmpdir, "b.md"), "---\ntags:\n  - sessions\n---\nB")
  maki.fs.write(maki.fs.joinpath(tmpdir, "c.md"), "---\ntags:\n  - storage\n---\nC")

  local result = format_read(tmpdir, { "auth", "sessions" })
  assert(result:find("a%.md %(%d+ bytes%)"), "auth matches a")
  assert(result:find("b%.md %(%d+ bytes%)"), "sessions matches b")
  assert(not result:find("c%.md"), "storage does not match")
  rmtree(tmpdir)
end)

case("format_read_normalizes_request_tags", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - auth_flow\n---\nA")
  local result = format_read(tmpdir, { "Auth-Flow", "AUTH FLOW" })
  assert(result:find("a%.md"), "normalized request matches")
  rmtree(tmpdir)
end)

case("format_read_matches_stem_pseudo_tag", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "notes.md"), "no frontmatter")
  local result = format_read(tmpdir, { "notes" })
  assert(result:find("notes%.md"), "stem pseudo-tag matches")
  assert(result:find("no frontmatter"), "body returned without frontmatter")
  rmtree(tmpdir)
end)

case("format_read_no_matches", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - auth\n---\nA")
  eq(
    format_read(tmpdir, { "storage" }),
    "no memory files matched any of the given tags; use `list` to see available tags"
  )
  rmtree(tmpdir)
end)

case("format_read_warns_on_partial_invalid_tags", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - auth\n---\nA")
  local result, err = format_read(tmpdir, { "auth", "bad!tag" })
  eq(err, nil)
  local wpos = result:find("warning: ignored invalid tag")
  local bpos = result:find("a%.md %(%d+ bytes%)")
  assert(wpos, "should warn about rejected tags")
  assert(bpos, "should still match valid tag")
  assert(wpos < bpos, "warning should precede matched body")
  rmtree(tmpdir)
end)

case("format_read_all_invalid_tags_errors", function()
  local tmpdir = mktmpdir()
  local result, err = format_read(tmpdir, { "!!!", "", "  " })
  eq(result, nil)
  assert(err:find("no valid tags"), "should error on all-invalid tags")
  assert(err:find("rejected:"), "error should list rejected raw values")
  assert(err:find("!!!", 1, true), "error should include the raw rejected value")
  rmtree(tmpdir)
end)

case("format_read_strips_frontmatter", function()
  local tmpdir = mktmpdir()
  maki.fs.write(maki.fs.joinpath(tmpdir, "a.md"), "---\ntags:\n  - x\n---\n# Title\nBody")
  local result = format_read(tmpdir, { "x" })
  assert(not result:find("tags:"), "frontmatter tags stripped from body")
  assert(result:find("# Title"), "body preserved")
  assert(result:find("%[x%]"), "tag shown in header")
  rmtree(tmpdir)
end)

case("format_read_entry_single_file_with_tags", function()
  local content = "---\ntags:\n  - auth\n  - sessions\n---\n# Body\ntext"
  local formatted = h.format_read_entry("arch.md", 42, content)
  assert(formatted:find("^arch%.md %(42 bytes%) %[auth, sessions%]"), "header with tags and size")
  assert(formatted:find("\n# Body\ntext$"), "body follows header")
  assert(not formatted:find("%-%-%-"), "no frontmatter fences in output")
end)

case("format_read_entry_untagged_no_brackets", function()
  local formatted = h.format_read_entry("notes.md", 12, "just a body")
  eq(formatted, "notes.md (12 bytes)\n\njust a body", "header without brackets then body, frontmatter stripped")
  assert(not formatted:find("%["), "no tag brackets when untagged")
end)

case("validate_input_unknown_command", function()
  local err = validate_input({ command = "find" })
  assert(err:find("unknown command"), "rejects unknown command, got: " .. tostring(err))
  assert(err:find("find", 1, true), "error names the bad command")
end)

case("validate_input_read_path_or_tags_required", function()
  local err = validate_input({ command = "read" })
  assert(err:find("path.*or.*tags"), "read with neither errors, got: " .. tostring(err))
end)

case("validate_input_read_path_and_tags_mutually_exclusive", function()
  local err = validate_input({ command = "read", path = "a.md", tags = { "auth" } })
  assert(err:find("not both"), "read with both errors, got: " .. tostring(err))
end)

case("validate_input_read_tags_alone_ok", function()
  eq(validate_input({ command = "read", tags = { "auth" } }), nil)
end)

case("validate_input_read_path_alone_ok", function()
  eq(validate_input({ command = "read", path = "a.md" }), nil)
end)

case("validate_input_write_requires_path_content_tags", function()
  assert(validate_input({ command = "write" }):find("path"), "write without path errors")
  assert(validate_input({ command = "write", path = "a.md" }):find("content"), "write without content errors")
  assert(validate_input({ command = "write", path = "a.md", content = "x" }):find("tags"), "write without tags errors")
  eq(validate_input({ command = "write", path = "a.md", content = "x", tags = {} }), nil, "empty tags ok")
end)

case("validate_input_delete_requires_path", function()
  assert(validate_input({ command = "delete" }):find("path"), "delete without path errors")
  eq(validate_input({ command = "delete", path = "a.md" }), nil)
end)

case("validate_input_list_no_args_ok", function()
  eq(validate_input({ command = "list" }), nil)
end)

case("validate_input_scalar_tags_rejected", function()
  local err = validate_input({ command = "read", tags = "auth" })
  assert(err:find("must be an array"), "scalar tags rejected, got: " .. tostring(err))
end)

case("write_read_delete_lifecycle", function()
  local tmpdir = mktmpdir()
  assert(not maki.fs.metadata(maki.fs.joinpath(tmpdir, "nope.md")), "metadata should be nil for nonexistent")

  local file_path = safe_resolve(tmpdir, "arch.md")
  maki.fs.write(file_path, "# Architecture\nMicroservices")
  eq(maki.fs.read(file_path), "# Architecture\nMicroservices")

  maki.fs.write(file_path, "v2")
  eq(maki.fs.read(file_path), "v2")

  maki.fs.rm(file_path)
  assert(not maki.fs.metadata(file_path), "file should be deleted")
  rmtree(tmpdir)
end)

if #failures > 0 then
  error(#failures .. " case(s) failed:\n\n" .. table.concat(failures, "\n\n"))
end
