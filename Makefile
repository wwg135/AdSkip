export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdSkip
ARCHS = arm64 arm64e
AdSkip_FILES = Tweak.xm
AdSkip_CFLAGS = -fobjc-arc
AdSkip_LDFLAGS = -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Vision -framework IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

