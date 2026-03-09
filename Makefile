PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/rocket_nif.so

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop)

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -fPIC -shared -I$(ERTS_INCLUDE_DIR) -Ic_src

# Enable SSE4.2 for picohttpparser SIMD optimization if supported and not already enabled
SSE42_ALREADY := $(shell echo | $(CC) -dM -E - 2>/dev/null | grep -q __SSE4_2__ && echo yes || echo no)
ifeq ($(SSE42_ALREADY),no)
    SSE42_SUPPORTED := $(shell echo | $(CC) -msse4.2 -dM -E - 2>/dev/null | grep -q __SSE4_2__ && echo yes || echo no)
    ifeq ($(SSE42_SUPPORTED),yes)
	CFLAGS += -msse4.2
    endif
endif

# macOS-specific linker flags
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	CFLAGS += -undefined dynamic_lookup
endif

all: $(NIF_SO)

$(NIF_SO): c_src/rocket_nif.c c_src/picohttpparser.c c_src/picohttpparser.h
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ c_src/rocket_nif.c c_src/picohttpparser.c

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
