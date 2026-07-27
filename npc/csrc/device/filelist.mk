DIRS-$(CONFIG_DEVICE) += csrc/device/io
SRCS-$(CONFIG_DEVICE) += csrc/device/device.cpp
SRCS-$(CONFIG_HAS_SERIAL) += csrc/device/serial.cpp
SRCS-$(CONFIG_HAS_TIMER) += csrc/device/rtc.cpp
