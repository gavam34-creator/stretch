ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WorkupStretch

WorkupStretch_FILES = Tweak.m
WorkupStretch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
WorkupStretch_FRAMEWORKS = UIKit QuartzCore Foundation

# ВАЖНО: без Substrate — чтобы работало через ESign-инжект
WorkupStretch_USE_SUBSTRATE = no
WorkupStretch_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 ShadowTrackerExtra || true"