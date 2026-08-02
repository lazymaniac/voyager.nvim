-- Intentionally unformatted: the emoji must precede the symbol on the next line.
local marker = "😀"; local function save(value)
  return marker .. ":mysql:" .. value
end

return { save = save }
