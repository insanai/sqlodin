.PHONY: check-network python-test python-build all deps native build test check vet sim bench bench-linux bench-durable-linux check-durability docs example clean help

ODIN ?= odin
CLI = bin/sqlodin
NATIVE_ARCHIVES = build/native/libsqlite3.a build/native/libsqlite_vec.a build/native/libssl.a build/native/libcrypto.a
DURABILITY_REPORT ?= benchmarks/results/linux-candidate-v3-durability.json
REALWORLD_REPORT ?= benchmarks/results/linux-realworld-current.json

all: build

deps:
	git submodule update --init --recursive

# macOS and Linux use verified project-local static archives.
native:
	python3 tools/build_native.py

bench-linux:
	python3 tools/benchmark.py --output benchmarks/results/linux-latest.json

bench-durable-linux:
	python3 tools/compare_realworld.py --output $(REALWORLD_REPORT) --durability-report $(DURABILITY_REPORT)
	python3 tools/inspect_benchmark_storage.py $(REALWORLD_REPORT)

check-durability:
	python3 tools/check_durability.py --output $(DURABILITY_REPORT)

# The submodule gitlink pins the whole library; never update to a floating branch here.
deps/paxos-odin/src/paxos.odin:
	git submodule update --init --recursive

$(NATIVE_ARCHIVES): native
	@test -f $@

$(CLI): $(NATIVE_ARCHIVES) $(wildcard cli/*.odin service/*.odin transport/mtls/*.odin src/durable/*.odin src/*.odin src/sqlite/*.odin deps/paxos-odin/src/*.odin) Makefile tools/build_cli.py tools/build_native.py tools/build_shell.py internal/shell/local.c tools/native_sources.json | deps/paxos-odin/src/paxos.odin native
	@mkdir -p bin
	ODIN="$(ODIN)" python3 tools/build_cli.py --output $(CLI)

build: $(CLI)
	@./$(CLI) build all

test: $(CLI)
	@./$(CLI) test

vet: deps/paxos-odin/src/paxos.odin native
	@python3 tools/check_style.py --soft
	@$(ODIN) check tests -vet -strict-style -no-entry-point
	@for p in sim bench cli internal/durability_probe internal/process_probe bench/realworld; do $(ODIN) check $$p -vet -strict-style || exit 1; done
	@$(ODIN) check examples/multimaster_search.odin -file -vet -strict-style

check: deps/paxos-odin/src/paxos.odin native
	@ODIN="$(ODIN)" python3 tools/check.py

sim: $(CLI)
	@./$(CLI) sim --seed=42 --steps=2000

bench: $(CLI)
	@./$(CLI) bench

docs: $(CLI)
	@./$(CLI) docs all

example: deps/paxos-odin/src/paxos.odin native
	@$(ODIN) run examples/multimaster_search.odin -file

clean:
	rm -rf bin/ docs/build/

help:
	@echo "SQLodin build targets:"
	@echo "  make build         Build the library, simulator, benchmark, and CLI into bin/"
	@echo "  make test          Run the test suite (odin test tests)"
	@echo "  make vet           Zen constraints and -vet -strict-style on every package"
	@echo "  make check         Full verification: style, tests in both profiles, contracts, fault matrix, smoke runs"
	@echo "  make sim           Run seeded chaos simulation"
	@echo "  make bench         Run multi-master write and sqlite-vec/FTS5 benchmark"
	@echo "  make docs          Compile the architectural book and SOD records to PDF via Typst"
	@echo "  make example       Run the 3-node multi-master vector/FTS search demo"
	@echo "  make clean         Remove built binaries and generated PDF documents"

# Native service tests need loopback sockets and OpenSSL 3.
check-network: $(CLI)
	python3 tools/check_network_service.py --output build/network-service-check.json

python-test:
	cd languages/python && uv sync --extra test && uv run pytest

python-build:
	cd languages/python && uv build
