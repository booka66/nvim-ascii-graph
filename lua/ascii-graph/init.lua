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
  local pfx = line:match("^(%s*[%*/#%-;%%]+%s+)")
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

local function find_block(bufnr, lnum)
  local get = function(l)
    if l < 1 then return nil end
    return vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  end
  local cur = get(lnum)
  if not cur then return nil end
  local prefix = detect_prefix(cur)

  local function tree_line(line)
    if not line then return false end
    if line:sub(1, #prefix) ~= prefix then return false end
    return has_connector(line:sub(#prefix + 1))
  end

  local start_l, end_l = lnum, lnum
  while tree_line(get(start_l - 1)) do start_l = start_l - 1 end
  local above = get(start_l - 1)
  if above and above:sub(1, #prefix) == prefix and not has_connector(above:sub(#prefix + 1)) then
    local stripped = above:sub(#prefix + 1):gsub("^%s+", ""):gsub("%s+$", "")
    if stripped ~= "" then start_l = start_l - 1 end
  end
  while tree_line(get(end_l + 1)) do end_l = end_l + 1 end

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

local function enter_insert(bufnr, kind)
  local block = state[bufnr]
  if not block then return end
  local idx = cursor_idx(block)
  local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_l - 1, block.end_l, false)
  local nodes = parse_all(lines, block.prefix)
  local node = nodes[idx]
  local line = lines[idx]
  local label_start = indent_byte_len(line, node.label)
  local lnum = block.start_l + idx - 1
  if kind == "i" then
    vim.api.nvim_win_set_cursor(0, { lnum, label_start })
    vim.cmd("startinsert")
  else
    vim.api.nvim_win_set_cursor(0, { lnum, #line })
    vim.cmd("startinsert!")
  end
end

local KEYS = { "<Tab>", "<S-Tab>", "<CR>", "o", "O", "dd", "i", "a", "A", "<Esc>" }

local function set_keys(bufnr)
  local nmap = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  nmap("<Tab>", function() apply_op(bufnr, "indent") end)
  nmap("<S-Tab>", function() apply_op(bufnr, "outdent") end)
  nmap("<CR>", function() apply_op(bufnr, "new_sibling"); enter_insert(bufnr, "a") end)
  nmap("o", function() apply_op(bufnr, "new_child"); enter_insert(bufnr, "a") end)
  nmap("O", function() apply_op(bufnr, "new_above"); enter_insert(bufnr, "i") end)
  nmap("dd", function() apply_op(bufnr, "delete") end)
  nmap("i", function() enter_insert(bufnr, "i") end)
  nmap("a", function() enter_insert(bufnr, "a") end)
  nmap("A", function() enter_insert(bufnr, "a") end)
  nmap("<Esc>", function() M.exit(bufnr) end)
end

local function unset_keys(bufnr)
  for _, lhs in ipairs(KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
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
end

function M.exit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not state[bufnr] then return end
  unset_keys(bufnr)
  state[bufnr] = nil
  vim.api.nvim_echo({ { "", "" } }, false, {})
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if state[bufnr] then M.exit(bufnr) else M.enter(bufnr) end
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
  ops = ops,
}

return M
