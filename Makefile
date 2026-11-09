# make                 same as make dist
# make dist            src/ -> dist/ (rebuilds this OS's native app first when src/native changed)
# make dist-hook       the PostToolUse hook: read the event on stdin, run dist only if a src/ file was edited
# make native          build the native app for this OS (macOS or Windows), then dist
# make native-macos    build build/macos/DeskBuddy.zip (on macOS), then dist
# make native-windows  build build/windows/DeskBuddy.zip (on Windows), then dist
# make test            run the mod's tests
# make publish        build dist/ and push it to the dist branch on origin (the marketplace)
# make install-dev     register dist/ as a local marketplace and install the plugin from it
# make uninstall-app   remove the installed native app so the mod reinstalls it (macOS; Windows todo)
# make clean           remove build/ and dist/
CLAUDE := scripts/claude.sh

ifeq ($(OS),Windows_NT)
NATIVE := native-windows
else
NATIVE := native-macos
endif

.PHONY: dist dist-hook native native-macos native-windows test publish install-dev uninstall-app clean
dist:
	scripts/dist.sh
dist-hook:
	scripts/dist.sh --hook
native: $(NATIVE)
native-macos:
	src/native/macos/build.sh
	scripts/dist.sh
native-windows:
	powershell -NoProfile -ExecutionPolicy Bypass -File src/native/windows/build.ps1
	scripts/dist.sh
test:
	$(CLAUDE) plugin test src/mod
publish:
	scripts/publish.sh
install-dev: dist
	$(CLAUDE) plugin marketplace add "$(CURDIR)/dist"
	$(CLAUDE) plugin install desk-buddy@desk-buddy
uninstall-app:
	scripts/uninstall-app.sh
clean:
	rm -rf build dist
