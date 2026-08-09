APPNAME = NASBrowser
APPBUNDLE = $(APPNAME).app
CONTENTS = $(APPBUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS

LIBSMB2_DIR = $(HOME)/libsmb2
LIBSMB2_INC = $(LIBSMB2_DIR)/include
LIBSMB2_A = $(LIBSMB2_DIR)/lib/.libs/libsmb2.a

CC = gcc
CFLAGS = -std=gnu99 -Wall -fobjc-exceptions -I$(LIBSMB2_INC)
LDFLAGS = -framework Cocoa

OBJS = main.o AppDelegate.o WebDAVServer.o

all: $(APPBUNDLE)

$(APPBUNDLE): $(MACOS)/$(APPNAME) Info.plist
	mkdir -p $(CONTENTS)
	cp Info.plist $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo

$(MACOS)/$(APPNAME): $(OBJS) $(LIBSMB2_A)
	mkdir -p $(MACOS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBSMB2_A)

%.o: %.m
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(OBJS) $(APPBUNDLE)

.PHONY: all clean
