# Build:  make package                              (rootful, e.g. palera1n rootful)
#         THEOS_PACKAGE_SCHEME=rootless make package (rootless, e.g. palera1n default)
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ClassicPod

ClassicPod_FILES = main.m IPodViewController.m IPScreenView.m ClickWheelView.m IPMenu.m IPCoverFlowView.m
ClassicPod_FRAMEWORKS = UIKit CoreGraphics QuartzCore MediaPlayer AVFoundation AudioToolbox
ClassicPod_CFLAGS = -fobjc-arc
ClassicPod_CODESIGN_FLAGS = -Sents.plist

include $(THEOS_MAKE_PATH)/application.mk
