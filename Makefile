APP       := dist/MacTaskbar.app
BIN       := .build/release/MacTaskbar
BUNDLE_ID := io.github.cwbudde.mactaskbar
SUBSYSTEM := io.github.cwbudde.mactaskbar

# Sign with the stable "MacTaskbar Dev" identity (see `make dev-cert`) when present,
# so the Accessibility grant survives rebuilds; fall back to ad-hoc signing.
DEV_ID  := MacTaskbar Dev
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(DEV_ID)"' && echo "$(DEV_ID)" || echo -)

.PHONY: all build app run stop dump logs dev-cert reset-permission clean

all: app

build:
	swift build -c release

app: build
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/MacTaskbar
	cp Resources/Info.plist $(APP)/Contents/Info.plist
ifeq ($(SIGN_ID),-)
	@echo "warning: signing ad-hoc; the Accessibility grant breaks on every rebuild. Run 'make dev-cert' once."
endif
	codesign --force --sign "$(SIGN_ID)" $(APP)

run: app stop
	open $(APP)

stop:
	-pkill -x MacTaskbar

# Print what the AX enumeration sees. Run from a terminal, the Accessibility check
# applies to the terminal app, not to MacTaskbar.app.
dump: build
	$(BIN) --dump

logs:
	log stream --level debug --predicate 'subsystem == "$(SUBSYSTEM)"'

# One-time: create a self-signed code-signing identity in the login keychain.
dev-cert:
	scripts/create-dev-cert.sh

# Ad-hoc signatures change on every build, so macOS may silently ignore the
# old Accessibility grant. Reset it and grant again when the bar stays empty.
reset-permission:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf .build dist
