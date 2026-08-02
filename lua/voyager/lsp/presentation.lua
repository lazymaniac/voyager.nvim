local M = {}
local Presentation = {}
Presentation.__index = Presentation

local function eligible_window(winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  if vim.api.nvim_win_get_config(winid).relative ~= "" then
    return false
  end
  return vim.bo[vim.api.nvim_win_get_buf(winid)].buftype ~= "quickfix"
end

local function target_buffer(item)
  if type(item.bufnr) == "number" and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
    return item.bufnr
  end
  if type(item.filename) == "string" and item.filename ~= "" then
    local bufnr = vim.fn.bufadd(item.filename)
    local ok = pcall(vim.fn.bufload, bufnr)
    if ok and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
  end
end

local function voyager_tag(item)
  return type(item) == "table"
      and type(item.user_data) == "table"
      and type(item.user_data.voyager) == "table"
      and item.user_data.voyager
    or nil
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager presentation options are required")
  return setmetatable({
    _navigation = vim.deepcopy(opts.navigation),
    _resolve_node = opts.resolve_node,
    _choose_window = opts.choose_window,
    _set_current = opts.set_current,
    _notify = opts.notify,
    _presentation_token = 0,
  }, Presentation)
end

function Presentation:_begin(context)
  self._presentation_token = self._presentation_token + 1
  self._generation = context.generation
  self._request_token = context.request_token
  self._observer = nil
  return self._presentation_token
end

function Presentation:_list_items(context, items)
  local result = {}
  for _, item in ipairs(items) do
    local list_item = vim.deepcopy(item.list_item)
    local user_data = vim.deepcopy(item.raw)
    if type(user_data) ~= "table" then
      user_data = { value = user_data }
    end
    user_data.voyager = {
      generation = context.generation,
      request_token = context.request_token,
      node_id = item.node_id,
    }
    list_item.user_data = user_data
    table.insert(result, list_item)
  end
  return result
end

function Presentation:_reuse_window(base_winid, bufnr)
  if not self._navigation.reuse_win or vim.api.nvim_win_get_buf(base_winid) == bufnr then
    return base_winid
  end
  local tabpage = vim.api.nvim_win_get_tabpage(base_winid)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if
      eligible_window(winid)
      and vim.api.nvim_win_get_tabpage(winid) == tabpage
      and vim.api.nvim_win_get_buf(winid) == bufnr
    then
      return winid
    end
  end
  return base_winid
end

function Presentation:_jump(context, item, node_id)
  local base_winid = self._choose_window()
  if not eligible_window(base_winid) then
    return false
  end
  local bufnr = target_buffer(item)
  if not bufnr then
    self._notify("Voyager: could not open the selected target", vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_win_call(base_winid, function()
    vim.cmd("normal! m'")
  end)
  vim.fn.settagstack(base_winid, {
    items = { { tagname = context.tagname, from = vim.deepcopy(context.from) } },
  }, "t")

  local jump_winid = self:_reuse_window(base_winid, bufnr)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_set_current_win(jump_winid)
  vim.api.nvim_win_set_buf(jump_winid, bufnr)
  vim.api.nvim_win_set_cursor(jump_winid, { item.lnum, item.col - 1 })
  vim.api.nvim_win_call(jump_winid, function()
    vim.cmd("normal! zv")
  end)
  self._set_current(node_id)
  return true
end

function Presentation:_custom_select(context, presentation_token, item)
  if
    presentation_token ~= self._presentation_token
    or context.generation ~= self._generation
    or context.request_token ~= self._request_token
  then
    return false
  end
  local tag = voyager_tag(item)
  if
    not tag
    or tag.generation ~= context.generation
    or tag.request_token ~= context.request_token
    or type(tag.node_id) ~= "string"
  then
    return false
  end
  local node = self._resolve_node(tag.node_id)
  if not node then
    return false
  end
  return self:_jump(context, item, tag.node_id)
end

function Presentation:_open_list(context, action, list_items, presentation_token)
  local list_opts = {
    title = action.label,
    items = list_items,
    context = { bufnr = context.bufnr, method = action.method },
  }
  local kind
  local owner_winid
  local info
  if self._navigation.loclist then
    owner_winid = eligible_window(context.winid) and context.winid or self._choose_window()
    if not eligible_window(owner_winid) then
      return false
    end
    vim.fn.setloclist(owner_winid, {}, " ", list_opts)
    vim.api.nvim_win_call(owner_winid, function()
      vim.cmd("lopen")
    end)
    info = vim.fn.getloclist(owner_winid, { id = 0 })
    kind = "loclist"
  else
    vim.fn.setqflist({}, " ", list_opts)
    vim.cmd("botright copen")
    info = vim.fn.getqflist({ id = 0 })
    kind = "quickfix"
  end
  self._observer = {
    kind = kind,
    owner_winid = owner_winid,
    list_id = info.id,
    generation = context.generation,
    request_token = context.request_token,
    presentation_token = presentation_token,
  }
  return true
end

function Presentation:present(context, items, action)
  local presentation_token = self:_begin(context)
  if #items == 0 then
    return
  end
  local list_items = self:_list_items(context, items)
  if vim.is_callable(self._navigation.on_list) then
    local list = {
      title = action.label,
      items = list_items,
      context = { bufnr = context.bufnr, method = action.method },
    }
    self._navigation.on_list(list, function(item)
      return self:_custom_select(context, presentation_token, item)
    end)
    return
  end

  if action.presentation == "always_list" or #list_items > 1 then
    self:_open_list(context, action, list_items, presentation_token)
    return
  end
  self:_jump(context, list_items[1], voyager_tag(list_items[1]).node_id)
end

function Presentation:_active_list()
  local observer = self._observer
  if not observer then
    return nil
  end
  if
    observer.presentation_token ~= self._presentation_token
    or observer.generation ~= self._generation
    or observer.request_token ~= self._request_token
  then
    return nil
  end
  if observer.kind == "loclist" then
    if not vim.api.nvim_win_is_valid(observer.owner_winid) then
      return nil
    end
    return vim.fn.getloclist(observer.owner_winid, { id = 0, idx = 0, items = 0 })
  end
  return vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
end

function Presentation:on_cursor_moved(winid)
  if not eligible_window(winid) then
    return
  end
  local observer = self._observer
  local list = self:_active_list()
  if not observer or not list or list.id ~= observer.list_id or type(list.items) ~= "table" then
    return
  end
  local item = list.items[list.idx]
  local tag = voyager_tag(item)
  if
    not tag
    or tag.generation ~= observer.generation
    or tag.request_token ~= observer.request_token
    or type(tag.node_id) ~= "string"
  then
    return
  end
  local node = self._resolve_node(tag.node_id)
  local location = type(node) == "table" and (node.location or node) or nil
  if type(location) ~= "table" or type(location.range) ~= "table" then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local bufnr = item.bufnr
  if (type(bufnr) ~= "number" or bufnr <= 0) and type(item.filename) == "string" then
    bufnr = vim.fn.bufnr(item.filename)
  end
  if
    vim.api.nvim_win_get_buf(winid) ~= bufnr
    or cursor[1] ~= location.range.start.line + 1
    or cursor[2] ~= location.range.start.character
    or item.lnum ~= location.range.start.line + 1
    or item.col - 1 ~= location.range.start.character
  then
    return
  end
  self._observer = nil
  self._set_current(tag.node_id)
end

function Presentation:invalidate()
  self._presentation_token = self._presentation_token + 1
  self._generation = nil
  self._request_token = nil
  self._observer = nil
end

return M
