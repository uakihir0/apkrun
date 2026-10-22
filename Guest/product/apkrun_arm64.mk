$(call inherit-product, device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk)

# The development image uses Cuttlefish's userdebug defaults, including the
# orange, unlocked AVB state from OQ-36. Release signing is supplied separately
# by the offline user-image build.
PRODUCT_IGNORE_ALL_ANDROIDMK := true
PRODUCT_NAME := apkrun_arm64
PRODUCT_DEVICE := apkrun_arm64
PRODUCT_BRAND := APKRun
PRODUCT_MODEL := APKRun ARM64
PRODUCT_MANUFACTURER := APKRun

PRODUCT_SYSTEM_PROPERTIES += \
    ro.apkrun.product=1

PRODUCT_PACKAGES += \
    ApkRunGuest \
    apkrun_vsockd

PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.usb.config=none \
    ro.adb.secure=1

PRODUCT_COPY_FILES += \
    device/apkrun/apkrun_arm64/init/apkrun.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/apkrun.rc \
    device/apkrun/apkrun_arm64/permissions/privapp-permissions-apkrun.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-apkrun.xml
