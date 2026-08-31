.PHONY: help doctor setup install-format-tools format-tools-status format format-check lint install-debug-cli uninstall-debug-cli debug-cli-status codex-acquire codex-status codex-update-candidate resolve build run test guardrails codex-schema-check provider-conformance m7-backend-certification m8-live-certification conductor-selftest ci-app-test-runner-selftest release-selftest release-sync-cli-version release-preflight release-artifact install-local-production xcode xcode-open xcode-generate xcode-check xcode-validate xcode-rust-link-validate xcode-generator-test xcode-clean dev-status dev-build dev-swift-build dev-cargo-build dev-cargo-test dev-cargo-codegen dev-cargo-codegen-check dev-cargo-archive dev-cargo-deny dev-cargo-audit dev-cargo-fuzz dev-rust-ffi-swift-baseline-export dev-rust-ffi-swift-baseline-check dev-rust-ffi-swift-baseline-measure dev-rust-ffi-swift-baseline-candidate dev-rust-search-phase-profile dev-run dev-launch-existing dev-codex-schema-check dev-provider-conformance dev-m7-backend-certification dev-m8-live-certification dev-test dev-provider-test dev-smoke dev-smoke-launch dev-format dev-format-check dev-lint dev-format-tools-status dev-check-format-tools dev-install-format-tools dev-release-preflight dev-release-artifact dev-install-local-production dev-stop-app dev-daemon-stop clean

PRODUCT ?= all
CODEX_ARCH ?= all
PROFILE ?= debug
CARGO_PACKAGE ?= all
FUZZ_TARGET ?= envelope_decode
FUZZ_SECONDS ?= 60
FIXTURE ?=
PROCESS_RUNS ?= 3
M8_ARGS ?=

help:
	@printf '%s\n' 'Usage: make <target>'
	@printf '\n%s\n' 'Common targets:'
	@printf '  %-30s %s\n' 'doctor' 'Verify local Swift/Xcode setup and diagnostics'
	@printf '  %-30s %s\n' 'setup' 'Install format tools, run doctor, and resolve packages'
	@printf '  %-30s %s\n' 'build' 'Build and package the debug app'
	@printf '  %-30s %s\n' 'run' 'Build, package, and launch the debug app'
	@printf '  %-30s %s\n' 'test' 'Run the Swift test suite'
	@printf '  %-30s %s\n' 'guardrails' 'Run source layout and repository guardrails'
	@printf '  %-30s %s\n' 'codex-schema-check' 'Validate bounded app-server assumptions against generated Codex schemas'
	@printf '  %-30s %s\n' 'provider-conformance' 'Validate offline P7-4 provider capability contract'
	@printf '  %-30s %s\n' 'm7-backend-certification' 'Validate M7 backend cutover and release evidence gate'
	@printf '  %-30s %s\n' 'm8-live-certification' 'Run M8 live provider, backend, sleep/wake, and signed-artifact gates'
	@printf '  %-30s %s\n' 'clean' 'Remove .build'
	@printf '\n%s\n' 'Coordinated developer daemon targets:'
	@printf '  %-30s %s\n' 'dev-status' 'Show conductor daemon status'
	@printf '  %-30s %s\n' 'dev-build' 'Coordinated debug app package build'
	@printf '  %-30s %s\n' 'dev-swift-build' 'Coordinated Swift build; PRODUCT=Agentry|agentry-mcp|all'
	@printf '  %-30s %s\n' 'dev-cargo-build' 'Coordinated Cargo workspace build; PROFILE=debug|release'
	@printf '  %-30s %s\n' 'dev-cargo-test' 'Coordinated Cargo tests; CARGO_PACKAGE=proto|runtime|ffi|all'
	@printf '  %-30s %s\n' 'dev-cargo-codegen-check' 'Coordinated deterministic UniFFI generation check'
	@printf '  %-30s %s\n' 'dev-cargo-archive' 'Coordinated staged static archive; PROFILE=debug|release'
	@printf '  %-30s %s\n' 'dev-cargo-deny' 'Coordinated Cargo dependency/license policy check'
	@printf '  %-30s %s\n' 'dev-cargo-audit' 'Coordinated Cargo advisory audit'
	@printf '  %-30s %s\n' 'dev-cargo-fuzz' 'Coordinated bounded fuzz smoke; FUZZ_TARGET=envelope_decode FUZZ_SECONDS=1..300'
	@printf '  %-38s %s\n' 'dev-rust-ffi-swift-baseline-export' 'Export canonical pre-P1 Swift fixtures from the release test binary'
	@printf '  %-38s %s\n' 'dev-rust-ffi-swift-baseline-check' 'Regenerate pre-P1 Swift fixtures twice and verify committed bytes'
	@printf '  %-38s %s\n' 'dev-rust-ffi-swift-baseline-measure' 'Measure pre-P1 Swift fixtures in the release test binary'
	@printf '  %-38s %s\n' 'dev-rust-ffi-swift-baseline-candidate' 'Measure Rust search candidate and enforce the frozen SLO gate'
	@printf '  %-38s %s\n' 'dev-rust-search-phase-profile' 'Profile Rust search phases; FIXTURE=representative-* PROCESS_RUNS=N'
	@printf '  %-30s %s\n' 'dev-run' 'Coordinated debug app build and launch'
	@printf '  %-30s %s\n' 'dev-launch-existing' 'Launch existing coordinated debug app without building'
	@printf '  %-30s %s\n' 'dev-codex-schema-check' 'Coordinated Codex app-server schema validation'
	@printf '  %-30s %s\n' 'dev-provider-conformance' 'Coordinated offline P7-4 provider certification contract validation'
	@printf '  %-30s %s\n' 'dev-m7-backend-certification' 'Coordinated M7 backend/release evidence gate'
	@printf '  %-30s %s\n' 'dev-m8-live-certification' 'Coordinated M8 live certification; pass M8_ARGS="--live" to attempt operational gates'
	@printf '  %-30s %s\n' 'dev-test' 'Coordinated test run; override with FILTER=name'
	@printf '  %-30s %s\n' 'dev-provider-test' 'Run provider package tests; override with FILTER=name'
	@printf '  %-30s %s\n' 'dev-smoke' 'Run non-disruptive live debug app smoke checks'
	@printf '  %-30s %s\n' 'dev-smoke-launch' 'Launch debug app, then run smoke checks'
	@printf '  %-30s %s\n' 'dev-stop-app' 'Stop the coordinated debug app'
	@printf '  %-30s %s\n' 'dev-daemon-stop' 'Stop the conductor daemon'
	@printf '\n%s\n' 'Style targets:'
	@printf '  %-30s %s\n' 'format' 'Format Swift files directly'
	@printf '  %-30s %s\n' 'format-check' 'Check Swift formatting directly'
	@printf '  %-30s %s\n' 'lint' 'Run direct format-check and SwiftLint'
	@printf '  %-30s %s\n' 'dev-format' 'Coordinated Swift formatting'
	@printf '  %-30s %s\n' 'dev-format-check' 'Coordinated Swift formatting check'
	@printf '  %-30s %s\n' 'dev-lint' 'Coordinated format-check and SwiftLint'
	@printf '  %-30s %s\n' 'install-format-tools' 'Install SwiftFormat and SwiftLint'
	@printf '  %-30s %s\n' 'format-tools-status' 'Show direct format tool status'
	@printf '  %-30s %s\n' 'dev-install-format-tools' 'Coordinated format tool install'
	@printf '  %-30s %s\n' 'dev-format-tools-status' 'Show coordinated format tool status'
	@printf '  %-30s %s\n' 'dev-check-format-tools' 'Check coordinated format tool availability'
	@printf '\n%s\n' 'Debug CLI targets:'
	@printf '  %-30s %s\n' 'install-debug-cli' 'Build and install the Agentry debug CLI'
	@printf '  %-30s %s\n' 'uninstall-debug-cli' 'Uninstall the Agentry debug CLI'
	@printf '  %-30s %s\n' 'debug-cli-status' 'Show Agentry debug CLI status'
	@printf '  %-30s %s\n' 'codex-acquire' 'Acquire and verify pinned Codex package(s); override with CODEX_ARCH=host|arm64|x86_64'
	@printf '  %-30s %s\n' 'codex-status' 'Verify cached pinned Codex packages without network access'
	@printf '  %-30s %s\n' 'codex-update-candidate' 'Prepare review-only stable Codex update evidence; set one CODEX_CANDIDATE selector'
	@printf '\n%s\n' 'Xcode workspace targets:'
	@printf '  %-30s %s\n' 'xcode' 'Generate and open the disposable Xcode workspace'
	@printf '  %-30s %s\n' 'xcode-generate' 'Generate the disposable Xcode workspace'
	@printf '  %-30s %s\n' 'xcode-check' 'Check generated Xcode workspace state'
	@printf '  %-30s %s\n' 'xcode-validate' 'Full Xcode workspace validation, including xcodebuild -list'
	@printf '  %-30s %s\n' 'xcode-rust-link-validate' 'Coordinated arm64 Rust bridge build-for-testing; never launches the app'
	@printf '  %-30s %s\n' 'xcode-generator-test' 'Run Xcode workspace generator tests'
	@printf '  %-30s %s\n' 'xcode-clean' 'Remove generated Xcode workspace metadata'
	@printf '\n%s\n' 'Release targets:'
	@printf '  %-30s %s\n' 'release-preflight' 'Run release preflight directly'
	@printf '  %-30s %s\n' 'release-artifact' 'Build release artifact directly'
	@printf '  %-30s %s\n' 'install-local-production' 'Install a local production app'
	@printf '  %-30s %s\n' 'dev-release-preflight' 'Coordinated release preflight'
	@printf '  %-30s %s\n' 'dev-release-artifact' 'Coordinated release artifact build'
	@printf '  %-30s %s\n' 'dev-install-local-production' 'Coordinated local production install'
	@printf '\n%s\n' 'Internal/test targets:'
	@printf '  %-30s %s\n' 'resolve' 'Resolve Swift packages'
	@printf '  %-30s %s\n' 'conductor-selftest' 'Run conductor/tooling self-tests'
	@printf '  %-30s %s\n' 'ci-app-test-runner-selftest' 'Run hosted CI app-test runner self-tests'
	@printf '  %-30s %s\n' 'release-selftest' 'Run release tooling self-tests'
	@printf '  %-30s %s\n' 'release-sync-cli-version' 'Sync CLI version for release tooling'

doctor:
	./Scripts/doctor.sh

setup:
	./Scripts/install_format_tools.sh install
	./Scripts/doctor.sh
	swift package resolve

install-format-tools:
	./Scripts/install_format_tools.sh install

format-tools-status:
	./Scripts/install_format_tools.sh status

format:
	./Scripts/swift_style.sh format

format-check:
	./Scripts/swift_style.sh format-check

lint:
	./Scripts/swift_style.sh lint

install-debug-cli:
	./Scripts/install_debug_cli.sh install --build

uninstall-debug-cli:
	./Scripts/install_debug_cli.sh uninstall

debug-cli-status:
	./Scripts/install_debug_cli.sh status

codex-acquire:
	python3 Scripts/codex_runtime_artifact.py acquire --arch $(CODEX_ARCH) --cache-root "$${REPOPROMPT_CODEX_CACHE_ROOT:-.build/codex-runtime}"

codex-status:
	python3 Scripts/codex_runtime_artifact.py status --cache-root "$${REPOPROMPT_CODEX_CACHE_ROOT:-.build/codex-runtime}"

codex-update-candidate:
	@set --; count=0; \
	if [ -n "$(CODEX_CANDIDATE_VERSION)" ]; then count=$$((count + 1)); set -- "$$@" --version "$(CODEX_CANDIDATE_VERSION)"; fi; \
	if [ -n "$(CODEX_CANDIDATE_TAG)" ]; then count=$$((count + 1)); set -- "$$@" --tag "$(CODEX_CANDIDATE_TAG)"; fi; \
	if [ "$(CODEX_CANDIDATE_LATEST)" = "1" ]; then count=$$((count + 1)); set -- "$$@" --latest-stable; fi; \
	if [ "$$count" -ne 1 ]; then \
		echo "Set exactly one of CODEX_CANDIDATE_VERSION=X.Y.Z, CODEX_CANDIDATE_TAG=rust-vX.Y.Z, or CODEX_CANDIDATE_LATEST=1" >&2; \
		exit 1; \
	fi; \
	python3 Scripts/codex_update_candidate.py "$$@"

resolve:
	swift package resolve

build:
	./Scripts/package_app.sh debug

run:
	./Scripts/run.sh

test:
	swift build --build-tests
	./Scripts/stage_test_frameworks.sh
	swift test

guardrails:
	./Scripts/guardrails.sh

codex-schema-check:
	python3 Scripts/check_codex_app_server_schema.py

provider-conformance:
	python3 Scripts/validate_rust_agent_provider_p7_4.py --check

m7-backend-certification:
	Scripts/m7_backend_certification.sh

m8-live-certification:
	Scripts/m8_live_certification.sh $(M8_ARGS)

conductor-selftest:
	python3 Scripts/test_codex_app_server_schema.py
	python3 Scripts/test_validate_rust_agent_provider_p7_4.py
	python3 Scripts/test_validate_m7_backend_release.py
	python3 Scripts/test_validate_m8_live_evidence.py
	python3 Scripts/test_debug_app_process.py
	python3 Scripts/test_contribution_preflight.py
	python3 Scripts/test_ci_app_test_runner.py
	python3 Scripts/test_conductor_cache.py
	python3 Scripts/test_conductor_output.py
	python3 Scripts/test_conductor_diagnostics.py
	python3 Scripts/test_conductor_high_output.py
	python3 Scripts/test_agent_mode_file_tools_benchmark.py
	python3 Scripts/test_conductor_lifecycle.py
	python3 Scripts/test_local_production_installer.py
	python3 Scripts/test_security_inventory.py

ci-app-test-runner-selftest:
	python3 Scripts/test_ci_app_test_runner.py

release-selftest:
	python3 Scripts/test_release_promotion.py
	python3 Scripts/test_release_tooling.py
	python3 Scripts/test_codex_runtime_artifact.py
	python3 Scripts/test_codex_update_candidate.py
	python3 Scripts/test_codex_update_workflow.py

release-sync-cli-version:
	./Scripts/release.sh sync-cli-version

release-preflight:
	./Scripts/release.sh preflight

release-artifact:
	./Scripts/release.sh artifact

install-local-production:
	./Scripts/install_local_production.sh

xcode: xcode-open

xcode-open: xcode-generate
	open "$$(python3 Scripts/generate_xcode_workspace.py print-path)"

xcode-generate:
	python3 Scripts/generate_xcode_workspace.py generate

xcode-check:
	python3 Scripts/generate_xcode_workspace.py check

xcode-validate: xcode-generate
	python3 Scripts/generate_xcode_workspace.py validate --xcodebuild-list

xcode-rust-link-validate:
	./conductor xcode-rust-link-validate

xcode-generator-test:
	python3 Scripts/test_xcode_workspace_generator.py

xcode-clean:
	rm -rf .build/xcode .build/xcode-custom

dev-status:
	./conductor status

dev-build:
	./conductor build

dev-swift-build:
	./conductor swift-build --product $(PRODUCT)

dev-cargo-build:
	./conductor cargo-build --profile $(PROFILE)

dev-cargo-test:
	./conductor cargo-test --package $(CARGO_PACKAGE)

dev-cargo-codegen:
	./conductor cargo-codegen

dev-cargo-codegen-check:
	./conductor cargo-codegen --check

dev-cargo-archive:
	./conductor cargo-archive --profile $(PROFILE)

dev-cargo-deny:
	./conductor cargo-deny

dev-cargo-audit:
	./conductor cargo-audit

dev-cargo-fuzz:
	./conductor cargo-fuzz --target $(FUZZ_TARGET) --seconds $(FUZZ_SECONDS)

dev-rust-ffi-swift-baseline-export:
	./conductor rust-ffi-swift-baseline-export

dev-rust-ffi-swift-baseline-check:
	./conductor rust-ffi-swift-baseline-check

dev-rust-ffi-swift-baseline-measure:
	./conductor rust-ffi-swift-baseline-measure

dev-rust-ffi-swift-baseline-candidate:
	./conductor rust-ffi-swift-baseline-candidate

dev-rust-search-phase-profile:
	./conductor rust-search-phase-profile$(if $(FIXTURE), --fixture $(FIXTURE)) --process-runs $(PROCESS_RUNS)

dev-run:
	./conductor run

dev-launch-existing:
	./conductor app launch-existing

dev-codex-schema-check:
	./conductor codex-schema-check

dev-provider-conformance:
	./conductor provider-conformance

dev-m7-backend-certification:
	./conductor m7-backend-certification

dev-m8-live-certification:
	./conductor m8-live-certification $(M8_ARGS)

dev-test:
	@./Scripts/stage_test_frameworks.sh
	./conductor test$(if $(TEST_PRODUCT), --test-product $(TEST_PRODUCT))$(if $(FILTER), --filter $(FILTER))$(if $(CONFIGURATION), --configuration $(CONFIGURATION))$(if $(SANITIZE), --sanitize $(SANITIZE))

dev-provider-test:
	./conductor provider-test$(if $(TEST_PRODUCT), --test-product $(TEST_PRODUCT))$(if $(FILTER), --filter $(FILTER))

dev-smoke:
	./conductor smoke

dev-smoke-launch:
	./conductor smoke --launch

dev-format:
	./conductor format

dev-format-check:
	./conductor format-check

dev-lint:
	./conductor lint

dev-format-tools-status:
	./conductor format-tools-status

dev-check-format-tools:
	./conductor check-format-tools

dev-install-format-tools:
	./conductor install-format-tools

dev-release-preflight:
	./conductor release preflight

dev-release-artifact:
	./conductor release artifact

dev-install-local-production:
	./conductor release local-install

dev-stop-app:
	./conductor app stop

dev-daemon-stop:
	./conductor daemon stop

clean:
	rm -rf .build
