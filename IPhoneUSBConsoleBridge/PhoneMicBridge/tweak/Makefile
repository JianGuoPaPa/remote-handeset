TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := IPhoneUSBMic

IPhoneUSBMic_FILES := Tweak.xm MicStream.c MicStreamClient.c
IPhoneUSBMic_CFLAGS := -fobjc-arc -Wall -Wextra \
	-I../include -I.
IPhoneUSBMic_CCFLAGS := -std=c++17
IPhoneUSBMic_FRAMEWORKS := Foundation AVFoundation CoreMedia AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
