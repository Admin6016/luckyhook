TARGET = iphone:clang:latest:16.5
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = LuckyClient

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LuckyHook
LuckyHook_FILES = Tweak.xm
LuckyHook_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
LuckyHook_FRAMEWORKS = Foundation UIKit
LuckyHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
