.PHONY: all build run test clean open regen lint

SCHEME = aibars
PROJECT = aibars.xcodeproj
DERIVED = ~/Library/Developer/Xcode/DerivedData/aibars-*/Build/Products/Debug/aibars.app

all: build

regen:
	xcodegen generate

build: regen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' build

run: build
	@APP=$$(ls -d $(DERIVED) 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then echo "no built app found"; exit 1; fi; \
	open "$$APP"

test: regen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test

clean:
	rm -rf $(PROJECT) build *.xcworkspace
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true

open: regen
	open $(PROJECT)
