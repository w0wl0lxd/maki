local TextInput = require("maki.text_input")

local ListPicker = {}
ListPicker.__index = ListPicker

local DETAIL_RIGHT_PAD = 2
local NO_MATCHES_LABEL = "  (no matches)"

local function item_label(item)
  return type(item) == "string" and item or item.label
end

local function item_section(item)
  return type(item) == "table" and item.section or nil
end

local function filter_items(items, query)
  if query == "" then
    local indices, positions = {}, {}
    for i = 1, #items do
      indices[i] = i
      positions[i] = {}
    end
    return items, indices, positions
  end

  local labels = {}
  for i = 1, #items do
    labels[i] = item_label(items[i])
  end

  local matches = maki.fuzzy.match(query, labels)
  local filtered, indices, positions = {}, {}, {}
  for _, m in ipairs(matches) do
    filtered[#filtered + 1] = items[m.index]
    indices[#indices + 1] = m.index
    positions[#positions + 1] = m.positions or {}
  end
  return filtered, indices, positions
end

local function label_spans(label, positions, style, match_style)
  if not positions or #positions == 0 then
    return { { "  " .. label, style } }
  end

  local match_set = {}
  for _, p in ipairs(positions) do
    match_set[p] = true
  end

  local chars = {}
  for _, code in utf8.codes(label) do
    chars[#chars + 1] = utf8.char(code)
  end

  local parts = {}
  local current, current_is_match, has_started = {}, false, false
  for i = 1, #chars do
    local ch = chars[i]
    local is_match = match_set[i] or false
    if not has_started then
      current, current_is_match, has_started = { ch }, is_match, true
    elseif is_match == current_is_match then
      current[#current + 1] = ch
    else
      parts[#parts + 1] = { table.concat(current), current_is_match and match_style or style }
      current, current_is_match = { ch }, is_match
    end
  end
  if #current > 0 then
    parts[#parts + 1] = { table.concat(current), current_is_match and match_style or style }
  end

  if parts[1] then
    parts[1][1] = "  " .. parts[1][1]
  end
  return parts
end

local function render_lines(items, selected, width, positions_per_item)
  width = width or 80
  positions_per_item = positions_per_item or {}

  local prev_section = nil
  local lines = {}
  local selected_row = 1
  for i, item in ipairs(items) do
    local label = item_label(item)
    local detail = type(item) == "table" and item.detail or nil
    local section = item_section(item)
    local is_sel = (i == selected)
    local style = is_sel and "selected" or "item"
    local detail_style = is_sel and "selected" or "dim"
    local match_style = is_sel and "match_selected" or "match"

    if section and section ~= prev_section then
      lines[#lines + 1] = { { "  " .. section, "section" } }
      prev_section = section
    end

    if is_sel then
      selected_row = #lines + 1
    end

    local spans = label_spans(label, positions_per_item[i], style, match_style)

    if detail then
      local pad = width - 2 - #label - #detail - DETAIL_RIGHT_PAD
      if pad < 1 then
        pad = 1
      end
      spans[#spans + 1] = { string.rep(" ", pad), style }
      spans[#spans + 1] = { detail, detail_style }
      spans[#spans + 1] = { string.rep(" ", DETAIL_RIGHT_PAD), style }
    else
      local trail = width - 2 - #label
      if trail > 0 then
        spans[#spans + 1] = { string.rep(" ", trail), style }
      end
    end

    lines[#lines + 1] = spans
  end
  return lines, selected_row
end

function ListPicker.open(items, opts)
  opts = opts or {}
  local submit_keys = { enter = true }
  if opts.submit_keys then
    for _, k in ipairs(opts.submit_keys) do
      submit_keys[k] = true
    end
  end
  local width
  local input = TextInput.new()
  local filtered, original_indices, positions_per_item = filter_items(items, "")

  local cursor = opts.cursor or 1
  if cursor > #filtered then
    cursor = #filtered
  end
  if cursor < 1 then
    cursor = 1
  end

  local cursor_row = 1
  local function build_lines()
    local content
    if #filtered == 0 then
      content = { { { NO_MATCHES_LABEL, "dim" } } }
      cursor_row = 1
    else
      local lines
      lines, cursor_row = render_lines(filtered, cursor, width, positions_per_item)
      content = lines
    end
    local r = input:render("\xe2\x9d\xaf ")
    for _, ln in ipairs(r.lines) do
      content[#content + 1] = ln
    end
    return content
  end

  local buf = maki.ui.buf()

  local border_chrome = 2
  local section_count = 0
  local prev_section = nil
  for _, item in ipairs(items) do
    local s = item_section(item)
    if s and s ~= prev_section then
      section_count = section_count + 1
      prev_section = s
    end
  end
  local content_h = #items + section_count + 1
  local total_h = content_h + border_chrome

  local win = maki.ui.open_win(buf, {
    title = opts.title,
    footer = opts.footer,
    height = total_h,
    reserved_bottom = 1,
  })

  width = win.width
  buf:set_lines(build_lines())
  win:set_cursor(cursor_row)
  local confirming = nil

  while true do
    local ev = win:recv()
    if not ev or ev.type == "close" then
      return { type = "close" }
    end

    if ev.type == "resize" then
      width = ev.width
      buf:set_lines(build_lines())
      win:set_cursor(cursor_row)
    elseif ev.type == "key" then
      if ev.key == "up" then
        if cursor > 1 then
          cursor = cursor - 1
          buf:set_lines(build_lines())
          win:set_cursor(cursor_row)
        end
        confirming = nil
      elseif ev.key == "down" then
        if cursor < #filtered then
          cursor = cursor + 1
          buf:set_lines(build_lines())
          win:set_cursor(cursor_row)
        end
        confirming = nil
      elseif ev.key == "esc" or ev.key == "ctrl+c" then
        win:close()
        return { type = "close" }
      elseif ev.key == "ctrl+d" then
        if #filtered > 0 then
          if confirming == cursor then
            win:close()
            return { type = "delete", index = original_indices[cursor] }
          else
            confirming = cursor
            maki.ui.flash("Press Ctrl+D again to delete")
          end
        end
      elseif submit_keys[ev.key] then
        if #filtered > 0 then
          win:close()
          return { type = "choice", index = original_indices[cursor] }
        end
      else
        local result = input:handle_key(ev.key)
        if result == TextInput.Result.CHANGED then
          filtered, original_indices, positions_per_item = filter_items(items, input:value())
          if cursor > #filtered then
            cursor = #filtered
            if cursor < 1 then
              cursor = 1
            end
          end
          buf:set_lines(build_lines())
          win:set_cursor(cursor_row)
          confirming = nil
        elseif result == TextInput.Result.MOVED then
          buf:set_lines(build_lines())
          confirming = nil
        end
      end
    end
  end
end

ListPicker._render_lines = render_lines
ListPicker._filter_items = filter_items

return ListPicker
