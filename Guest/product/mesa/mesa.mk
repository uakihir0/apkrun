# Inherit this component from the APKRun AOSP product to add the pinned Mesa
# EGL, GLES, and VirGL driver prebuilts to the vendor image.
PRODUCT_PACKAGES += \
    libEGL_mesa \
    libGLESv1_CM_mesa \
    libGLESv2_mesa \
    libgallium_dri
