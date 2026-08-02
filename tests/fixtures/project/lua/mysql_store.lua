-- stylua: ignore
local marker = "😀"; local function save(value)
  return marker .. ":mysql:" .. value
end

return { save = save }
