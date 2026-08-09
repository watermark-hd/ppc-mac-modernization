APPNAME = AquaLink
APPBUNDLE = $(APPNAME).app
CONTENTS = $(APPBUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS

LIBSMB2_DIR = $(HOME)/developer/libsmb2
LIBSMB2_INC = $(LIBSMB2_DIR)/include
LIBSMB2_A = $(LIBSMB2_DIR)/lib/.libs/libsmb2.a

CC = gcc
CFLAGS = -std=gnu99 -Wall -fobjc-exceptions -I$(LIBSMB2_INC)
LDFLAGS = -framework Cocoa -framework Security

OBJS = main.o AppDelegate.o WebDAVServer.o LocalWebDAVServer.o

all: $(APPBUNDLE)

RESOURCES = $(CONTENTS)/Resources

$(APPBUNDLE): $(MACOS)/$(APPNAME) Info.plist $(APPNAME).icns
	mkdir -p $(CONTENTS)
	mkdir -p $(RESOURCES)
	cp Info.plist $(CONTENTS)/Info.plist
	cp $(APPNAME).icns $(RESOURCES)/$(APPNAME).icns
	printf 'APPL????' > $(CONTENTS)/PkgInfo

$(MACOS)/$(APPNAME): $(OBJS) $(LIBSMB2_A)
	mkdir -p $(MACOS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBSMB2_A)

%.o: %.m
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(OBJS) $(APPBUNDLE)

.PHONY: all clean
