local M = {}

M.MAX_TAGS = 50

-- Lua's bit32 is 32-bit only, so we split the 64-bit FNV-1a state into
-- hi/lo halves and propagate carries by hand during multiplication.
function M.fnv1a_64(data)
  local lo = 0x84222325
  local hi = 0xcbf29ce4
  local p_lo = 0x000001b3
  local p_hi = 0x00000100
  for i = 1, #data do
    lo = bit32.bxor(lo, string.byte(data, i))
    local ll = lo * p_lo
    local ll_lo = ll % 0x100000000
    local ll_hi = (ll - ll_lo) / 0x100000000
    local new_hi = (hi * p_lo + lo * p_hi + ll_hi) % 0x100000000
    lo = ll_lo
    hi = new_hi
  end
  return string.format("%08x%08x", hi, lo)
end

function M.project_id(path)
  local base = maki.fs.basename(path) or "root"
  return base .. "-" .. M.fnv1a_64(path)
end

function M.safe_resolve(memories_dir, relative)
  if not relative or relative == "" then
    return nil, "path is required"
  end
  local first = relative:sub(1, 1)
  if relative:find("\0") or first == "/" or first == "\\" or relative:match("^%a:") then
    return nil, "path must be relative"
  end
  local resolved = maki.fs.normalize(maki.fs.joinpath(memories_dir, relative))
  local norm_base = maki.fs.normalize(memories_dir)
  local sep = norm_base:find("\\") and "\\" or "/"
  local prefix = norm_base .. sep
  if resolved:sub(1, #prefix) ~= prefix then
    return nil, "path traversal outside memories directory is not allowed"
  end
  return resolved
end

function M.collect_file_entries(dir)
  local entries = maki.fs.dir(dir)
  if not entries then
    return {}
  end
  local files = {}
  for _, entry in ipairs(entries) do
    if entry[2] == "file" then
      local meta = maki.fs.metadata(maki.fs.joinpath(dir, entry[1]))
      if meta then
        files[#files + 1] = { entry[1], meta.size }
      end
    end
  end
  return files
end

local MAX_TAG_LEN = 64

local function stem_tag(path)
  local base = maki.fs.basename(path) or path
  local stem = base:gsub("%.[^.]*$", "")
  if stem == "" then
    stem = base
  end
  local tag = stem:lower():gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if tag == "" then
    return "untagged"
  end
  if #tag > MAX_TAG_LEN then
    tag = tag:sub(1, MAX_TAG_LEN)
  end
  return tag
end

function M.normalize_tag(raw)
  if raw == nil then
    return nil
  end
  local s = tostring(raw):lower()
  s = s:gsub("[%s-]+", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  if s == "" or #s > MAX_TAG_LEN or s:match("[^%a%d_]") then
    return nil
  end
  return s
end

function M.normalize_tags(list)
  local seen, out, rejected = {}, {}, {}
  for _, t in ipairs(list) do
    local n = M.normalize_tag(t)
    if n then
      if not seen[n] then
        seen[n] = true
        out[#out + 1] = n
      end
    else
      rejected[#rejected + 1] = tostring(t)
    end
  end
  return out, rejected
end

function M.format_rejected(rejected)
  if not rejected or #rejected == 0 then
    return nil
  end
  local MAX_REJECT_DISPLAY = 64
  local out = {}
  for i, v in ipairs(rejected) do
    out[i] = #v > MAX_REJECT_DISPLAY and v:sub(1, MAX_REJECT_DISPLAY) .. "..." or v
  end
  return table.concat(out, ", ")
end

local WRITE_REJECT_PREFIX = "invalid tag(s) rejected: "
local READ_REJECT_PREFIX = "warning: ignored invalid tag(s): "

local VALID_COMMANDS = { list = true, read = true, write = true, delete = true }

function M.validate_input(input)
  local cmd = input.command
  if not VALID_COMMANDS[cmd] then
    return "unknown command '" .. tostring(cmd) .. "'. Valid commands: list, read, write, delete"
  end
  if input.tags ~= nil and type(input.tags) ~= "table" then
    return "'tags' must be an array"
  end
  local has_path = input.path ~= nil and input.path ~= ""
  local has_tags = type(input.tags) == "table" and #input.tags > 0
  if cmd == "read" then
    if has_path and has_tags then
      return "provide 'path' or 'tags', not both"
    end
    if not has_path and not has_tags then
      return "'path' or 'tags' is required for read"
    end
  elseif cmd == "write" then
    if not has_path then
      return "'path' is required for write"
    end
    if not input.content then
      return "'content' is required for write"
    end
    if input.tags == nil then
      return "'tags' is required for write (may be an empty array)"
    end
  elseif cmd == "delete" then
    if not has_path then
      return "'path' is required for delete"
    end
  end
  return nil
end

function M.normalize_to_want(raw_tags)
  local normalized, rejected = M.normalize_tags(raw_tags)
  local want = {}
  for _, n in ipairs(normalized) do
    want[n] = true
  end
  if not next(want) then
    local r = M.format_rejected(rejected)
    return nil, nil, "no valid tags after normalization" .. (r and ("; rejected: " .. r) or "")
  end
  local r = M.format_rejected(rejected)
  return want, r and (READ_REJECT_PREFIX .. r) or nil, nil
end

function M.validate_write_tags(raw_tags)
  local normalized, rejected = M.normalize_tags(raw_tags)
  local r = M.format_rejected(rejected)
  if r then
    return nil, WRITE_REJECT_PREFIX .. r
  end
  return normalized, nil
end

local function prepend_warning(warning, body, no_match_msg, separator)
  local result = body or no_match_msg
  if warning then
    return warning .. separator .. result
  end
  return result
end

function M.parse_frontmatter(content)
  local rest = content:match("^%s*%-%-%-\n(.*)")
  if not rest then
    return {}, content
  end
  local end_pos = rest:find("\n%-%-%-")
  if not end_pos then
    return {}, content
  end
  local yaml_str = rest:sub(1, end_pos)
  local body = rest:sub(end_pos + 4):match("^%s*(.-)%s*$")
  local fm = maki.yaml.decode(yaml_str) or {}
  return fm, body
end

function M.extract_tags(frontmatter)
  if type(frontmatter) ~= "table" then
    return nil
  end
  local raw = frontmatter.tags
  if type(raw) == "string" then
    raw = { raw }
  end
  if type(raw) ~= "table" then
    return nil
  end

  local out = M.normalize_tags(raw)
  return #out > 0 and out or nil
end

function M.tags_for_file(path, content, read_err)
  if content then
    local tags = M.extract_tags(M.parse_frontmatter(content))
    if tags then
      return tags, nil
    end
  end
  local tag = stem_tag(path)
  return { tag }, read_err or (content == nil and "read error" or nil)
end

local function matching_entries(dir, want)
  local entries = M.collect_file_entries(dir)
  table.sort(entries, function(a, b)
    return a[1] < b[1]
  end)

  local matches = {}
  local warnings = {}
  for _, f in ipairs(entries) do
    local name, size = f[1], f[2]
    local path = maki.fs.joinpath(dir, name)
    local content, read_err = maki.fs.read(path)
    if not content then
      warnings[#warnings + 1] = name .. ": " .. tostring(read_err)
    else
      for _, t in ipairs(M.tags_for_file(name, content)) do
        if want[t] then
          matches[#matches + 1] = { name = name, content = content, size = size }
          break
        end
      end
    end
  end
  return matches, warnings
end

function M.format_tag_line(dir, max_tags)
  local groups, warnings = M.grouped_tags(dir)
  if not groups then
    return nil
  end
  local tags = {}
  for i, g in ipairs(groups) do
    tags[i] = g.tag
  end

  local line
  if #tags <= max_tags then
    line = table.concat(tags, ", ")
  else
    local omitted = #tags - max_tags
    local shown = {}
    for i = 1, max_tags do
      shown[i] = tags[i]
    end
    line = table.concat(shown, ", ") .. " ... (" .. omitted .. " tags omitted; use `list` to see all)"
    line = line .. ". Consider removing or consolidating stale memories to stay under " .. max_tags .. "."
  end
  if #warnings > 0 then
    line = line .. " (unreadable: " .. #warnings .. ")"
  end
  return line
end

-- serde_yaml renders an empty list as an empty mapping; extract_tags treats both as empty.
function M.encode_frontmatter(tags)
  local yaml, _ = maki.yaml.encode({ tags = tags })
  return "---\n" .. yaml .. "---\n"
end

function M.grouped_tags(dir)
  local entries = M.collect_file_entries(dir)
  if #entries == 0 then
    return nil
  end
  table.sort(entries, function(a, b)
    return a[1] < b[1]
  end)

  local tag_groups = {}
  local warnings = {}
  for _, f in ipairs(entries) do
    local name, size = f[1], f[2]
    local path = maki.fs.joinpath(dir, name)
    local content, read_err = maki.fs.read(path)
    local tags, terr = M.tags_for_file(name, content, read_err and tostring(read_err))
    if terr then
      warnings[#warnings + 1] = name .. ": " .. terr
    end
    for _, t in ipairs(tags) do
      tag_groups[t] = tag_groups[t] or { tag = t, files = {} }
      local group = tag_groups[t]
      group.files[#group.files + 1] = { name = name, size = size }
    end
  end

  local groups = {}
  for _, g in pairs(tag_groups) do
    groups[#groups + 1] = g
  end
  table.sort(groups, function(a, b)
    local ca, cb = #a.files, #b.files
    if ca == cb then
      return a.tag < b.tag
    end
    return ca > cb
  end)
  return groups, warnings
end

local NO_MATCH_MSG = "no memory files matched any of the given tags; use `list` to see available tags"

function M.format_read_entry(name, size, content)
  local fm, body = M.parse_frontmatter(content)
  local tags = M.extract_tags(fm) or {}
  local header = name .. " (" .. size .. " bytes)"
  if #tags > 0 then
    header = header .. " [" .. table.concat(tags, ", ") .. "]"
  end
  return header .. "\n\n" .. body
end

function M.format_list(dir, raw_tags)
  local want, warning
  if raw_tags and #raw_tags > 0 then
    local werr
    want, warning, werr = M.normalize_to_want(raw_tags)
    if werr then
      return nil, werr
    end
  end

  local groups, read_warnings = M.grouped_tags(dir)
  if not groups then
    if not want then
      return nil
    end
    return prepend_warning(warning, nil, NO_MATCH_MSG, "\n")
  end

  local selected = groups
  if want then
    selected = {}
    for _, g in ipairs(groups) do
      if want[g.tag] then
        selected[#selected + 1] = g
      end
    end
    if #selected == 0 then
      return prepend_warning(warning, nil, NO_MATCH_MSG, "\n")
    end
  end

  local lines = {}
  for _, g in ipairs(selected) do
    lines[#lines + 1] = g.tag .. " (" .. #g.files .. ")"
    for _, f in ipairs(g.files) do
      lines[#lines + 1] = "  - " .. f.name .. " (" .. f.size .. " bytes)"
    end
    lines[#lines + 1] = ""
  end
  local body = table.concat(lines, "\n")
  local combined = warning
  if #read_warnings > 0 then
    local rw = "warning: unreadable memory files: " .. table.concat(read_warnings, ", ")
    combined = combined and (combined .. "\n" .. rw) or rw
  end
  return prepend_warning(combined, body, nil, "\n"), nil
end

function M.format_read(dir, raw_tags)
  local want, warning, err = M.normalize_to_want(raw_tags)
  if err then
    return nil, err
  end

  local matches, read_warnings = matching_entries(dir, want)
  if #read_warnings > 0 then
    local rw = "warning: unreadable memory files: " .. table.concat(read_warnings, ", ")
    warning = warning and (warning .. "\n" .. rw) or rw
  end

  local parts = {}
  for _, m in ipairs(matches) do
    parts[#parts + 1] = M.format_read_entry(m.name, m.size, m.content)
  end

  return prepend_warning(warning, #parts > 0 and table.concat(parts, "\n\n") or nil, NO_MATCH_MSG, "\n\n")
end

return M
