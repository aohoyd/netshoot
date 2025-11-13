# Build Vars
IMAGENAME = aohoyd/netshoot
VERSION = 0.1

PACKAGES_DIR = packages
PACKAGE_YAMLS := $(wildcard $(PACKAGES_DIR)/*.yaml)
PACKAGE_NAMES := $(basename $(notdir $(PACKAGE_YAMLS)))

.DEFAULT_GOAL = all

.PHONY: build-packages build all $(PACKAGE_NAMES)

all:
		@$(MAKE) build-packages
		@$(MAKE) build

build:
		apko build apko.yaml ${IMAGENAME}:${VERSION} netshoot.tar --ignore-signatures

build-packages:
		@for file in $(PACKAGE_YAMLS); do \
			echo "Building $${file}..." ; \
			melange build $${file} \
				--arch x86_64,aarch64 \
				--out-dir $(PACKAGES_DIR) \
				--ignore-signatures || exit 2 ; \
		done ;

$(PACKAGE_NAMES):
		melange build $(PACKAGES_DIR)/$@.yaml \
			--arch x86_64,aarch64 \
			--out-dir $(PACKAGES_DIR) \
			--ignore-signatures

clean:
		@rm -rf packages/x86_64 packages/aarch64 netshoot.tar
