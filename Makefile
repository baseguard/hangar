# xcodebuild needs Xcode, and xcode-select may point at the Command Line Tools.
ifeq ($(findstring Xcode,$(shell xcode-select -p)),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

export PATH := $(HOME)/.cargo/bin:$(PATH)
export HANGAR_AGENT_VERSION := $(shell sed -n 's/.*agentVersion = //p' Sources/HangarKit/Guest/GuestSetup.swift)

SIGN_IDENTITY ?= -

.PHONY: agents build dmg test dev efi bench format lint

# The agent's panic messages name its source files: mapped, they carry no home folder or checkout path. rustc takes
# the last mapping that matches, so the home folder goes first; cfg(all()) adds to each target's own flags.
CARGO_FOLDER := $(or $(CARGO_HOME),$(HOME)/.cargo)
RUSTUP_FOLDER := $(or $(RUSTUP_HOME),$(HOME)/.rustup)
AGENT_PATHS := --config 'target.'"'"'cfg(all())'"'"'.rustflags = ["--remap-path-prefix=$(HOME)=/home", \
	"--remap-path-prefix=$(CARGO_FOLDER)=/cargo", "--remap-path-prefix=$(RUSTUP_FOLDER)=/rustup", \
	"--remap-path-prefix=$(CURDIR)=/hangar"]'

agents:
	cd guest-agent && cargo audit --deny warnings
	cd guest-agent && cargo zigbuild --release --locked $(AGENT_PATHS) --target aarch64-unknown-linux-gnu.2.31
	cd guest-agent && cargo zigbuild --release --locked $(AGENT_PATHS) --target aarch64-pc-windows-gnullvm
	cd guest-agent && cargo build --release --locked $(AGENT_PATHS) --target aarch64-apple-darwin
	mkdir -p Resources/Guest/linux Resources/Guest/windows Resources/Guest/macos
	install -m 755 guest-agent/target/aarch64-unknown-linux-gnu/release/hangar-agent Resources/Guest/linux/hangar-agent
	install -m 755 guest-agent/target/aarch64-pc-windows-gnullvm/release/hangar-agent.exe Resources/Guest/windows/hangar-agent.exe
	install -m 755 guest-agent/target/aarch64-apple-darwin/release/hangar-agent Resources/Guest/macos/hangar-agent
	codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)" Resources/Guest/macos/hangar-agent

build: agents
	scripts/build.sh

dmg:
	packaging/dmg/make-dmg.sh

# The release workflow runs the tests before it imports the signing certificate.
test: SIGN_IDENTITY := -
test: agents
	xcodebuild -project Hangar.xcodeproj -scheme Hangar -destination 'platform=macOS' \
		-derivedDataPath .build/test -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test

dev: agents
	xcodebuild -project Hangar.xcodeproj -scheme Hangar -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates \
		-derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile -quiet build
	@echo "Built .build/xcode/Build/Products/Debug/Hangar.app"

efi:
	scripts/build-efi.sh

bench:
	scripts/bench-traffic.sh

format:
	xcrun swift format --recursive --parallel --in-place --configuration .swift-format Sources Tests packaging/dmg

lint:
	xcrun swift format lint --recursive --parallel --strict --configuration .swift-format Sources Tests packaging/dmg
