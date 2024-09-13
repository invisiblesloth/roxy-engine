HEAP_SIZE      = 8388208
STACK_SIZE     = 61800

PRODUCT = GameName.pdx

# Locate the SDK
SDK = ${PLAYDATE_SDK_PATH}
ifeq ($(SDK),)
	SDK = $(shell egrep '^\s*SDKRoot' ~/.Playdate/config | head -n 1 | cut -c9-)
endif

ifeq ($(SDK),)
	$(error SDK path not found; set ENV value PLAYDATE_SDK_PATH)
endif

VPATH += source/libraries/roxy \
		 source/libraries/roxy/utilities \
		 source/libraries/roxy/core/managers \
		 source/libraries/roxy/classes

# List C source files here
SRC = source/libraries/roxy/roxy.c \
	  source/libraries/roxy/utilities/roxy_math.c \
	  source/libraries/roxy/utilities/roxy_ease.c \
	  source/libraries/roxy/core/managers/roxy_input.c \
	  source/libraries/roxy/core/sequences/roxy_sequence.c

# List all user directories here
UINCDIR = 

# List user asm files
UASRC = 

# List all user C define here, like -D_DEBUG=1
UDEFS = 

# Define ASM defines here
UADEFS = 

# List the user directory to look for the libraries here
ULIBDIR =

# List all user libraries here
ULIBS =

include $(SDK)/C_API/buildsupport/common.mk
