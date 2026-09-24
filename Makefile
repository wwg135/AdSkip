export TARGET ?= iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdSkip
ARCHS = arm64 arm64e

AdSkip_FILES = Tweak.xm
AdSkip_CFLAGS = -fobjc-arc
AdSkip_LDFLAGS = -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Vision -framework IOKit

BUNDLE_NAME = AdSkipPrefs
AdSkipPrefs_FILES = AdSkipPrefs/AdSkipRootListController.m AppScanner.m
AdSkipPrefs_INSTALL_PATH = /Library/PreferenceBundles
AdSkipPrefs_FRAMEWORKS = UIKit
AdSkipPrefs_PRIVATE_FRAMEWORKS = Preferences
AdSkipPrefs_INFO_PLIST = AdSkipPrefs/Info.plist
AdSkipPrefs_RESOURCE_FILES = \
    AdSkipPrefs/Root.plist \
    AdSkipPrefs/Resources/icon.png \
    AdSkipPrefs/Resources/icon@2x.png \
    AdSkipPrefs/Resources/icon@3x.png

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
