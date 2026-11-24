# APKRun product lunch targets (android-image.md §11.1, ADR-0020).
#
# Mapped into the AOSP tree as device/apkrun/apkrun_arm64/ by
# scripts/aosp/build-product.sh.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/apkrun_arm64.mk

COMMON_LUNCH_CHOICES := \
    apkrun_arm64-trunk_staging-userdebug \
    apkrun_arm64-trunk_staging-user
