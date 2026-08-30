DESTDIR ?=
PREFIX  ?= /usr

.PHONY: build install deb test e2e-test clean

build:
	@echo "Nothing to build (pure Perl/JS plugin)"

install:
	# Perl modules
	install -D -m 0644 src/PVE/API2/Hardware/GPU.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/API2/Hardware/GPU.pm
	install -D -m 0644 src/PVE/API2/Hardware/GPU/Intel.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/API2/Hardware/GPU/Intel.pm
	install -D -m 0644 src/PVE/GPU/SRIOV.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/GPU/SRIOV.pm
	install -D -m 0644 src/PVE/GPU/ATS.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/GPU/ATS.pm
	install -D -m 0644 src/PVE/GPU/Power.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/GPU/Power.pm
	# JavaScript plugin
	install -D -m 0644 src/js/pve-gpu-plugin.js \
		$(DESTDIR)$(PREFIX)/share/pve-manager/js/pve-gpu-plugin.js
	# Scripts
	install -D -m 0755 src/scripts/apply-sriov-config.sh \
		$(DESTDIR)$(PREFIX)/lib/pve-gpu/apply-sriov-config.sh
	install -D -m 0755 src/scripts/apply-vfio-config.sh \
		$(DESTDIR)$(PREFIX)/lib/pve-gpu/apply-vfio-config.sh
	install -D -m 0755 src/scripts/manage-ats-policy.sh \
		$(DESTDIR)$(PREFIX)/lib/pve-gpu/manage-ats-policy.sh
	install -D -m 0755 src/scripts/check-pve-gpu-binders.sh \
		$(DESTDIR)$(PREFIX)/lib/pve-gpu/check-pve-gpu-binders.sh
	install -D -m 0755 src/scripts/reapply-patches.sh \
		$(DESTDIR)$(PREFIX)/lib/pve-gpu/reapply-patches.sh
	# Systemd services
	install -D -m 0644 src/systemd/pve-gpu-sriov.service \
		$(DESTDIR)/lib/systemd/system/pve-gpu-sriov.service
	install -D -m 0644 src/systemd/pve-gpu-vfio.service \
		$(DESTDIR)/lib/systemd/system/pve-gpu-vfio.service
	install -D -m 0644 src/systemd/pve-guests.service.d/10-pve-gpu-manager.conf \
		$(DESTDIR)/lib/systemd/system/pve-guests.service.d/10-pve-gpu-manager.conf
	# APT hook
	install -D -m 0644 config/99-pve-gpu-reapply \
		$(DESTDIR)/etc/apt/apt.conf.d/99-pve-gpu-reapply

deb:
	dpkg-buildpackage -us -uc -b

test:
	prove -r t/

e2e-test:
	cd test/e2e && npx playwright test

clean:
	rm -rf debian/pve-gpu-manager
	rm -rf debian/.debhelper
	rm -f debian/debhelper-build-stamp
	rm -f debian/files
	rm -f ../pve-gpu-manager_*.deb
	rm -f ../pve-gpu-manager_*.buildinfo
	rm -f ../pve-gpu-manager_*.changes
