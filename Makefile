PREFIX ?= /usr
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share

.PHONY: all install uninstall test

all:
	@echo "PlasmArch does not require compilation. Run 'make install' to install."

install:
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 installer.sh $(DESTDIR)$(BINDIR)/plasmarch
	install -d $(DESTDIR)$(DATADIR)/plasmarch/presets
	cp -r presets/* $(DESTDIR)$(DATADIR)/plasmarch/presets/
	find $(DESTDIR)$(DATADIR)/plasmarch/presets -type d -exec chmod 0755 {} +
	find $(DESTDIR)$(DATADIR)/plasmarch/presets -type f -exec chmod 0644 {} +
	install -d $(DESTDIR)$(DATADIR)/bash-completion/completions
	install -m 0644 completions/bash/plasmarch $(DESTDIR)$(DATADIR)/bash-completion/completions/plasmarch
	install -d $(DESTDIR)$(DATADIR)/zsh/site-functions
	install -m 0644 completions/zsh/_plasmarch $(DESTDIR)$(DATADIR)/zsh/site-functions/_plasmarch
	install -d $(DESTDIR)$(DATADIR)/licenses/plasmarch
	install -m 0644 LICENSE $(DESTDIR)$(DATADIR)/licenses/plasmarch/LICENSE

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/plasmarch
	rm -rf $(DESTDIR)$(DATADIR)/plasmarch
	rm -f $(DESTDIR)$(DATADIR)/bash-completion/completions/plasmarch
	rm -f $(DESTDIR)$(DATADIR)/zsh/site-functions/_plasmarch
	rm -rf $(DESTDIR)$(DATADIR)/licenses/plasmarch

test:
	./tests/test_installer.sh
