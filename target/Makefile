GID := $(shell git rev-parse --short HEAD)
DIRTY := $(shell if [ -z "$$(git status --porcelain)" ]; then echo ""; else echo "-dirty"; fi)
VERSION := 1.0-$(GID)$(DIRTY)

LUSTRE_PACKAGE=lustre-udev
LUSTRE_BUILD_DIR=build/$(LUSTRE_PACKAGE)
LUSTRE_DESCRIPTION=install the udev rules file required for lustre target deployment

LVM_PACKAGE=lvm-udev
LVM_BUILD_DIR=build/$(LVM_PACKAGE)
LVM_DESCRIPTION=install the udev rules file required for lvm target deployment

all: pkg-lustre pkg-lvm

pkg-lustre:
	@echo "Preparing lustre deb package directory structure..."
	@mkdir -p $(LUSTRE_BUILD_DIR)/etc/udev/rules.d/
	@mkdir -p $(LUSTRE_BUILD_DIR)/lib/lustre/
	@mkdir -p $(LUSTRE_BUILD_DIR)/DEBIAN

	@echo "Preparing lustre deb $(LUSTRE_PACKAGE) version $(VERSION)..."
	@cp ./debian/control ./debian/lustre-control
	@sed -i 's/^Package:.*$$/Package: $(LUSTRE_PACKAGE)/g' debian/lustre-control
	@sed -i 's/^Version:.*$$/Version: $(VERSION)/g' debian/lustre-control
	@sed -i 's/^Description:.*$$/Description: $(LUSTRE_DESCRIPTION)\n/g' debian/lustre-control
	@mv debian/lustre-control $(LUSTRE_BUILD_DIR)/DEBIAN/control
	@cp udev/50-persistent-storage-iscsi.rules $(LUSTRE_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/60-persistent-storage-nvme.rules $(LUSTRE_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/64-md-raid-attr-ltgt.rules $(LUSTRE_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/90-md-raid-device-ltgt.rules $(LUSTRE_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/gethostname.sh $(LUSTRE_BUILD_DIR)/etc/
	@cp udev/ltgt_mdraid.sh $(LUSTRE_BUILD_DIR)/lib/lustre/

	@echo "Building lustre $(LUSTRE_BUILD_DIR).deb package..."
	@dpkg-deb --build $(LUSTRE_BUILD_DIR)
	@echo "Deb lustre package created at $(LUSTRE_BUILD_DIR).deb"

pkg-lvm:
	@echo "Preparing lvm deb package directory structure..."
	@mkdir -p $(LVM_BUILD_DIR)/etc/udev/rules.d/
	@mkdir -p $(LVM_BUILD_DIR)/lib/lvm/
	@mkdir -p $(LVM_BUILD_DIR)/DEBIAN

	@echo "Preparing lvm deb $(LVM_PACKAGE) version $(VERSION)..."
	@cp ./debian/control ./debian/lvm-control
	@sed -i 's/^Package:.*$$/Package: $(LVM_PACKAGE)/g' debian/lvm-control
	@sed -i 's/^Version:.*$$/Version: $(VERSION)/g' debian/lvm-control
	@sed -i 's/^Description:.*$$/Description: $(LVM_DESCRIPTION)\n/g' debian/lvm-control
	@mv debian/lvm-control $(LVM_BUILD_DIR)/DEBIAN/control
	@cp udev/50-persistent-storage-iscsi.rules $(LVM_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/60-persistent-storage-nvme.rules $(LVM_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/99-md-raid-device-lvm.rules $(LVM_BUILD_DIR)/etc/udev/rules.d/
	@cp udev/gethostname.sh $(LVM_BUILD_DIR)/etc/
	@cp udev/lvm_mdraid.sh $(LVM_BUILD_DIR)/lib/lvm/

	@echo "Building lvm $(LVM_BUILD_DIR).deb package..."
	@dpkg-deb --build $(LVM_BUILD_DIR)
	@echo "Deb lustre package created at $(LVM_BUILD_DIR).deb"

clean-lustre:
	rm -rf $(LUSTRE_BUILD_DIR) build/$(LUSTRE_PACKAGE).deb

clean-lvm:
	rm -rf $(LVM_BUILD_DIR) build/$(LVM_PACKAGE).deb

clean-all:
	rm -rf build/*
