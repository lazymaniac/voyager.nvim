NVIM ?= nvim
STYLUA ?= stylua
ROOT := $(abspath .)
DEPS := $(ROOT)/.deps
PLENARY := $(DEPS)/plenary.nvim
NUI := $(DEPS)/nui.nvim
PLENARY_REV := 50012918b2fc8357b87cff2a7f7f0446e47da174
NUI_REV := f535005e6ad1016383f24e39559833759453564e
STYLUA_VERSION := 2.5.2
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

.PHONY: deps check-deps check-stylua test test-unit test-e2e format format-check

deps:
	@scripts/ensure-dependency install plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency install nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)

check-deps:
	@scripts/ensure-dependency check plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency check nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)

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
