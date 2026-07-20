# Ace — Arch Linux Compatible Package Manager
# https://github.com/yourorg/ace

V        ?= v
OUT      ?= ace
VFLAGS   ?=
PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
DOCDIR   ?= $(PREFIX)/share/doc/ace
VPROD    ?= -prod
VERSION  ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)

.PHONY: all build test clean run fmt vet rebuild install uninstall release fixtures compat bench

all: build

build:
	$(V) main.v $(VFLAGS) -enable-globals -o $(OUT)

test:
	$(V) -enable-globals test . $(VFLAGS)
	$(V) -enable-globals test config/ $(VFLAGS)
	$(V) -enable-globals test cli/ $(VFLAGS)
	$(V) -enable-globals test db/ $(VFLAGS)
	$(V) -enable-globals test trans/ $(VFLAGS)
	$(V) -enable-globals test util/ $(VFLAGS)
	$(V) -enable-globals test archive/ $(VFLAGS)
	$(V) -enable-globals test lib/ $(VFLAGS)

fixtures:
	@echo "Generating test fixtures..."
	$(V) -enable-globals run tests/fixtures/gen_fixtures.v

compat: build
	@echo "Running compat checks..."
	$(V) run tests/compat/run_compat.v

bench:
	@echo "Running benchmarks..."
	$(V) -enable-globals run tests/bench/run_benchmarks.v

clean:
	rm -f $(OUT)
	rm -rf tests/fixtures/output

run: build
	./$(OUT)

fmt:
	$(V) fmt -w . $(VFLAGS)

vet:
	$(V) vet . $(VFLAGS)

rebuild: clean build

install: build
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(OUT) $(DESTDIR)$(BINDIR)/$(OUT)
	install -d $(DESTDIR)$(DOCDIR)
	install -m 0644 README.md $(DESTDIR)$(DOCDIR)/README.md
	install -m 0644 ARCHITECTURE.md $(DESTDIR)$(DOCDIR)/ARCHITECTURE.md
	install -m 0644 CONTRIBUTING.md $(DESTDIR)$(DOCDIR)/CONTRIBUTING.md

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(OUT)
	rm -rf $(DESTDIR)$(DOCDIR)

release:
	$(V) main.v $(VFLAGS) -enable-globals -o $(OUT) -prod
	mkdir -p releases
	tar -czf releases/ace-$(VERSION)-linux-x86_64.tar.gz ace
	@echo "release: releases/ace-$(VERSION)-linux-x86_64.tar.gz"
