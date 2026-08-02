-- Intentionally unformatted: the emoji must precede `save` on the same line.
local marker = "😀"; local function save(value)
  return marker .. ":mysql:" .. value
end

return { save = save }
