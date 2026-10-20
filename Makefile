SCHEME := ClipboardMemory
DERIVED := build
DEBUG_APP := $(DERIVED)/Build/Products/Debug/$(SCHEME).app
RELEASE_APP := $(DERIVED)/Build/Products/Release/$(SCHEME).app
DESTINATION := platform=macOS,arch=arm64

.PHONY: generate run test install

generate:
	xcodegen generate

run: generate
	xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) build
	-killall $(SCHEME)
	open $(DEBUG_APP)

test: generate
	xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) test

install: generate
	xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) build
	rm -rf /Applications/$(SCHEME).app
	cp -R $(RELEASE_APP) /Applications/$(SCHEME).app
