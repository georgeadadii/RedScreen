PROJECT := RedScreen.xcodeproj
SCHEME := RedScreen
CONFIGURATION ?= Debug
DERIVED_DATA := $(CURDIR)/.build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/RedScreen.app
FIXTURE_DIR := $(CURDIR)/RedScreenCoreTests/Fixtures
FIXTURE_SUPPORT := RedScreenCoreTests/FixtureSupport
FIXTURE_GENERATOR := $(CURDIR)/.build/fixture-generator/fixture-generator

.PHONY: build run test test-core install clean fixtures

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

# Core suite for CI; the full test target also runs desktop UI automation.
test-core:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:RedScreenCoreTests \
		test

# Installs one stable copy in /Applications. Grant Screen Recording to this copy: development
# builds and test runs never replace it, so it keeps its permission until you reinstall (and,
# with a signing team in Config/Local.xcconfig, across reinstalls too).
INSTALLED_APP := /Applications/RedScreen.app

install:
	$(MAKE) build CONFIGURATION=Release
	@# Quit a running copy so the replaced app is the one that launches next.
	-@/usr/bin/pkill -x RedScreen && sleep 1 || true
	/bin/rm -rf "$(INSTALLED_APP)"
	/usr/bin/ditto "$(DERIVED_DATA)/Build/Products/Release/RedScreen.app" "$(INSTALLED_APP)"
	@/usr/bin/codesign -dv "$(INSTALLED_APP)" 2>&1 | /usr/bin/grep -E '^(Signature|TeamIdentifier)=' || true
	@echo "Installed $(INSTALLED_APP). Open it from there and allow Screen Recording for that copy."

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
