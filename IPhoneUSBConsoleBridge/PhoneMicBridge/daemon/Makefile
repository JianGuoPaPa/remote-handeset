TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME := IPhoneUSBMicD

IPhoneUSBMicD_FILES := main.c
IPhoneUSBMicD_CFLAGS := -std=gnu11 -Wall -Wextra -Werror \
	-I../include
IPhoneUSBMicD_INSTALL_PATH := /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
