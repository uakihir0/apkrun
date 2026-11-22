# APKRun arm64 product (android-image.md §11).
#
# Inherits the Cuttlefish arm64 phone product and adds the APKRun guest
# components: the Guest Agent, the Store Agent, and apkrun_vsockd
# (ADR-0008). The kernel, partition layout, and fstab stay unchanged so
# the stock image remains a valid development target (§11.2).

$(call inherit-product, device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk)

PRODUCT_NAME := apkrun_arm64
PRODUCT_DEVICE := apkrun_arm64
PRODUCT_MANUFACTURER := APKRun
PRODUCT_BRAND := apkrun
PRODUCT_MODEL := APKRun arm64

# All APKRun modules use Android.bp (android-image.md §11.1).
PRODUCT_IGNORE_ALL_ANDROIDMK := true

PRODUCT_PACKAGES += \
    apkrun_vsockd \
    ApkRunGuest \
    ApkRunStore

# Marks the image as an APKRun product for init/apkrun.rc and the agent
# startup checks (android-image.md §11.1).
PRODUCT_PRODUCT_PROPERTIES += \
    ro.apkrun.product=1

# Privapp permissions, overlays, and the host-owned time settings
# (desktop-integration.md §9: AUTO_TIME and AUTO_TIME_ZONE default to 0
# in overlay/frameworks/base/packages/SettingsProvider).
include device/apkrun/apkrun_arm64/locale-time.mk

# The APKRun policy inputs. The userdebug-only permissive rules stay in
# sepolicy/userdebug/ so a `user` build never sees them (ADR-0020);
# scripts/check-sepolicy.sh enforces that split before a `user` build.
BOARD_SEPOLICY_DIRS += device/apkrun/apkrun_arm64/sepolicy
ifeq ($(TARGET_BUILD_VARIANT),userdebug)
BOARD_SEPOLICY_DIRS += device/apkrun/apkrun_arm64/sepolicy/userdebug
endif

# Release AVB key (ADR-0020): the builder supplies it through
# APKRUN_AVB_KEY_DIR and keeps it outside the repository; without it the
# product inherits the AOSP test key, so a `user` build must set it.
ifneq ($(strip $(APKRUN_AVB_KEY_DIR)),)
BOARD_AVB_ENABLE := true
BOARD_AVB_KEY_PATH := $(APKRUN_AVB_KEY_DIR)/avb.pem
BOARD_AVB_ALGORITHM := SHA256_RSA4096
endif
