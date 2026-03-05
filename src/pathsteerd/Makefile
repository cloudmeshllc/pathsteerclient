# PathSteer Guardian Daemon Makefile
#
# Build: make
# Install: make install
# Clean: make clean

CC = gcc
CFLAGS = -Wall -Wextra -O2 -D_GNU_SOURCE
LDFLAGS = -lpthread -lm -lcurl -lsqlite3

# Source files
SRC = pathsteerd.c
OBJ = $(SRC:.c=.o)
TARGET = pathsteerd

# Install paths
PREFIX ?= /opt/pathsteer
BINDIR = $(PREFIX)/bin

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ) $(TARGET)

install: $(TARGET)
	install -d $(BINDIR)
	install -m 755 $(TARGET) $(BINDIR)/

# Debug build
debug: CFLAGS += -g -DDEBUG
debug: clean all

# Static build (for distribution)
static: LDFLAGS += -static
static: clean all

# Dependencies
pathsteerd.o: pathsteerd.c
