PROJECT := AhaKey Studio.xcodeproj
DERIVED_DATA := $(CURDIR)/DerivedData

.PHONY: build debug test install
build:
	./scripts/build.sh

debug:
	./scripts/build-debug.sh

test:
	xcodebuild -project "$(PROJECT)" -scheme "AhaKey Studio" -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" test

install:
	INSTALL_TO_APPLICATIONS=1 LAUNCH_AFTER_INSTALL=1 ./scripts/build.sh
