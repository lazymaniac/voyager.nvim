local voyager = require("voyager")
assert(type(voyager.setup) == "function")
for _, command in ipairs({
  "VoyagerOpen",
  "VoyagerFocus",
  "VoyagerSave",
  "VoyagerLoad",
  "VoyagerClose",
  "VoyagerBuild",
  "VoyagerBuildCancel",
}) do
  assert(vim.fn.exists(":" .. command) == 2, command .. " is not registered")
end
vim.cmd("qa!")
