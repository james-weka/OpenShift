ifndef DESTDIR
DESTDIR=/usr/
endif
ifndef CONFDIR
CONFDIR=/etc
endif

install:
	install -v -m 644 weka-kmod-lib.sh $(DESTDIR)/lib/kvc/
	install -v -m 644 weka-kmod.conf $(CONFDIR)/kvc/
	install -v -m 755 weka-kmod-wrapper.sh $(DESTDIR)/lib/kvc/
	ln -sf ../lib/kvc/weka-kmod-wrapper.sh $(DESTDIR)/bin/spkut
