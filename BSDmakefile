# FreeBSD's make(1) reads BSDmakefile before Makefile. QuickRAW's Makefile is written for
# GNU make, so point the user to it instead of failing with confusing syntax errors.

all:
	@echo "On FreeBSD, QuickRAW is built with GNU make:"
	@echo "    pkg install gmake      (once)"
	@echo "    gmake                  (instead of make; e.g. gmake -j4, gmake BACKEND=coarray)"
	@false

.DEFAULT:
	@echo "On FreeBSD, QuickRAW is built with GNU make: gmake ${.TARGET}"
	@false
