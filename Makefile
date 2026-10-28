PREFIX ?= /usr/local
BUILD := .build
SWIFTC := swiftc
FLAGS := -target $(shell uname -m)-apple-macos13 -swift-version 5

# Masks a stale usr/include/swift/module.modulemap that some Command Line Tools
# upgrades leave behind ("redefinition of module 'SwiftBridging'").
# Harmless on healthy toolchains; disable with `make CLT_FIX=`.
CLT_STALE := /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
CLT_FIX ?= $(if $(wildcard $(CLT_STALE)),-vfsoverlay $(BUILD)/clt-fix.yaml,)

LIB_SOURCES := $(wildcard Sources/EMLKit/*.swift)

.PHONY: all build test install uninstall clean fixtures

all: build

build: $(BUILD)/eml2pdf

$(BUILD)/eml2pdf: $(LIB_SOURCES) Sources/eml2pdf/main.swift | $(BUILD)/clt-fix.yaml
	$(SWIFTC) -O $(FLAGS) $(CLT_FIX) $^ -o $@

$(BUILD)/run-tests: $(LIB_SOURCES) Tests/main.swift | $(BUILD)/clt-fix.yaml
	$(SWIFTC) $(FLAGS) $(CLT_FIX) $^ -o $@

test: $(BUILD)/run-tests
	$(BUILD)/run-tests Tests/Fixtures

fixtures:
	python3 Tests/make_fixtures.py

$(BUILD)/clt-fix.yaml:
	@mkdir -p $(BUILD)
	@: > $(BUILD)/empty.modulemap
	@printf '{"version":0,"case-sensitive":"false","roots":[{"name":"%s","type":"directory","contents":[{"name":"module.modulemap","type":"file","external-contents":"%s"}]}]}\n' \
		"$(dir $(CLT_STALE))" "$(abspath $(BUILD))/empty.modulemap" > $@

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD)/eml2pdf $(PREFIX)/bin/eml2pdf

uninstall:
	rm -f $(PREFIX)/bin/eml2pdf

clean:
	rm -rf $(BUILD)
