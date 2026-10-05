ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = V16RequestConstructionTrace

V16RequestConstructionTrace_FILES = V16RequestConstructionTrace.m
V16RequestConstructionTrace_CFLAGS = -fobjc-arc
V16RequestConstructionTrace_FRAMEWORKS = Foundation
V16RequestConstructionTrace_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 DCfMHzCDBFK || true"
