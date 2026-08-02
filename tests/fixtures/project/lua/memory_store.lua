local function save(value)
  return "memory:" .. value
end

return { save = save }
