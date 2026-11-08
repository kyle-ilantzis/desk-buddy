# make            same as make dist
# make dist       src/ -> dist/ (rebuilds the native app only when src/native changed)
# make native     force a native rebuild, then dist
# make test       run the mod's tests
# make install-dev  register dist/ as a local marketplace and install the plugin from it
# make clean      remove build/ and dist/
CLAUDE := scripts/claude.sh

.PHONY: dist native test install-dev clean
dist:
	scripts/dist.sh
native:
	scripts/dist.sh --native
test:
	$(CLAUDE) plugin test src/mod
install-dev: dist
	$(CLAUDE) plugin marketplace add "$(CURDIR)/dist"
	$(CLAUDE) plugin install desk-buddy@desk-buddy
clean:
	rm -rf build dist
