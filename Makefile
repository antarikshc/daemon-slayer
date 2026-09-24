# DaemonSlayer — build / install / lifecycle (stock macOS tools only)

APP_NAME      = DaemonSlayer
BUNDLE_ID     = dev.antariksh.daemonslayer
# Ad-hoc by default so anyone can build. Put a real identity in the untracked
# Makefile.local (SIGN_IDENTITY = ...) to keep notification permission across rebuilds.
-include Makefile.local
SIGN_IDENTITY ?= -
INSTALL_DIR   ?= $(HOME)/Applications
DIST          = dist
CONFIG        ?= release

APP            = $(DIST)/$(APP_NAME).app
BIN            = .build/$(CONFIG)/daemonslayer
INSTALLED_APP  = $(INSTALL_DIR)/$(APP_NAME).app
INSTALLED_BIN  = $(INSTALLED_APP)/Contents/MacOS/daemonslayer
LA_TEMPLATE    = packaging/launchagent.plist.template
LA_PLIST       = $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
SYMLINK        = /usr/local/bin/daemonslayer

.PHONY: build install uninstall test clean status

# --- build: compile, assemble bundle, codesign with stable identity ---------
build:
	swift build -c $(CONFIG) --product daemonslayer
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/daemonslayer"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	# Ad-hoc signatures change every build, so macOS re-asks for notification
	# permission; a stable identity from Makefile.local avoids that.
	@echo ">> Codesigning with identity '$(SIGN_IDENTITY)' — macOS may prompt for keychain access on first run."
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) "$(APP)"
	codesign --verify --deep --strict "$(APP)"
	@codesign -dv "$(APP)" 2>&1 | grep -i '^Authority\|^Signature\|^Identifier' || true

# --- install: deploy bundle, write LaunchAgent, (re)bootstrap ---------------
install: build
	mkdir -p "$(INSTALL_DIR)"
	# ditto preserves the signed bundle's structure/xattrs exactly when replacing.
	rm -rf "$(INSTALLED_APP)"
	ditto "$(APP)" "$(INSTALLED_APP)"
	mkdir -p "$(HOME)/Library/LaunchAgents" "$(HOME)/Library/Logs"
	# Substitute literal paths into the plist (launchd does not expand env vars / placeholders).
	sed -e 's|@APP_PATH@|$(INSTALLED_APP)|g' -e 's|@HOME@|$(HOME)|g' "$(LA_TEMPLATE)" > "$(LA_PLIST)"
	# bootout before bootstrap so a re-install replaces any already-loaded agent (idempotent).
	launchctl bootout gui/$$(id -u) "$(LA_PLIST)" 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) "$(LA_PLIST)"
	# kickstart -k forces a (re)start now so the new build is running immediately.
	launchctl kickstart -k gui/$$(id -u)/$(BUNDLE_ID)
	# Convenience symlink only if /usr/local/bin exists and is writable (never sudo, never fail).
	@if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then \
		ln -sf "$(INSTALLED_BIN)" "$(SYMLINK)"; \
		echo ">> Symlinked $(SYMLINK) -> $(INSTALLED_BIN)"; \
	else \
		echo ">> /usr/local/bin not writable; alias manually: alias daemonslayer='$(INSTALLED_BIN)'"; \
	fi
	@echo ""
	@echo ">> Installed. Next steps:"
	@echo "   - First launch prompts for notification permission — allow it."
	@echo "   - Set DaemonSlayer notification style to ALERTS in System Settings > Notifications"
	@echo "     (banners auto-dismiss; ALERTS keeps the Kill button sticky — spec 6)."
	@echo "   - Check status: $(INSTALLED_BIN) --status"

# --- uninstall: tear down agent, bundle, config, logs (spec 11) -------------
uninstall:
	launchctl bootout gui/$$(id -u) "$(LA_PLIST)" 2>/dev/null || true
	rm -rf "$(INSTALLED_APP)"
	rm -f "$(LA_PLIST)"
	# Remove the symlink only if it still points at our installed binary.
	@if [ -L "$(SYMLINK)" ] && [ "$$(readlink "$(SYMLINK)")" = "$(INSTALLED_BIN)" ]; then \
		rm -f "$(SYMLINK)"; echo ">> Removed symlink $(SYMLINK)"; \
	fi
	rm -rf "$(HOME)/.config/daemonslayer"
	rm -rf "$(HOME)/Library/Application Support/daemonslayer"
	rm -f "$(HOME)"/Library/Logs/daemonslayer*.log*
	@echo ">> Removed: bundle, LaunchAgent plist, config (~/.config/daemonslayer),"
	@echo "   state (~/Library/Application Support/daemonslayer), and logs."

# --- test / clean -----------------------------------------------------------
test:
	swift test

clean:
	swift package clean
	rm -rf "$(DIST)"

# --- status: query the running/installed binary, fall back to .build --------
status:
	@if [ -x "$(INSTALLED_BIN)" ]; then \
		"$(INSTALLED_BIN)" --status; \
	elif [ -x "$(BIN)" ]; then \
		"$(BIN)" --status; \
	else \
		echo "No daemonslayer binary found; run 'make build' or 'make install' first."; \
	fi
