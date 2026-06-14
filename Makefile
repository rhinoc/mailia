APP_SERVER_MANIFEST := $(CURDIR)/mailia-mail/Cargo.toml
APP_SERVER_BIN := $(CURDIR)/mailia-mail/target/debug/mailia-mail
SWIFT_PRODUCT ?= Mailia

.PHONY: dev dev-cli app-server swift-build rust-check rust-test test

dev: app-server
	MAILIA_APP_SERVER_PATH="$(APP_SERVER_BIN)" swift run $(SWIFT_PRODUCT)

dev-cli:
	MAILIA_DISABLE_APP_SERVER=1 swift run $(SWIFT_PRODUCT)

app-server:
	cargo build --manifest-path "$(APP_SERVER_MANIFEST)" --bin mailia-mail

swift-build:
	swift build --product $(SWIFT_PRODUCT)

rust-check:
	cargo check --manifest-path "$(APP_SERVER_MANIFEST)"

rust-test:
	cargo test --manifest-path "$(APP_SERVER_MANIFEST)"

test: rust-test
	swift test
