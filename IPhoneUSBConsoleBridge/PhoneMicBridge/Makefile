export THEOS_PACKAGE_SCHEME := rootless
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

SUBPROJECTS := daemon tweak

include $(THEOS_MAKE_PATH)/aggregate.mk
