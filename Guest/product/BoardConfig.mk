SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/apkrun/apkrun_arm64/sepolicy/system_ext/private

ifeq ($(TARGET_BUILD_VARIANT),userdebug)
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/apkrun/apkrun_arm64/sepolicy/userdebug
endif
