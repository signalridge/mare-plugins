lint:
    stylua --check plugins types tests
    python3 tests/manifests.py
    python3 tests/test_manifests.py
    python3 tests/test_ci_workflow.py
    lua tests/service-contracts.lua
    python3 scripts/lua_api_rules.py --self-test
    python3 tests/test_lua_api_rules.py
    python3 scripts/lua_api_rules.py

specs:
    ./tests/run-specs.sh

test:
    #!/usr/bin/env bash
    set -euo pipefail
    skip_summary="$(mktemp "${TMPDIR:-/tmp}/mare-e2e-skips.XXXXXX")"
    trap 'rm -f "$skip_summary"' EXIT
    export MARE_E2E_SKIP_SUMMARY="$skip_summary"
    python3 tests/manifests.py
    python3 tests/test_manifests.py
    python3 tests/test_ci_workflow.py
    lua tests/service-contracts.lua
    python3 scripts/lua_api_rules.py --self-test
    python3 tests/test_lua_api_rules.py
    python3 scripts/lua_api_rules.py
    ./tests/run-specs.sh
    ./tests/run-e2e-step.sh ./tests/e2e-todo.sh
    ./tests/run-e2e-step.sh ./tests/e2e-ask-user-question.sh
    ./tests/run-e2e-step.sh ./tests/e2e-plan-mode.sh
    ./tests/run-e2e-step.sh python3 tests/e2e-plan-gate-rpc.py
    ./tests/run-e2e-step.sh python3 tests/e2e-plan-mode-rpc.py
    ./tests/run-e2e-step.sh ./tests/e2e-session-title.sh
    ./tests/run-e2e-step.sh python3 tests/e2e-themes.py
    ./tests/run-e2e-step.sh ./tests/e2e-hooks.sh
    ./tests/run-e2e-step.sh ./tests/e2e-hooks-events.sh
    ./tests/run-e2e-step.sh ./tests/e2e-hooks-input.sh
    ./tests/run-e2e-step.sh ./tests/e2e-hooks-parity.sh
    ./tests/run-e2e-step.sh ./tests/e2e-time-context.sh
    ./tests/run-e2e-step.sh python3 tests/e2e-peers.py
    ./tests/run-e2e-step.sh ./tests/e2e-mermaid.sh
    ./tests/run-e2e-step.sh ./tests/e2e-presets.sh
    ./tests/run-e2e-step.sh ./tests/e2e-presets-activation.sh
    ./tests/run-e2e-step.sh ./tests/e2e-btw.sh
    ./tests/run-e2e-step.sh ./tests/e2e-goal.sh
    ./tests/run-e2e-step.sh ./tests/e2e-secrets.sh
    ./tests/run-e2e-step.sh ./tests/e2e-session-search.sh
    ./tests/run-e2e-step.sh ./tests/e2e-spill.sh
    ./tests/run-e2e-step.sh ./tests/e2e-terminal.sh
    ./tests/run-e2e-step.sh python3 tests/terminal/model_e2e.py
    ./tests/run-e2e-step.sh python3 tests/terminal/tui_resize_e2e.py
    ./tests/run-e2e-step.sh ./tests/e2e-toolbelt.sh
    ./tests/run-e2e-step.sh ./tests/e2e-codemode.sh
    ./tests/run-e2e-step.sh ./tests/e2e-web.sh
    ./tests/run-e2e-step.sh ./tests/e2e-schedule-domain.sh
    ./tests/run-e2e-step.sh ./tests/e2e-schedule.sh
    ./tests/run-e2e-step.sh ./tests/e2e-workflow.sh
    ./tests/run-e2e-step.sh ./tests/e2e-team.sh
    ./tests/run-e2e-step.sh python3 tests/e2e-service-contracts.py
    ./tests/run-e2e-step.sh --print-summary "$skip_summary"
