LOCAL_PATH := $(call my-dir)

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/permissions/privapp-permissions-apkrun.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-apkrun.xml

DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay
