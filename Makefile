ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = V16FinalRequestTrace
V16FinalRequestTrace_FILES = V16FinalRequestTrace.m
V16FinalRequestTrace_CFLAGS = -fobjc-arc
V16FinalRequestTrace_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
