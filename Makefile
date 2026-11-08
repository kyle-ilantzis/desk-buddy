# make                 same as make dist
# make dist            src/ -> dist/ (rebuilds this OS's native app first when src/native changed)
# make native          build the native app for this OS (macOS or Windows), then dist
# make native-macos    build build/macos/DeskBuddy.zip (on macOS), then dist
# make native-windows  build build/windows/DeskBuddy.zip (on Windows), then dist
# make test            run the mod's tests
# make install-dev     register dist/ as a local marketplace and install the plugin from it
# make uninstall-app   remove the installed native app so the mod reinstalls it (macOS; Windows todo)
# make clean           remove build/ and dist/
CLAUDE := scripts/claude.sh

ifeq ($(OS),Windows_NT)
NATIVE := native-windows
else
NATIVE := native-macos
endif

.PHONY: dist native native-macos native-windows test install-dev uninstall-app clean
dist:
	scripts/dist.sh
native: $(NATIVE)
native-macos:
	src/native/macos/build.sh
	scripts/dist.sh
native-windows:
	powershell -NoProfile -ExecutionPolicy Bypass -File src/native/windows/build.ps1
	scripts/dist.sh
test:
	$(CLAUDE) plugin test src/mod
install-dev: dist
	$(CLAUDE) plugin marketplace add "$(CURDIR)/dist"
	$(CLAUDE) plugin install desk-buddy@desk-buddy
uninstall-app:
	scripts/uninstall-app.sh
clean:
	rm -rf build dist
