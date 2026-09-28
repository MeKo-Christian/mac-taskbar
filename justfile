app := "dist/MacTaskbar.app"
bin := ".build/release/MacTaskbar"
bundle_id := "io.github.cwbudde.mactaskbar"

# Sign with the stable "MacTaskbar Dev" identity (see `just dev-cert`) when present,
# so the Accessibility grant survives rebuilds; fall back to ad-hoc signing.
sign_id := `security find-identity -v -p codesigning 2>/dev/null | grep -q '"MacTaskbar Dev"' && echo "MacTaskbar Dev" || echo -`

default: app

# Compile the release binary
build:
    swift build -c release

# Wrap the binary into dist/MacTaskbar.app and sign it
app: build
    mkdir -p {{app}}/Contents/MacOS
    cp {{bin}} {{app}}/Contents/MacOS/MacTaskbar
    cp Resources/Info.plist {{app}}/Contents/Info.plist
    @if [ "{{sign_id}}" = "-" ]; then echo "warning: signing ad-hoc; the Accessibility grant breaks on every rebuild. Run 'just dev-cert' once."; fi
    codesign --force --sign "{{sign_id}}" {{app}}

# Build, sign and launch the app
run: app stop
    open {{app}}

# Quit a running instance
stop:
    -pkill -x MacTaskbar

# Run from a terminal, the Accessibility check applies to the terminal app, not to MacTaskbar.app.
# Print what the AX enumeration sees, without starting the UI
dump: build
    {{bin}} --dump

# Stream the app's log (debug level)
logs:
    log stream --level debug --predicate 'subsystem == "{{bundle_id}}"'

# One-time: create a self-signed code-signing identity in the login keychain
dev-cert:
    scripts/create-dev-cert.sh

# Ad-hoc signatures change on every build, so macOS may silently ignore the old grant.
# Forget the Accessibility grant; run again and re-grant when the bar stays empty
reset-permission:
    tccutil reset Accessibility {{bundle_id}}

# Remove build output
clean:
    rm -rf .build dist
