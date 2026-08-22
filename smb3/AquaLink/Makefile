APPNAME = AquaLink
APPBUNDLE = $(APPNAME).app
CONTENTS = $(APPBUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS

# LIBSMB2_DIR ひとつだけ指定すれば済むように、よくあるレイアウトを順に探して
# 最初に見つかったものを使う。手元ビルド(iBook上で ./configure --disable-shared
# した際の $(LIBSMB2_DIR)/lib/.libs/libsmb2.a)と、MacPorts等でインストール済みの
# prefix($(LIBSMB2_DIR)/lib/libsmb2.dylib や libsmb2.a)の両方に対応する。
# 見つからなければ最後の候補(手元ビルドの場所)を既定値として使う。
LIBSMB2_DIR ?= $(HOME)/developer/libsmb2
LIBSMB2_INC ?= $(LIBSMB2_DIR)/include
LIBSMB2_A ?= $(firstword \
    $(wildcard $(LIBSMB2_DIR)/lib/libsmb2.dylib) \
    $(wildcard $(LIBSMB2_DIR)/lib/libsmb2.a) \
    $(wildcard $(LIBSMB2_DIR)/lib/.libs/libsmb2.a) \
    $(LIBSMB2_DIR)/lib/.libs/libsmb2.a)

CC ?= gcc
CFLAGS += -std=gnu99 -Wall -fobjc-exceptions -I$(LIBSMB2_INC)
LDFLAGS += -framework Cocoa -framework Security

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
