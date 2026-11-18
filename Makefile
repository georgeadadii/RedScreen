PROJECT := RedScreen.xcodeproj
SCHEME := RedScreen
CONFIGURATION ?= Debug
DERIVED_DATA := $(CURDIR)/.build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/RedScreen.app
FIXTURE_DIR := $(CURDIR)/RedScreenCoreTests/Fixtures
FIXTURE_SUPPORT := RedScreenCoreTests/FixtureSupport
FIXTURE_GENERATOR := $(CURDIR)/.build/fixture-generator/fixture-generator

.PHONY: build run test install clean fixtures

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

run: build
	open -n "$(APP)"

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		test

install:
	$(MAKE) build CONFIGURATION=Release
	/usr/bin/ditto "$(DERIVED_DATA)/Build/Products/Release/RedScreen.app" \
		/Applications/RedScreen.app

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean

# Regenerates the synthetic screenshot corpus. The generator runs with an empty environment under
# Tools/FixtureGenerator/generator.sb: no network, no reads beneath $(HOME), writes only to
# $(FIXTURE_DIR). Commit the regenerated files together with the scenario change.
fixtures:
	mkdir -p "$(dir $(FIXTURE_GENERATOR))"
	xcrun swiftc -swift-version 6 -O -o "$(FIXTURE_GENERATOR)" \
		Tools/FixtureGenerator/main.swift \
		$(FIXTURE_SUPPORT)/FixtureSchema.swift \
		$(FIXTURE_SUPPORT)/FixtureScenarios.swift \
		$(FIXTURE_SUPPORT)/FixtureRenderer.swift
	rm -rf "$(FIXTURE_DIR)"
	mkdir -p "$(FIXTURE_DIR)"
	/usr/bin/env -i /usr/bin/sandbox-exec -f Tools/FixtureGenerator/generator.sb \
		-D HOME_DIR="$(HOME)" \
		-D OUTPUT_DIR="$(FIXTURE_DIR)" \
		-D GENERATOR="$(FIXTURE_GENERATOR)" \
		"$(FIXTURE_GENERATOR)" "$(FIXTURE_DIR)"
