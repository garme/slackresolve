PREFIX ?= /usr
DESTDIR ?=
LIBDIR = $(PREFIX)/libexec/slackresolve

.PHONY: all test check install uninstall dist slackware-package
all: check
check:
	@for script in bin/* lib/*.sh tests/*.sh packaging/*.SlackBuild; do test ! -f "$$script" || bash -n "$$script" || exit; done
test: check
	bash tests/run.sh
install: check
	install -d "$(DESTDIR)$(PREFIX)/sbin" "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(LIBDIR)/lib" "$(DESTDIR)$(LIBDIR)/awk"
	install -m 755 bin/slackresolve "$(DESTDIR)$(PREFIX)/sbin/slackresolve"
	install -m 755 bin/slackresolve-tui "$(DESTDIR)$(PREFIX)/bin/slackresolve-tui"
	install -m 644 lib/*.sh "$(DESTDIR)$(LIBDIR)/lib/"
	install -m 644 awk/*.awk "$(DESTDIR)$(LIBDIR)/awk/"
	install -d "$(DESTDIR)$(PREFIX)/share/applications" "$(DESTDIR)$(PREFIX)/doc/slackresolve-0.3.3/docs" "$(DESTDIR)$(PREFIX)/man/man8"
	install -m 644 share/slackresolve.desktop "$(DESTDIR)$(PREFIX)/share/applications/"
	install -m 644 README.md LICENSE "$(DESTDIR)$(PREFIX)/doc/slackresolve-0.3.3/"
	install -m 644 docs/*.md "$(DESTDIR)$(PREFIX)/doc/slackresolve-0.3.3/docs/"
	install -m 644 docs/TEST_RESULTS.txt "$(DESTDIR)$(PREFIX)/doc/slackresolve-0.3.3/docs/"
	install -m 644 docs/slackresolve.8 "$(DESTDIR)$(PREFIX)/man/man8/"
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/sbin/slackresolve" "$(DESTDIR)$(PREFIX)/bin/slackresolve-tui" "$(DESTDIR)$(PREFIX)/share/applications/slackresolve.desktop" "$(DESTDIR)$(PREFIX)/man/man8/slackresolve.8"
	rm -rf "$(DESTDIR)$(LIBDIR)" "$(DESTDIR)$(PREFIX)/doc/slackresolve-0.3.3"
dist:
	mkdir -p dist
	tar --exclude=./dist --exclude=./.git --exclude=./.test-work --transform='s,^\./,slackresolve-0.3.3/,' -czf dist/slackresolve-0.3.3.tar.gz .
slackware-package:
	bash packaging/slackresolve.SlackBuild
