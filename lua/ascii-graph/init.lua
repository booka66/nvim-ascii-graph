local M = {}

local V = "│"
local T = "├"
local L = "└"
local H = "─"

local SPINE_LINE = V .. "   "
local SPINE_BLANK = "    "
local CONN_TEE = T .. H .. " "
local CONN_END = L .. H .. " "

local state = {}

local function detect_prefix(line)
  local pfx = line:match("^(%s*[%*/#%-;%%]+%s)")
  if pfx then return pfx end
  return line:match("^(%s*)") or ""
end

local function has_connector(s)
  return s:find(T, 1, true) ~= nil or s:find(L, 1, true) ~= nil
end

local function parse_line(line, prefix)
  if line:sub(1, #prefix) ~= prefix then
    return 0, (line:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  local rest = line:sub(#prefix + 1)
  if not has_connector(rest) then
    return 0, (rest:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  if rest:sub(1, 1) == " " then rest = rest:sub(2) end
  local depth = 1
  while true do
    if rest:sub(1, #SPINE_LINE) == SPINE_LINE then
      rest = rest:sub(#SPINE_LINE + 1); depth = depth + 1
    elseif rest:sub(1, #SPINE_BLANK) == SPINE_BLANK then
      rest = rest:sub(#SPINE_BLANK + 1); depth = depth + 1
    else
      break
    end
  end
  if rest:sub(1, #CONN_TEE) == CONN_TEE then
    rest = rest:sub(#CONN_TEE + 1)
  elseif rest:sub(1, #CONN_END) == CONN_END then
    rest = rest:sub(#CONN_END + 1)
  end
  return depth, (rest:gsub("%s+$", ""))
end

local function has_later_at(nodes, i, level)
  for j = i + 1, #nodes do
    if nodes[j].depth < level then return false end
    if nodes[j].depth == level then return true end
  end
  return false
end

local function render(nodes, prefix)
  local out = {}
  for i, node in ipairs(nodes) do
    if node.depth == 0 then
      out[i] = prefix .. node.label
    else
      local parts = { prefix, " " }
      for level = 1, node.depth - 1 do
        parts[#parts + 1] = has_later_at(nodes, i, level) and SPINE_LINE or SPINE_BLANK
      end
      parts[#parts + 1] = has_later_at(nodes, i, node.depth) and CONN_TEE or CONN_END
      parts[#parts + 1] = node.label
      out[i] = table.concat(parts)
    end
  end
  return out
end

local function subtree_end(nodes, i)
  local d = nodes[i].depth
  local j = i + 1
  while j <= #nodes and nodes[j].depth > d do j = j + 1 end
  return j - 1
end

local ops = {}

function ops.new_sibling(nodes, i)
  if #nodes == 0 then
    table.insert(nodes, { depth = 0, label = "" }); return 1
  end
  local j = subtree_end(nodes, i)
  local depth = nodes[i].depth == 0 and (nodes[i + 1] and 1 or 1) or nodes[i].depth
  if nodes[i].depth == 0 then
    table.insert(nodes, j + 1, { depth = 1, label = "" })
  else
    table.insert(nodes, j + 1, { depth = depth, label = "" })
  end
  return j + 1
end

function ops.new_child(nodes, i)
  if #nodes == 0 then
    table.insert(nodes, { depth = 0, label = "" }); return 1
  end
  table.insert(nodes, i + 1, { depth = nodes[i].depth + 1, label = "" })
  return i + 1
end

function ops.new_above(nodes, i)
  if #nodes == 0 then
    table.insert(nodes, { depth = 0, label = "" }); return 1
  end
  table.insert(nodes, i, { depth = nodes[i].depth, label = "" })
  return i
end

function ops.indent(nodes, i)
  if i == 1 then return i end
  local max_depth = nodes[i - 1].depth + 1
  if nodes[i].depth >= max_depth then return i end
  local send = subtree_end(nodes, i)
  for k = i, send do nodes[k].depth = nodes[k].depth + 1 end
  return i
end

function ops.outdent(nodes, i)
  if nodes[i].depth == 0 then return i end
  local send = subtree_end(nodes, i)
  for k = i, send do nodes[k].depth = nodes[k].depth - 1 end
  return i
end

function ops.delete(nodes, i)
  if #nodes == 0 then return 1 end
  local send = subtree_end(nodes, i)
  for k = send, i, -1 do table.remove(nodes, k) end
  if #nodes == 0 then
    table.insert(nodes, { depth = 0, label = "" })
    return 1
  end
  return math.min(i, #nodes)
end

local function parse_all(lines, prefix)
  local nodes = {}
  for _, line in ipairs(lines) do
    local d, lbl = parse_line(line, prefix)
    table.insert(nodes, { depth = d, label = lbl })
  end
  return nodes
end

local function indent_byte_len(line, label)
  return #line - #label
end

local function has_tree_chars(line)
  if not line then return false end
  return line:find(T, 1, true) ~= nil or line:find(L, 1, true) ~= nil or line:find(V, 1, true) ~= nil
end

local function common_prefix_bytes(lines)
  if #lines == 0 then return "" end
  local ref = lines[1]
  local len = #ref
  for i = 2, #lines do
    local l = lines[i]
    local j = 0
    while j < len and j < #l and ref:byte(j + 1) == l:byte(j + 1) do
      j = j + 1
    end
    len = j
  end
  local s = ref:sub(1, len)
  local i = #s
  while i > 0 do
    local b = s:byte(i)
    if b < 128 or b >= 192 then break end
    i = i - 1
  end
  if i > 0 and s:byte(i) >= 192 then
    local seq_len = s:byte(i) < 224 and 2 or (s:byte(i) < 240 and 3 or 4)
    if i + seq_len - 1 > #s then s = s:sub(1, i - 1) end
  end
  return s
end

local function find_block(bufnr, lnum)
  local get = function(l)
    if l < 1 then return nil end
    return vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  end
  local cur = get(lnum)
  if not cur then return nil end

  local start_l, end_l = lnum, lnum
  while has_tree_chars(get(start_l - 1)) do start_l = start_l - 1 end
  while has_tree_chars(get(end_l + 1)) do end_l = end_l + 1 end

  if not has_tree_chars(cur) and start_l == end_l then
    local below = get(lnum + 1)
    if below and has_tree_chars(below) then
      end_l = lnum + 1
      while has_tree_chars(get(end_l + 1)) do end_l = end_l + 1 end
    end
  end

  local above = get(start_l - 1)
  if above and not has_tree_chars(above) then
    local above_pfx = detect_prefix(above)
    local first_pfx = detect_prefix(get(start_l))
    if above_pfx == first_pfx then
      local rest = above:sub(#above_pfx + 1):gsub("^%s+", ""):gsub("%s+$", "")
      if rest ~= "" then
        start_l = start_l - 1
      end
    end
  end

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, start_l - 1, end_l, false)
  local has_root = not has_tree_chars(all_lines[1])
  local prefix

  if has_root and #all_lines >= 2 then
    prefix = common_prefix_bytes(all_lines)
  else
    prefix = detect_prefix(all_lines[1])
  end

  return { prefix = prefix, start_l = start_l, end_l = end_l }
end

local function cursor_idx(block)
  local lnum = vim.fn.line(".")
  local idx = lnum - block.start_l + 1
  if idx < 1 then idx = 1 end
  local len = block.end_l - block.start_l + 1
  if idx > len then idx = len end
  return idx
end

local function apply_op(bufnr, name)
  local block = state[bufnr]
  if not block then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  local nodes = parse_all(lines, block.prefix)
  local idx = cursor_idx(block)
  local new_idx = ops[name](nodes, idx)
  local new_lines = render(nodes, block.prefix)
  vim.api.nvim_buf_set_lines(bufnr, block.start_l - 1, block.end_l, false, new_lines)
  block.end_l = block.start_l + #new_lines - 1
  local target_lnum = block.start_l + new_idx - 1
  local node = nodes[new_idx]
  local line = new_lines[new_idx]
  local col = indent_byte_len(line, node.label)
  vim.api.nvim_win_set_cursor(0, { target_lnum, col })
end

local function place_cursor_at_label_end(bufnr, block, nodes, new_lines, idx)
  local lnum = block.start_l + idx - 1
  vim.api.nvim_win_set_cursor(0, { lnum, #new_lines[idx] })
end

local function apply_op_stay_insert(bufnr, name)
  local block = state[bufnr]
  if not block then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  local nodes = parse_all(lines, block.prefix)
  local idx = cursor_idx(block)
  local new_idx = ops[name](nodes, idx)
  local new_lines = render(nodes, block.prefix)
  vim.api.nvim_buf_set_lines(bufnr, block.start_l - 1, block.end_l, false, new_lines)
  block.end_l = block.start_l + #new_lines - 1
  place_cursor_at_label_end(bufnr, block, nodes, new_lines, new_idx)
end

local N_KEYS = { "<Tab>", "<S-Tab>", "<CR>", "o", "O", "dd", "i", "a", "A", "<Esc>" }
local I_KEYS = { "<CR>", "<Tab>", "<S-Tab>", "<C-d>", "<Esc>" }

local function enter_insert_at_label_end(bufnr)
  local block = state[bufnr]
  if not block then return end
  local idx = cursor_idx(block)
  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  local lnum = block.start_l + idx - 1
  vim.api.nvim_win_set_cursor(0, { lnum, #lines[idx] })
  vim.cmd("startinsert!")
end

local function set_keys(bufnr)
  local nmap = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  local imap = function(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end

  nmap("<Tab>", function() apply_op(bufnr, "indent") end)
  nmap("<S-Tab>", function() apply_op(bufnr, "outdent") end)
  nmap("<CR>", function() apply_op(bufnr, "new_sibling"); enter_insert_at_label_end(bufnr) end)
  nmap("o", function() apply_op(bufnr, "new_child"); enter_insert_at_label_end(bufnr) end)
  nmap("O", function() apply_op(bufnr, "new_above"); enter_insert_at_label_end(bufnr) end)
  nmap("dd", function() apply_op(bufnr, "delete") end)
  nmap("i", function() enter_insert_at_label_end(bufnr) end)
  nmap("a", function() enter_insert_at_label_end(bufnr) end)
  nmap("A", function() enter_insert_at_label_end(bufnr) end)
  nmap("<Esc>", function() M.exit(bufnr) end)

  imap("<CR>", function() apply_op_stay_insert(bufnr, "new_sibling") end)
  imap("<Tab>", function() apply_op_stay_insert(bufnr, "indent") end)
  imap("<S-Tab>", function() apply_op_stay_insert(bufnr, "outdent") end)
  imap("<C-d>", function() apply_op_stay_insert(bufnr, "delete") end)
  imap("<Esc>", function()
    vim.cmd("stopinsert")
  end)
end

local function unset_keys(bufnr)
  for _, lhs in ipairs(N_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  for _, lhs in ipairs(I_KEYS) do
    pcall(vim.keymap.del, "i", lhs, { buffer = bufnr })
  end
end

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.fn.line(".")
  local block = find_block(bufnr, lnum)
  if not block then return end
  state[bufnr] = block

  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  if #lines == 1 then
    local stripped = lines[1]:sub(#block.prefix + 1):gsub("^%s+", ""):gsub("%s+$", "")
    if stripped == "" then
      vim.api.nvim_buf_set_lines(bufnr, block.start_l - 1, block.end_l, false, { block.prefix })
    end
  end

  set_keys(bufnr)
  vim.api.nvim_echo({ { "-- ASCII GRAPH --", "ModeMsg" } }, false, {})
  enter_insert_at_label_end(bufnr)
end

function M.exit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not state[bufnr] then return end
  local block = state[bufnr]
  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  local nodes = parse_all(lines, block.prefix)
  local new_lines = render(nodes, block.prefix)
  vim.api.nvim_buf_set_lines(bufnr, block.start_l - 1, block.end_l, false, new_lines)
  unset_keys(bufnr)
  state[bufnr] = nil
  vim.api.nvim_echo({ { "", "" } }, false, {})
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if state[bufnr] then M.exit(bufnr) else M.enter(bufnr) end
end

function M.is_active(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return state[bufnr] ~= nil
end

function M.status()
  if M.is_active() then return "GRAPH" end
  return ""
end

function M.lualine_component()
  return {
    function() return M.status() end,
    cond = M.is_active,
    color = { fg = "#1a1b26", bg = "#7aa2f7", gui = "bold" },
  }
end

function M.setup(opts)
  opts = opts or {}
  vim.api.nvim_create_user_command("AsciiGraph", M.toggle, {})
  if opts.keymap then
    vim.keymap.set("n", opts.keymap, M.toggle, { desc = "Toggle ASCII graph mode" })
  end
end

M._internal = {
  parse_line = parse_line,
  render = render,
  parse_all = parse_all,
  detect_prefix = detect_prefix,
  common_prefix_bytes = common_prefix_bytes,
  ops = ops,
}

return M
