-- Classic Font Awesome codepoints; present in every Nerd Fonts patched font.
local nerd_icons = {
  definition = "\u{f05b}",
  declaration = "\u{f024}",
  references = "\u{f0c1}",
  implementation = "\u{f085}",
  type_definition = "\u{f02b}",
  incoming_calls = "\u{f090}",
  outgoing_calls = "\u{f08b}",
  manual = "\u{f124}",
  current = "●",
  stale = "\u{f071}",
  note = "\u{f040}",
  collapsed = "▸",
  expanded = "▾",
}

local text_icons = {
  definition = "",
  declaration = "",
  references = "",
  implementation = "",
  type_definition = "",
  incoming_calls = "",
  outgoing_calls = "",
  manual = "",
  current = "●",
  stale = "!",
  note = "✎",
  collapsed = "▸",
  expanded = "▾",
}

local icon_keys = {}
for key in pairs(nerd_icons) do
  icon_keys[key] = true
end

local defaults = {
  sidebar = { width = 42, side = "right", border = "rounded", icons = true },
  navigation = { timeout_ms = 10000 },
  sidebar_keymaps = {
    jump_or_toggle = "<CR>",
    note = "n",
    save = "s",
    load = "L",
    toggle = "za",
    close = { "q", "<Esc>" },
  },
  storage = { resolve_uri = nil },
}

local known = {
  sidebar = { width = true, side = true, border = true, icons = true },
  navigation = { timeout_ms = true },
  sidebar_keymaps = {
    jump_or_toggle = true,
    note = true,
    save = true,
    load = true,
    toggle = true,
    close = true,
  },
  storage = { resolve_uri = true },
}

local borders = { none = true, single = true, double = true, rounded = true, solid = true, shadow = true }

local function fail(path, message)
  error("voyager.setup: " .. path .. " " .. message, 0)
end

local function validate_lhs(path, value, allow_list)
  if value == false then
    return {}
  end
  local values = allow_list and type(value) == "table" and value or { value }
  if allow_list and type(value) == "table" and #value == 0 then
    fail(path, "must not be an empty list")
  end
  for _, lhs in ipairs(values) do
    local ok, normalized = false, nil
    if type(lhs) == "string" then
      ok, normalized = pcall(vim.keycode, lhs)
    end
    if not ok or lhs == "" or normalized == "" then
      fail(path, "must be false or a non-empty normal-mode LHS")
    end
  end
  return values
end

local function reject_unknown(scope, supplied, allowed)
  for key in pairs(supplied or {}) do
    if allowed[key] == nil then
      fail(scope .. "." .. tostring(key), "is not a supported option")
    end
  end
end

local M = {}

function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then
    fail("opts", "must be a table")
  end
  opts = opts or {}
  reject_unknown("opts", opts, known)
  for section, supplied in pairs(opts) do
    if type(supplied) ~= "table" then
      fail(section, "must be a table")
    end
    reject_unknown(section, supplied, known[section])
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for key, value in pairs(opts.sidebar_keymaps or {}) do
    result.sidebar_keymaps[key] = vim.deepcopy(value)
  end

  if type(result.sidebar.width) ~= "number" or result.sidebar.width % 1 ~= 0 or result.sidebar.width < 20 then
    fail("sidebar.width", "must be an integer of at least 20")
  end
  if result.sidebar.side ~= "left" and result.sidebar.side ~= "right" then
    fail("sidebar.side", "must be 'left' or 'right'")
  end
  if not borders[result.sidebar.border] then
    fail("sidebar.border", "must be a supported NUI border")
  end
  local icons = result.sidebar.icons
  if icons == true then
    result.sidebar.icons = vim.deepcopy(nerd_icons)
  elseif icons == false then
    result.sidebar.icons = vim.deepcopy(text_icons)
  elseif type(icons) == "table" then
    reject_unknown("sidebar.icons", icons, icon_keys)
    local merged = vim.deepcopy(nerd_icons)
    for key, value in pairs(icons) do
      if type(value) ~= "string" then
        fail("sidebar.icons." .. tostring(key), "must be a string")
      end
      merged[key] = value
    end
    result.sidebar.icons = merged
  else
    fail("sidebar.icons", "must be true, false, or a table of icon overrides")
  end
  local timeout = result.navigation.timeout_ms
  if type(timeout) ~= "number" or timeout % 1 ~= 0 or timeout < 100 or timeout > 120000 then
    fail("navigation.timeout_ms", "must be an integer from 100 through 120000")
  end
  if result.storage.resolve_uri ~= nil and not vim.is_callable(result.storage.resolve_uri) then
    fail("storage.resolve_uri", "must be callable or nil")
  end

  local seen = {}
  for key, value in pairs(result.sidebar_keymaps) do
    for _, lhs in ipairs(validate_lhs("sidebar_keymaps." .. key, value, true)) do
      local normalized = vim.keycode(lhs)
      if seen[normalized] then
        fail("sidebar_keymaps", "contains duplicate normalized LHS '" .. lhs .. "'")
      end
      seen[normalized] = true
    end
  end
  return vim.deepcopy(result)
end

return M
