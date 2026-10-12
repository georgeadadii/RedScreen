PROJECT := RedScreen.xcodeproj
SCHEME := RedScreen
CONFIGURATION ?= Debug
DERIVED_DATA := $(CURDIR)/.build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/RedScreen.app

.PHONY: build run test install clean

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
