.PHONY: all build test check vet sim bench docs example clean help

ODIN ?= odin
CLI = bin/sqlodin

all: build

$(CLI): $(wildcard cli/*.odin) Makefile
	@mkdir -p bin
	$(ODIN) build cli -out:$(CLI) -o:speed

build: $(CLI)
	@./$(CLI) build all

test: $(CLI)
	@./$(CLI) test

vet:
	@python3 tools/check_style.py --soft
	@$(ODIN) check tests -vet -strict-style -no-entry-point
	@for p in sim bench cli; do $(ODIN) check $$p -vet -strict-style || exit 1; done
	@$(ODIN) check examples/multimaster_search.odin -file -vet -strict-style

check:
	@ODIN="$(ODIN)" python3 tools/check.py

sim: $(CLI)
	@./$(CLI) sim --seed=42 --steps=2000

bench: $(CLI)
	@./$(CLI) bench

docs: $(CLI)
	@./$(CLI) docs all

example:
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
