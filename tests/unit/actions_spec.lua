local Actions = require("voyager.lsp.actions")

describe("Voyager LSP actions", function()
  it("defines the native methods in stable order", function()
    assert.same({
      "definition",
      "declaration",
      "references",
      "implementation",
      "type_definition",
      "incoming_calls",
      "outgoing_calls",
    }, Actions.names())
    assert.same("textDocument/declaration", Actions.get("declaration").method)
    assert.same({ includeDeclaration = true }, Actions.get("references").context)
    assert.same("incoming", Actions.get("incoming_calls").direction)
    assert.same("outgoing", Actions.get("outgoing_calls").direction)
    assert.same("above", Actions.get("references").placement)
    assert.same("above", Actions.get("incoming_calls").placement)
    assert.is_nil(Actions.get("definition").placement)
    assert.is_nil(Actions.get("outgoing_calls").placement)
    local internal_name, internal = Actions.by_method("voyager/manual")
    assert.equals("manual", internal_name)
    assert.equals("manual jump", internal.label)
    assert.is_true(internal.internal)
    local archive_name, archive = Actions.by_method("voyager/archive")
    assert.equals("archive", archive_name)
    assert.equals("archived records", archive.label)
    assert.is_true(archive.internal)
    assert.is_true(archive.storage)
  end)
end)
