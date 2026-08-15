NVIM ?= nvim
STYLUA ?= stylua
CONTAINER ?= docker
LUAROCKS ?= luarocks
GO ?= go
ROOT := $(abspath .)
DEPS := $(ROOT)/.deps
PLENARY := $(DEPS)/plenary.nvim
NUI := $(DEPS)/nui.nvim
PANVIMDOC := $(DEPS)/panvimdoc
PLENARY_REV := 50012918b2fc8357b87cff2a7f7f0446e47da174
NUI_REV := f535005e6ad1016383f24e39559833759453564e
PANVIMDOC_REV := 662fb20304d20c539fb48a0bda628f5165507de7
STYLUA_VERSION := 2.5.2
DOC_DATE := 2026 August 01
LUAROCKS_VERSION := 3.13.0
ROCKSPEC := voyager.nvim-scm-1.rockspec
ROCK_BUILD_OUTPUT := $(ROOT)/voyager.nvim-scm-1.all.rock
ROCK_ARTIFACT_DIR := $(ROOT)/.tmp/artifacts
ROCK_FILE := $(ROCK_ARTIFACT_DIR)/voyager.nvim-scm-1.all.rock
ROCK_TREE := $(ROOT)/.tmp/rocks
ACTIONLINT_VERSION := 1.7.12
ACTIONLINT_REV := 914e7df21a07ef503a81201c76d2b11c789d3fca
ACTIONLINT_DIR := $(ROOT)/.tmp/tools/actionlint-$(ACTIONLINT_REV)
ACTIONLINT_BIN := $(ACTIONLINT_DIR)/actionlint
TEST_ENV := env VOYAGER_TEST_ROOT=$(ROOT) NVIM_APPNAME=voyager-test XDG_CONFIG_HOME=$(ROOT)/.tmp/test/config XDG_CACHE_HOME=$(ROOT)/.tmp/test/cache XDG_STATE_HOME=$(ROOT)/.tmp/test/state XDG_DATA_HOME=$(ROOT)/.tmp/test/data
TEST_NVIM := $(TEST_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/minimal_init.lua
E2E_PROJECT := $(ROOT)/.tmp/e2e-project
E2E_SAVE_ROOT := $(ROOT)/.tmp/e2e-save
E2E_LOAD_ROOT := $(ROOT)/.tmp/e2e-load
E2E_SAVE_ENV := env VOYAGER_TEST_ROOT=$(ROOT) VOYAGER_E2E_ROOT=$(E2E_PROJECT) NVIM_APPNAME=voyager-e2e-save XDG_CONFIG_HOME=$(E2E_SAVE_ROOT)/config XDG_CACHE_HOME=$(E2E_SAVE_ROOT)/cache XDG_STATE_HOME=$(E2E_SAVE_ROOT)/state XDG_DATA_HOME=$(E2E_SAVE_ROOT)/data
E2E_LOAD_ENV := env VOYAGER_TEST_ROOT=$(ROOT) VOYAGER_E2E_ROOT=$(E2E_PROJECT) NVIM_APPNAME=voyager-e2e-load XDG_CONFIG_HOME=$(E2E_LOAD_ROOT)/config XDG_CACHE_HOME=$(E2E_LOAD_ROOT)/cache XDG_STATE_HOME=$(E2E_LOAD_ROOT)/state XDG_DATA_HOME=$(E2E_LOAD_ROOT)/data

ifeq ($(strip $(TEST_FILE)),)
UNIT_COMMAND := PlenaryBustedDirectory tests/unit { minimal_init = 'tests/minimal_init.lua' }
else
UNIT_COMMAND := lua require('tests.run_file')('$(TEST_FILE)')
endif

.PHONY: deps check-deps check-stylua check-luarocks check-actionlint test test-unit test-e2e format format-check docs help-check rock rock-smoke workflow-lint

deps:
	@scripts/ensure-dependency install plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency install nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)
	@scripts/ensure-dependency install panvimdoc https://github.com/kdheepak/panvimdoc.git $(PANVIMDOC_REV) $(PANVIMDOC)

check-deps:
	@scripts/ensure-dependency check plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency check nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)
	@scripts/ensure-dependency check panvimdoc https://github.com/kdheepak/panvimdoc.git $(PANVIMDOC_REV) $(PANVIMDOC)

test: test-unit test-e2e

test-unit: check-deps
	@$(TEST_NVIM) -c "$(UNIT_COMMAND)"

test-e2e: check-deps
	@test "$(E2E_PROJECT)" = "$(ROOT)/.tmp/e2e-project"
	@test "$(E2E_SAVE_ROOT)" = "$(ROOT)/.tmp/e2e-save"
	@test "$(E2E_LOAD_ROOT)" = "$(ROOT)/.tmp/e2e-load"
	@rm -rf "$(E2E_PROJECT)" "$(E2E_SAVE_ROOT)" "$(E2E_LOAD_ROOT)"
	@mkdir -p "$(E2E_PROJECT)"
	@cp -R tests/fixtures/project/. "$(E2E_PROJECT)/"
	@$(E2E_SAVE_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/e2e/minimal_init.lua -c "lua require('plenary.busted').run('tests/e2e/save_phase_spec.lua')"
	@$(E2E_LOAD_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/e2e/minimal_init.lua -c "lua require('plenary.busted').run('tests/e2e/load_phase_spec.lua')"

check-stylua:
	@command -v $(STYLUA) >/dev/null 2>&1 || { echo "StyleLua $(STYLUA_VERSION) is required" >&2; exit 1; }
	@actual="$$($(STYLUA) --version)"; test "$$actual" = "stylua $(STYLUA_VERSION)" || { echo "expected stylua $(STYLUA_VERSION), got $$actual" >&2; exit 1; }

format: check-stylua
	@$(STYLUA) lua plugin tests

format-check: check-stylua
	@$(STYLUA) --check lua plugin tests

docs: check-deps
	@$(CONTAINER) build -t voyager-panvimdoc:4.0.1 $(PANVIMDOC)
	@$(CONTAINER) run --rm -v $(ROOT):/work -w /work voyager-panvimdoc:4.0.1 --project-name voyager --input-file README.md --vim-version "Neovim 0.12.4" --toc true --description "Persistent flat LSP relationship flows" --title-date-pattern "$(DOC_DATE)" --dedup-subheadings true --demojify true --treesitter true --ignore-rawblocks true --doc-mapping false --doc-mapping-project-name true --shift-heading-level-by 0 --increment-heading-level-by 0

help-check:
	@$(MAKE) docs
	@$(NVIM) --headless -u NONE -i NONE -c "helptags doc" -c "qa!"
	@git diff --exit-code -- doc/voyager.txt doc/tags

check-luarocks:
	@command -v $(LUAROCKS) >/dev/null 2>&1 || { echo "LuaRocks $(LUAROCKS_VERSION) is required" >&2; exit 1; }
	@actual="$$($(LUAROCKS) --version | awk 'NR == 1 { print $$NF }')"; test "$$actual" = "$(LUAROCKS_VERSION)" || { echo "expected LuaRocks $(LUAROCKS_VERSION), got $$actual" >&2; exit 1; }

rock: check-luarocks
	@test "$(ROCK_BUILD_OUTPUT)" = "$(ROOT)/voyager.nvim-scm-1.all.rock"
	@rm -f "$(ROCK_BUILD_OUTPUT)"
	@mkdir -p "$(ROCK_ARTIFACT_DIR)"
	@$(LUAROCKS) make --pack-binary-rock --deps-mode=none "$(ROCKSPEC)"
	@test -f "$(ROCK_BUILD_OUTPUT)"
	@mv "$(ROCK_BUILD_OUTPUT)" "$(ROCK_FILE)"

rock-smoke: rock
	@test "$(ROCK_TREE)" = "$(ROOT)/.tmp/rocks"
	@rm -rf "$(ROCK_TREE)"
	@mkdir -p "$(ROCK_TREE)"
	@$(LUAROCKS) --tree "$(ROCK_TREE)" install nui.nvim 0.4.0-1
	@$(LUAROCKS) --tree "$(ROCK_TREE)" install "$(ROCK_FILE)" --deps-mode=none
	@rock_dir="$$($(LUAROCKS) --tree "$(ROCK_TREE)" show --rock-dir voyager.nvim scm-1)"; \
	  test -n "$$rock_dir"; \
	  lua_path="$$($(LUAROCKS) --tree "$(ROCK_TREE)" path --lr-path)"; \
	  lua_cpath="$$($(LUAROCKS) --tree "$(ROCK_TREE)" path --lr-cpath)"; \
	  VOYAGER_ROCK_DIR="$$rock_dir" LUA_PATH="$$lua_path;;" LUA_CPATH="$$lua_cpath;;" \
	  $(NVIM) --headless --noplugin -u NONE -i NONE \
	    --cmd 'execute "set runtimepath^=" .. fnameescape($$VOYAGER_ROCK_DIR)' \
	    -c "runtime plugin/voyager.lua" -l tests/smoke/installed.lua

$(ACTIONLINT_BIN):
	@command -v $(GO) >/dev/null 2>&1 || { echo "Go is required to install actionlint $(ACTIONLINT_VERSION)" >&2; exit 1; }
	@mkdir -p "$(ACTIONLINT_DIR)"
	@GOBIN="$(ACTIONLINT_DIR)" $(GO) install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_REV)

check-actionlint: $(ACTIONLINT_BIN)
	@actual="$$($(ACTIONLINT_BIN) -version | sed -n '1s/^v//p')"; test "$$actual" = "$(ACTIONLINT_VERSION)" || { echo "expected actionlint $(ACTIONLINT_VERSION), got $$actual" >&2; exit 1; }

workflow-lint: check-actionlint
	@$(ACTIONLINT_BIN) .github/workflows/*.yml
