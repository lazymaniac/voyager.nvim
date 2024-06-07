---@class LspUtils
---Utils for lsp related stuff
local LspUtils = {}

LspUtils.pretty_lsp_method = function(lsp_method)
  if lsp_method == "textDocument/references" then
    return "Ref"
  elseif lsp_method == "textDocument/definition" then
    return "Def"
  elseif lsp_method == "textDocument/implementation" then
    return "Impl"
  elseif lsp_method == "textDocument/typeDefinition" then
    return "Type"
  elseif lsp_method == "callHierarchy/incomingCalls" then
    return "Inc"
  elseif lsp_method == "callHierarchy/outgoingCalls" then
    return "Out"
  end
end

return LspUtils
