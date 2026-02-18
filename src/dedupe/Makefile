# PathSteer Guardian - dedupe Makefile

CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -pthread
LDFLAGS = -lpthread

TARGET = dedupe
SRCS = dedupe.c

PREFIX ?= /usr/local

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/
