local ToolView = require("maki.tool_view")
local helpers = require("memory_helpers")
local ListPicker = require("maki.list_picker")

local function memories_path_suffix()
  local cwd = maki.uv.cwd()
  local root = maki.fs.root(cwd, ".git") or cwd
  return "projects/" .. helpers.project_id(root) .. "/memories"
end

local function resolve_dir(check_legacy)
  if check_legacy then
    local legacy = maki.env.legacy_dir()
    if legacy then
      local dir = maki.fs.joinpath(legacy, memories_path_suffix())
      local meta = maki.fs.metadata(dir)
      if meta and meta.is_dir then
        return dir
      end
    end
  end
  local state = maki.env.state_dir()
  if not state then
    return nil, "cannot resolve state dir"
  end
  return maki.fs.joinpath(state, memories_path_suffix())
end

maki.api.register_prompt_hint({
  prompt = "system",
  slot = "after_instructions",
  content = function()
    local dir = resolve_dir(true)
    if not dir then
      return nil
    end
    local tag_line = helpers.format_tag_line(dir, helpers.MAX_TAGS)
    if not tag_line then
      return nil
    end
    return "\n\nMemory tags (use `list` then `read tags=[...]` to retrieve): " .. tag_line .. "\n"
  end,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Proactively save non-obvious project gotchas and architecture decisions to **memory**.",
})

local function render_content(content, path, ctx)
  local buf = maki.ui.buf()
  local tol = ctx:tool_output_lines()
  local view = ToolView.new(buf, {
    max_lines = (tol and tol.other) or 20,
    keep = "head",
  })
  buf:on("click", function()
    view:toggle()
  end)

  local ext = path:match("%.([^%.]+)$") or "md"
  if not view:set_highlight(content, ext) then
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      view:append(line)
    end
  end
  view:finish()
  return buf
end

local function cmd_read(path, dir, ctx)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end
  local content, err = maki.fs.read(file_path)
  if not content then
    return nil, "read error: " .. err
  end
  local meta = maki.fs.metadata(file_path)
  local size = meta and meta.size or #content
  local formatted = helpers.format_read_entry(path, size, content)
  return {
    llm_output = formatted,
    body = render_content(formatted, path, ctx),
  }
end

local function cmd_write(path, content, tags, dir, ctx)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end

  local normalized, verr = helpers.validate_write_tags(tags)
  if verr then
    return nil, verr
  end
  local full = helpers.encode_frontmatter(normalized) .. content
  maki.fs.mkdir(dir, { parents = true })
  local ok, write_err = maki.fs.write(file_path, full)
  if not ok then
    return nil, "write error: " .. tostring(write_err)
  end
  return {
    llm_output = "wrote "
      .. path
      .. " (tags: "
      .. (#normalized > 0 and table.concat(normalized, ", ") or "none")
      .. ")",
    body = render_content(full, path, ctx),
  }
end

local function cmd_delete(path, dir)
  local file_path, err = helpers.safe_resolve(dir, path)
  if not file_path then
    return nil, err
  end
  if not maki.fs.metadata(file_path) then
    return nil, "'" .. path .. "' does not exist"
  end
  local ok, rm_err = maki.fs.rm(file_path)
  if not ok then
    return nil, "delete error: " .. tostring(rm_err)
  end
  return "deleted " .. path
end

maki.api.register_tool({
  name = "memory",
  description = "Persistent, project-scoped scratchpad for learnings, patterns, decisions, and gotchas across sessions.\n\n"
    .. "- Memory files carry a `tags:` frontmatter list (snake_case) for retrieval.\n"
    .. "- Available tags are listed in your system prompt; use `list` (no args) to see the full grouped index.\n"
    .. "- Save important context before compaction or to build up project knowledge.\n"
    .. "- Keep entries concise and current. Delete outdated information.",

  schema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "Commands:\n"
          .. "- `list [tags=[...]]`: tag-grouped index (no bodies); pass tags to filter.\n"
          .. "- `read path=X | tags=[...]`: one file body (path) or collated bodies (tags).\n"
          .. "- `write path=X tags=[...] content=Y`: create or overwrite a memory.\n"
          .. "- `delete path=X`: delete one file.",
        required = true,
      },
      path = {
        type = "string",
        description = "File path (relative, e.g. 'architecture.md'). Used by read, write, delete.",
      },
      content = { type = "string", description = "Body for write (frontmatter added automatically)." },
      tags = {
        type = "array",
        items = { type = "string" },
        description = "Tag list for list (filter) and read (selector) and write (assign). snake_case normalized.",
      },
    },
  },

  header = function(input)
    local parts = { input.command or "" }
    if input.path then
      parts[#parts + 1] = input.path
    elseif input.tags then
      parts[#parts + 1] = table.concat(input.tags, ",")
    end
    return table.concat(parts, " ")
  end,

  restore = function(input, output, _is_error, ctx)
    local content = (input.command == "write" and input.content) or output
    return render_content(content, input.path or "memory.md", ctx)
  end,

  handler = function(input, ctx)
    local verr = helpers.validate_input(input)
    if verr then
      return { llm_output = "error: " .. verr, is_error = true }
    end
    local cmd = input.command
    local has_path = input.path ~= nil and input.path ~= ""
    local has_tags = type(input.tags) == "table" and #input.tags > 0
    local read_only = cmd == "list" or cmd == "read"
    local dir, dir_err = resolve_dir(read_only)
    if not dir then
      return { llm_output = "error: " .. dir_err, is_error = true }
    end

    local result, err
    if cmd == "list" then
      result, err = helpers.format_list(dir, input.tags)
      if result == nil and not err then
        result = "No memories yet."
      end
    elseif cmd == "read" then
      if has_tags then
        result, err = helpers.format_read(dir, input.tags)
      else
        result, err = cmd_read(input.path, dir, ctx)
      end
    elseif cmd == "write" then
      result, err = cmd_write(input.path, input.content, input.tags, dir, ctx)
    elseif cmd == "delete" then
      result, err = cmd_delete(input.path, dir)
    end
    if err then
      return { llm_output = "error: " .. err, is_error = true }
    end
    return result
  end,
})

local function popup_build_items(dir)
  local groups = helpers.grouped_tags(dir)
  if not groups then
    return {}
  end

  local items = {}
  for _, g in ipairs(groups) do
    local section = g.tag .. " (" .. #g.files .. ")"
    for _, f in ipairs(g.files) do
      items[#items + 1] = { label = f.name, detail = "(" .. f.size .. " bytes)", section = section }
    end
  end
  return items
end

maki.api.register_command({
  name = "/memory",
  description = "View, edit, and delete memory files",
  handler = function()
    local dir = resolve_dir(true)
    if not dir then
      maki.ui.flash("Cannot resolve memory directory")
      return
    end

    local items = popup_build_items(dir)
    local last_cursor = 1
    while true do
      if last_cursor > #items then
        last_cursor = math.max(1, #items)
      end
      local event = ListPicker.open(items, {
        title = " Memory Files ",
        cursor = last_cursor,
        submit_keys = { "ctrl+o" },
        footer = {
          { "Enter", "open" },
          { "Ctrl+O", "edit" },
          { "Ctrl+D", "delete" },
        },
      })

      if event.type == "close" then
        break
      end

      last_cursor = event.index
      if event.type == "choice" then
        local item = items[event.index]
        if item then
          local path = maki.fs.joinpath(dir, item.label)
          local code = maki.ui.open_editor(path)
          if code == 0 then
            items = popup_build_items(dir)
          end
        end
      elseif event.type == "delete" then
        local item = items[event.index]
        local ok, err = maki.fs.rm(maki.fs.joinpath(dir, item.label))
        if ok then
          maki.ui.flash("Deleted " .. item.label)
          items = popup_build_items(dir)
          if #items == 0 then
            break
          end
        else
          maki.ui.flash("Delete failed: " .. tostring(err))
        end
      else
        break
      end
    end
  end,
})
