PACKAGE = nginx-mod-gallery
VERSION = $(shell \
    grep VERSION lib/Nginx/Module/Gallery.pm |grep ^our \
    |sed 's/[^[:digit:].]\+//g')
EMAIL = rshadow@rambler.ru
LICENSE = gpl3

deb-dh-make:
	dh_make \
		--packagename $(PACKAGE)_$(VERSION) \
		--single \
		--email $(EMAIL) \
		--copyright $(LICENSE) \
		--createorig
	
deb-changelog:
	dch --newversion $(VERSION)
