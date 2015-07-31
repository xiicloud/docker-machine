.PHONY: build install.sh install

default: build

build: install.sh

install.sh:
	cat prelude.sh > $@
	cat docker-install.sh >> $@
	cat csphere-install.sh >> $@
	sed -i -e '2,$$ s/^#.*//' -e '/^$$/d' $@
	chmod +x $@

install: build
	./install.sh
