local M = {}

local BOX = { TL = "╭", TR = "╮", BL = "╰", BR = "╯", H = "─", V = "│" }
local CONN = {
  H = "─", V = "│",
  ULC = "┌", URC = "┐", LLC = "└", LRC = "┘",
  AR = "▶", AL = "◀", AU = "▲", AD = "▼",
}

local state = {}

local function new_model(start_l)
  return {
    start_l = start_l,
    end_l = start_l - 1,
    nodes = {},
    order = {},
    edges = {},
    next_id = 1,
    conn_pending = nil,
    saved_ve = nil,
  }
end

local function utf8_byte_len(b)
  if b < 0x80 then return 1
  elseif b < 0xC0 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4 end
end

local function chars(s)
  local out, i = {}, 1
  while i <= #s do
    local len = utf8_byte_len(s:byte(i))
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return out
end

local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

local function display_col_to_byte_col(line, dcol)
  local i, d = 1, 0
  while i <= #line and d < dcol - 1 do
    local len = utf8_byte_len(line:byte(i))
    d = d + 1
    i = i + len
  end
  return i - 1
end

local function compute_node_size(label)
  local lines = vim.split(label or "", "\n", { plain = true })
  local w = 0
  for _, l in ipairs(lines) do
    local cw = display_width(l)
    if cw > w then w = cw end
  end
  w = math.max(w + 4, 6)
  local h = math.max(#lines + 2, 3)
  return w, h, lines
end

local function add_node(m, x, y, label)
  local w, h, lines = compute_node_size(label)
  local id = m.next_id
  m.next_id = id + 1
  local node = { id = id, x = x, y = y, w = w, h = h, lines = lines, label = label }
  m.nodes[id] = node
  table.insert(m.order, id)
  return node
end

local function set_node_label(m, id, label)
  local node = m.nodes[id]
  if not node then return end
  local w, h, lines = compute_node_size(label)
  node.w, node.h, node.lines, node.label = w, h, lines, label
end

local function del_node(m, id)
  m.nodes[id] = nil
  for i, nid in ipairs(m.order) do
    if nid == id then table.remove(m.order, i); break end
  end
  for i = #m.edges, 1, -1 do
    if m.edges[i].from == id or m.edges[i].to == id then
      table.remove(m.edges, i)
    end
  end
end

local function add_edge(m, from, to)
  for _, e in ipairs(m.edges) do
    if e.from == from and e.to == to then return end
  end
  table.insert(m.edges, { from = from, to = to })
end

local function blank_canvas(w, h)
  local g = {}
  for y = 1, h do
    g[y] = {}
    for x = 1, w do g[y][x] = " " end
  end
  return g
end

local function setc(g, x, y, ch)
  if y < 1 or y > #g then return end
  if x < 1 or x > #g[y] then return end
  g[y][x] = ch
end

local function draw_box(g, node)
  local x1, y1 = node.x, node.y
  local x2, y2 = x1 + node.w - 1, y1 + node.h - 1
  setc(g, x1, y1, BOX.TL); setc(g, x2, y1, BOX.TR)
  setc(g, x1, y2, BOX.BL); setc(g, x2, y2, BOX.BR)
  for x = x1 + 1, x2 - 1 do setc(g, x, y1, BOX.H); setc(g, x, y2, BOX.H) end
  for y = y1 + 1, y2 - 1 do setc(g, x1, y, BOX.V); setc(g, x2, y, BOX.V) end
  for i, line in ipairs(node.lines) do
    local ly = y1 + i
    local cs = chars(line)
    for j, ch in ipairs(cs) do
      setc(g, x1 + 1 + j, ly, ch)
    end
  end
end

local function route_edge(g, from, to)
  local fcx = from.x + math.floor(from.w / 2)
  local fcy = from.y + math.floor(from.h / 2)
  local tcx = to.x + math.floor(to.w / 2)
  local tcy = to.y + math.floor(to.h / 2)

  local f_right, f_bottom = from.x + from.w - 1, from.y + from.h - 1
  local t_right, t_bottom = to.x + to.w - 1, to.y + to.h - 1

  local sx, sy, sdir, tx, ty, tdir
  if to.x > f_right then
    sx, sy, sdir = f_right, fcy, "R"
    tx, ty, tdir = to.x, tcy, "L"
  elseif from.x > t_right then
    sx, sy, sdir = from.x, fcy, "L"
    tx, ty, tdir = t_right, tcy, "R"
  elseif to.y > f_bottom then
    sx, sy, sdir = fcx, f_bottom, "D"
    tx, ty, tdir = tcx, to.y, "U"
  else
    sx, sy, sdir = fcx, from.y, "U"
    tx, ty, tdir = tcx, t_bottom, "D"
  end

  if sdir == "R" then sx = sx + 1
  elseif sdir == "L" then sx = sx - 1
  elseif sdir == "D" then sy = sy + 1
  else sy = sy - 1 end

  local bx, by = tx, ty
  if tdir == "R" then bx = tx + 1
  elseif tdir == "L" then bx = tx - 1
  elseif tdir == "D" then by = ty + 1
  else by = ty - 1 end

  local arrow = ({ R = CONN.AL, L = CONN.AR, U = CONN.AD, D = CONN.AU })[tdir]

  if sdir == "R" or sdir == "L" then
    local x1, x2 = math.min(sx, bx), math.max(sx, bx)
    for x = x1, x2 do setc(g, x, sy, CONN.H) end
    if sy ~= by then
      local c1
      if sdir == "R" then
        c1 = (by > sy) and CONN.URC or CONN.LRC
      else
        c1 = (by > sy) and CONN.ULC or CONN.LLC
      end
      setc(g, bx, sy, c1)
      local y1, y2 = math.min(sy, by), math.max(sy, by)
      for y = y1 + 1, y2 - 1 do setc(g, bx, y, CONN.V) end
      local c2
      if tdir == "L" then
        c2 = (by > sy) and CONN.LLC or CONN.ULC
      else
        c2 = (by > sy) and CONN.LRC or CONN.URC
      end
      setc(g, bx, by, c2)
    end
    setc(g, tx, ty, arrow)
  else
    local y1, y2 = math.min(sy, by), math.max(sy, by)
    for y = y1, y2 do setc(g, sx, y, CONN.V) end
    if sx ~= bx then
      local c1
      if sdir == "D" then
        c1 = (bx > sx) and CONN.LLC or CONN.LRC
      else
        c1 = (bx > sx) and CONN.ULC or CONN.URC
      end
      setc(g, sx, by, c1)
      local x1, x2 = math.min(sx, bx), math.max(sx, bx)
      for x = x1 + 1, x2 - 1 do setc(g, x, by, CONN.H) end
      local c2
      if tdir == "U" then
        c2 = (bx > sx) and CONN.LRC or CONN.LLC
      else
        c2 = (bx > sx) and CONN.URC or CONN.ULC
      end
      setc(g, bx, by, c2)
    end
    setc(g, tx, ty, arrow)
  end
end

local function canvas_size(m)
  local w, h = 1, 1
  for _, n in pairs(m.nodes) do
    if n.x + n.w > w then w = n.x + n.w end
    if n.y + n.h > h then h = n.y + n.h end
  end
  return w, h
end

local function render_lines(m)
  if vim.tbl_isempty(m.nodes) then return { "" } end
  local w, h = canvas_size(m)
  local g = blank_canvas(w, h)
  for _, id in ipairs(m.order) do draw_box(g, m.nodes[id]) end
  for _, e in ipairs(m.edges) do
    local f, t = m.nodes[e.from], m.nodes[e.to]
    if f and t then route_edge(g, f, t) end
  end
  local out = {}
  for y = 1, h do out[y] = table.concat(g[y]) end
  return out
end

local function flush(bufnr, m)
  local lines = render_lines(m)
  if #lines == 1 and lines[1] == "" and m.end_l < m.start_l then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, m.start_l - 1, math.max(m.end_l, m.start_l - 1), false, lines)
  m.end_l = m.start_l + #lines - 1
end

local function cursor_canvas_pos(m)
  local lnum = vim.fn.line(".")
  local cx = vim.fn.virtcol(".")
  local cy = lnum - m.start_l + 1
  if cy < 1 then cy = 1 end
  if cx < 1 then cx = 1 end
  return cx, cy
end

local function node_at(m, cx, cy)
  for i = #m.order, 1, -1 do
    local n = m.nodes[m.order[i]]
    if cx >= n.x and cx < n.x + n.w and cy >= n.y and cy < n.y + n.h then
      return n
    end
  end
  return nil
end

local function set_cursor_canvas(bufnr, m, cx, cy)
  local lnum = m.start_l + cy - 1
  if lnum < 1 then lnum = 1 end
  local last = vim.api.nvim_buf_line_count(bufnr)
  if lnum > last then lnum = last end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local bc = display_col_to_byte_col(line, cx)
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, bc })
end

local function msg(text)
  vim.api.nvim_echo({ { text, "ModeMsg" } }, false, {})
end

local function open_edit_float(bufnr, m, node)
  local edit_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[edit_buf].buftype = "nofile"
  vim.bo[edit_buf].bufhidden = "wipe"
  local init_lines = (#node.lines == 0) and { "" } or node.lines
  vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, init_lines)

  local chart_win = vim.api.nvim_get_current_win()

  local function get_top()
    return vim.api.nvim_win_call(chart_win, function() return vim.fn.line("w0") end)
  end

  local function compute_pos()
    local buf_row = m.start_l + node.y
    local top = get_top()
    local win_row = buf_row - top
    if win_row < 0 then win_row = 0 end
    local win_col = node.x + 1
    local width = math.max(node.w - 4, 1)
    local height = math.max(node.h - 2, 1)
    return win_row, win_col, width, height
  end

  local row, col, width, height = compute_pos()
  local edit_win = vim.api.nvim_open_win(edit_buf, true, {
    relative = "win",
    win = chart_win,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = true,
  })

  local group = vim.api.nvim_create_augroup("FlowchartEdit_" .. edit_buf, { clear = true })
  local closed = false

  local function sync()
    if closed or not vim.api.nvim_buf_is_valid(edit_buf) then return end
    local lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
    local label = table.concat(lines, "\n")
    set_node_label(m, node.id, label)
    flush(bufnr, m)
    local r, c, w, h = compute_pos()
    if vim.api.nvim_win_is_valid(edit_win) then
      pcall(vim.api.nvim_win_set_config, edit_win, {
        relative = "win",
        win = chart_win,
        row = r,
        col = c,
        width = w,
        height = h,
      })
    end
  end

  local function close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_clear_autocmds, { group = group })
    if vim.api.nvim_win_is_valid(edit_win) then
      vim.api.nvim_win_close(edit_win, true)
    end
    if vim.api.nvim_win_is_valid(chart_win) then
      vim.api.nvim_set_current_win(chart_win)
      vim.cmd("stopinsert")
      set_cursor_canvas(bufnr, m, node.x + 2, node.y + 1)
    end
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = edit_buf, callback = sync,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group, buffer = edit_buf, callback = close,
  })

  vim.keymap.set({ "n", "i" }, "<Esc>", close, { buffer = edit_buf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<C-c>", close, { buffer = edit_buf, nowait = true })

  local last_line = math.max(#init_lines, 1)
  local last_col = (init_lines[last_line] and #init_lines[last_line]) or 0
  vim.api.nvim_win_set_cursor(edit_win, { last_line, last_col })
  vim.cmd("startinsert!")
end

local function op_new_node(bufnr, m)
  local cx, cy = cursor_canvas_pos(m)
  local n = add_node(m, cx, cy, "")
  flush(bufnr, m)
  set_cursor_canvas(bufnr, m, n.x + 2, n.y + 1)
  open_edit_float(bufnr, m, n)
end

local function op_edit_node(bufnr, m)
  local cx, cy = cursor_canvas_pos(m)
  local n = node_at(m, cx, cy)
  if not n then return end
  open_edit_float(bufnr, m, n)
end

local function op_delete_node(bufnr, m)
  local cx, cy = cursor_canvas_pos(m)
  local n = node_at(m, cx, cy)
  if not n then return end
  del_node(m, n.id)
  if m.conn_pending == n.id then m.conn_pending = nil end
  flush(bufnr, m)
end

local function op_move_node(bufnr, m, dx, dy)
  local cx, cy = cursor_canvas_pos(m)
  local n = node_at(m, cx, cy)
  if not n then return end
  local nx = math.max(1, n.x + dx)
  local ny = math.max(1, n.y + dy)
  local rdx, rdy = nx - n.x, ny - n.y
  n.x, n.y = nx, ny
  flush(bufnr, m)
  set_cursor_canvas(bufnr, m, cx + rdx, cy + rdy)
end

local function op_connect(bufnr, m)
  local cx, cy = cursor_canvas_pos(m)
  local n = node_at(m, cx, cy)
  if not n then
    if m.conn_pending then
      m.conn_pending = nil
      msg("-- FLOWCHART -- (connect cancelled)")
    end
    return
  end
  if not m.conn_pending then
    m.conn_pending = n.id
    msg("-- FLOWCHART -- (connect: pick target node, c again to confirm)")
  else
    if m.conn_pending ~= n.id then
      add_edge(m, m.conn_pending, n.id)
      flush(bufnr, m)
    end
    m.conn_pending = nil
    msg("-- FLOWCHART --")
  end
end

local KEYS = { "n", "i", "a", "<CR>", "dd", "c", "H", "J", "K", "L", "<Esc>" }

local function set_keys(bufnr, m)
  local nmap = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  nmap("n", function() op_new_node(bufnr, m) end)
  nmap("i", function() op_edit_node(bufnr, m) end)
  nmap("a", function() op_edit_node(bufnr, m) end)
  nmap("<CR>", function() op_edit_node(bufnr, m) end)
  nmap("dd", function() op_delete_node(bufnr, m) end)
  nmap("c", function() op_connect(bufnr, m) end)
  nmap("H", function() op_move_node(bufnr, m, -1, 0) end)
  nmap("J", function() op_move_node(bufnr, m, 0, 1) end)
  nmap("K", function() op_move_node(bufnr, m, 0, -1) end)
  nmap("L", function() op_move_node(bufnr, m, 1, 0) end)
  nmap("<Esc>", function() M.exit(bufnr) end)
end

local function unset_keys(bufnr)
  for _, lhs in ipairs(KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
end

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state[bufnr] then return end
  local lnum = vim.fn.line(".")
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local start_l
  if cur_line:match("^%s*$") then
    start_l = lnum
  else
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { "" })
    start_l = lnum + 1
    vim.api.nvim_win_set_cursor(0, { start_l, 0 })
  end
  local m = new_model(start_l)
  state[bufnr] = m
  m.saved_ve = vim.wo.virtualedit
  vim.wo.virtualedit = "all"
  set_keys(bufnr, m)
  msg("-- FLOWCHART --  n:new+edit  i:edit  dd:delete  c:connect  HJKL:move  <Esc>:exit")
end

function M.exit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local m = state[bufnr]
  if not m then return end
  if m.end_l >= m.start_l then
    local lines = vim.api.nvim_buf_get_lines(bufnr, m.start_l - 1, m.end_l, false)
    for i, l in ipairs(lines) do lines[i] = (l:gsub("%s+$", "")) end
    vim.api.nvim_buf_set_lines(bufnr, m.start_l - 1, m.end_l, false, lines)
  end
  vim.wo.virtualedit = m.saved_ve or ""
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

function M.status() return M.is_active() and "FLOW" or "" end

function M.lualine_component()
  return {
    function() return M.status() end,
    cond = M.is_active,
    color = { fg = "#1a1b26", bg = "#bb9af7", gui = "bold" },
  }
end

function M.setup(opts)
  opts = opts or {}
  vim.api.nvim_create_user_command("Flowchart", M.toggle, {})
  if opts.keymap then
    vim.keymap.set("n", opts.keymap, M.toggle, { desc = "Toggle flowchart mode" })
  end
end

M._internal = {
  new_model = new_model,
  add_node = add_node,
  add_edge = add_edge,
  render_lines = render_lines,
  route_edge = route_edge,
  draw_box = draw_box,
}

return M
