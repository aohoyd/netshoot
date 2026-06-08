# Build Vars
IMAGENAME = aohoyd/cdbg
VERSION = 0.3

PACKAGES_DIR = packages
OUT_DIR = out
# Built one at a time: concurrent arch builders race on temp files in the
# shared source dir (packages/), so each arch gets its own melange invocation.
ARCHES = x86_64 aarch64
PACKAGE_YAMLS := $(wildcard $(PACKAGES_DIR)/*.yaml)
PACKAGE_NAMES := $(basename $(notdir $(PACKAGE_YAMLS)))

.DEFAULT_GOAL = all

.PHONY: build-packages build all update release release-latest $(PACKAGE_NAMES)

all:
		@$(MAKE) build-packages
		@$(MAKE) build

build:
		apko build apko.yaml ${IMAGENAME}:${VERSION} cdbg.tar --ignore-signatures

release:
		@test -f cdbg.tar || { echo "cdbg.tar not found — run 'make' first" >&2; exit 1; }
		docker load -i cdbg.tar
		docker push $(IMAGENAME):$(VERSION)-amd64
		docker push $(IMAGENAME):$(VERSION)-arm64
		docker buildx imagetools create -t $(IMAGENAME):$(VERSION) \
			$(IMAGENAME):$(VERSION)-amd64 $(IMAGENAME):$(VERSION)-arm64

release-latest:
		docker buildx imagetools create -t $(IMAGENAME):latest \
			$(IMAGENAME):$(VERSION)-amd64 $(IMAGENAME):$(VERSION)-arm64

build-packages:
		@for file in $(PACKAGE_YAMLS); do \
			echo "Building $${file}..." ; \
			for arch in $(ARCHES); do \
				melange build $${file} \
					--arch $${arch} \
					--out-dir $(OUT_DIR) \
					--ignore-signatures || exit 2 ; \
			done ; \
		done ;

$(PACKAGE_NAMES):
		@for arch in $(ARCHES); do \
			melange build $(PACKAGES_DIR)/$@.yaml \
				--arch $${arch} \
				--out-dir $(OUT_DIR) \
				--ignore-signatures || exit 2 ; \
		done

update:
		@for file in $(PACKAGE_YAMLS); do \
			./update-package.sh $${file} || exit 2 ; \
		done ;

clean:
		@rm -rf $(OUT_DIR) packages/x86_64 packages/aarch64 cdbg.tar
