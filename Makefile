ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = ShadowTrackerExtra

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Stretch
Stretch_FILES = Tweak.xm
Stretch_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
