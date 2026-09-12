local raw_path = vim.env.ANNOTATE_RAW
local reply_path = vim.env.ANNOTATE_REPLY

local cancelled = false
local reply_buf = nil

vim.o.swapfile = false
vim.o.mouse = "a"
vim.o.laststatus = 0
vim.o.autowriteall = true

local f = assert(io.open(raw_path, "rb"))
local raw = f:read("*a")
f:close()

local function apply_sgr(attrs, params)
  local parts = vim.split(params:gsub(":", ";"), ";", { plain = true })
  local i = 1
  while i <= #parts do
    local n = tonumber(parts[i]) or 0
    if n == 0 then
      attrs = {}
    elseif n == 1 then
      attrs.bold = true
    elseif n == 3 then
      attrs.italic = true
    elseif n == 4 then
      attrs.underline = true
    elseif n == 22 then
      attrs.bold = nil
    elseif n == 23 then
      attrs.italic = nil
    elseif n == 24 then
      attrs.underline = nil
    elseif n >= 30 and n <= 37 then
      attrs.fg = n - 30
    elseif n == 39 then
      attrs.fg = nil
    elseif n >= 40 and n <= 47 then
      attrs.bg = n - 40
    elseif n == 49 then
      attrs.bg = nil
    elseif n >= 90 and n <= 97 then
      attrs.fg = n - 90 + 8
    elseif n >= 100 and n <= 107 then
      attrs.bg = n - 100 + 8
    elseif n == 38 or n == 48 then
      local key = n == 38 and "fg" or "bg"
      if parts[i + 1] == "2" then
        attrs[key] = string.format(
          "#%02x%02x%02x",
          tonumber(parts[i + 2]) or 0,
          tonumber(parts[i + 3]) or 0,
          tonumber(parts[i + 4]) or 0
        )
        i = i + 4
      elseif parts[i + 1] == "5" then
        attrs[key] = tonumber(parts[i + 2]) or 0
        i = i + 2
      end
    end
    i = i + 1
  end
  return attrs
end

local function color_val(c)
  if type(c) == "string" then
    return c
  end
  if type(c) == "number" and c < 16 then
    return vim.g["terminal_color_" .. c]
  end
  return nil
end

local hl_cache = {}
local function hl_for(attrs)
  if not next(attrs) then
    return nil
  end
  local key = table.concat({
    tostring(attrs.fg or ""),
    tostring(attrs.bg or ""),
    attrs.bold and "b" or "",
    attrs.italic and "i" or "",
    attrs.underline and "u" or "",
  }, "_")
  if not hl_cache[key] then
    local name = "AnnThread" .. key:gsub("[^%w]", "x")
    vim.api.nvim_set_hl(0, name, {
      fg = color_val(attrs.fg),
      bg = color_val(attrs.bg),
      bold = attrs.bold or false,
      italic = attrs.italic or false,
      underline = attrs.underline or false,
    })
    hl_cache[key] = name
  end
  return hl_cache[key]
end

raw = raw:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\27]*\27\\", ""):gsub("\r\n", "\n"):gsub("\r", "")
local text_lines = {}
local line_spans = {}
local attrs = {}
for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
  local out = {}
  local byte = 0
  local spans = {}
  local pos = 1
  while true do
    local s, e, params, final = line:find("\27%[([%d;:]*)(%a)", pos)
    local chunk = line:sub(pos, s and s - 1 or #line)
    chunk = chunk:gsub("[%c\27]", "")
    if #chunk > 0 then
      out[#out + 1] = chunk
      local group = hl_for(attrs)
      if group then
        spans[#spans + 1] = { byte, byte + #chunk, group }
      end
      byte = byte + #chunk
    end
    if not s then
      break
    end
    if final == "m" then
      attrs = apply_sgr(attrs, params)
    end
    pos = e + 1
  end
  text_lines[#text_lines + 1] = table.concat(out)
  line_spans[#line_spans + 1] = spans
end

local thread = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(thread)
vim.api.nvim_buf_set_lines(thread, 0, -1, false, text_lines)
local ns = vim.api.nvim_create_namespace("annotate_thread")
for row, spans in ipairs(line_spans) do
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(thread, ns, row - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
  end
end
vim.bo[thread].modifiable = false

local function scrub_win(win)
  if win == -1 then
    return
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = false
  vim.wo[win].breakindent = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].colorcolumn = ""
  vim.wo[win].fillchars = "eob: "
end
scrub_win(vim.api.nvim_get_current_win())
vim.cmd("normal! G")

local HINTS = "a annotate line · v/V/mouse + a/⏎ selection · Tab switch · q/:qa quit&send · :Cancel discard"

local function thread_win()
  return vim.fn.bufwinid(thread)
end

local function reply_win()
  if reply_buf and vim.api.nvim_buf_is_valid(reply_buf) then
    return vim.fn.bufwinid(reply_buf)
  end
  return -1
end

local function hide_chrome()
  vim.o.mouse = "a"
  for _, lhs in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    pcall(vim.keymap.del, { "n", "i", "v", "x" }, lhs)
  end
  pcall(function()
    require("lualine").hide()
  end)
  vim.o.laststatus = 0
end

vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "laststatus",
  callback = function()
    if vim.o.laststatus ~= 0 then
      vim.schedule(function()
        vim.o.laststatus = 0
      end)
    end
  end,
})

local function prewarm_markdown()
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(reply_path, ":h") .. "/.warmup.md")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.bo[buf].filetype = "markdown"
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function ensure_reply()
  local win = reply_win()
  if win ~= -1 then
    return win
  end
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("topleft 10split " .. vim.fn.fnameescape(reply_path))
  reply_buf = vim.api.nvim_get_current_buf()
  vim.bo[reply_buf].filetype = "markdown"
  vim.bo[reply_buf].swapfile = false
  win = vim.api.nvim_get_current_win()
  vim.wo[win].winbar = "REPLY · " .. HINTS
  vim.keymap.set("n", "<Tab>", function()
    local tw = thread_win()
    if tw ~= -1 then
      vim.api.nvim_set_current_win(tw)
    end
  end, { buffer = reply_buf })
  hide_chrome()
  vim.api.nvim_set_current_win(cur)
  return win
end

local function annotate_lines(lines)
  if #lines == 0 then
    return
  end
  local win = ensure_reply()
  local content = vim.api.nvim_buf_get_lines(reply_buf, 0, -1, false)
  while #content > 0 and content[#content]:match("^%s*$") do
    table.remove(content)
  end
  if #content > 0 then
    content[#content + 1] = ""
  end
  for _, l in ipairs(lines) do
    content[#content + 1] = ("> " .. l):gsub("%s+$", "")
  end
  content[#content + 1] = ""
  content[#content + 1] = ""
  vim.api.nvim_buf_set_lines(reply_buf, 0, -1, false, content)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { #content, 0 })
  vim.cmd("startinsert")
end

local function annotate_selection()
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  annotate_lines(lines)
end

local function annotate_line()
  annotate_lines({ vim.api.nvim_get_current_line() })
end

local function flush()
  if cancelled then
    return
  end
  if reply_buf and vim.api.nvim_buf_is_valid(reply_buf) then
    vim.api.nvim_buf_call(reply_buf, function()
      vim.cmd("silent! write! " .. vim.fn.fnameescape(reply_path))
    end)
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = flush })
vim.api.nvim_create_user_command("Cancel", function()
  cancelled = true
  os.remove(reply_path)
  vim.cmd("qa!")
end, { range = true })
vim.api.nvim_create_user_command("Send", function()
  flush()
  vim.cmd("qa!")
end, { range = true })

local function unshadow(mode, lhs)
  local prefix = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local umbrella = mode == "x" and "v" or mode
  for _, m in ipairs(vim.fn.maplist()) do
    local applies = m.buffer == 0
      and (m.mode == " " or m.mode:find(mode, 1, true) or m.mode:find(umbrella, 1, true))
    if applies then
      local other = m.lhsraw or vim.api.nvim_replace_termcodes(m.lhs, true, false, true)
      if #other > #prefix and other:sub(1, #prefix) == prefix then
        pcall(vim.keymap.del, mode, m.lhs)
      end
    end
  end
end

local function unshadow_triggers()
  unshadow("x", "a")
  unshadow("x", "<CR>")
  unshadow("n", "a")
end

vim.keymap.set("x", "a", annotate_selection, { buffer = thread })
vim.keymap.set("x", "<CR>", annotate_selection, { buffer = thread })
vim.keymap.set("n", "a", annotate_line, { buffer = thread })
unshadow_triggers()
vim.keymap.set("n", "q", "<Cmd>qa<CR>", { buffer = thread })
vim.keymap.set("n", "<Tab>", function()
  vim.api.nvim_set_current_win(ensure_reply())
end, { buffer = thread })

vim.wo.winbar = "THREAD · " .. HINTS
hide_chrome()

local selected_path = vim.env.ANNOTATE_SELECTED
if selected_path and selected_path ~= "" then
  local sf = io.open(selected_path, "rb")
  if sf then
    local selected = sf:read("*a"):gsub("%s+$", "")
    sf:close()
    if selected ~= "" then
      annotate_lines(vim.split(selected, "\n", { plain = true }))
    end
  end
end

vim.defer_fn(function()
  hide_chrome()
  prewarm_markdown()
  unshadow_triggers()
  local tw = thread_win()
  if tw ~= -1 then
    scrub_win(tw)
    vim.wo[tw].winbar = "THREAD · " .. HINTS
    vim.api.nvim_win_call(tw, function()
      vim.cmd("normal! G")
    end)
  end
end, 200)

vim.defer_fn(function()
  hide_chrome()
  unshadow_triggers()
  scrub_win(thread_win())
end, 1500)
