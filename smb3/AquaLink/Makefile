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

# システム側(/System/Library/Frameworks)のCocoaヘッダーが実際に見つかる場合は
# 何もせず、今まで通りシステムのヘッダーをそのまま使う(大多数の環境ではこちら)。
# SDKが/Developer/SDKsに「存在するかどうか」だけでは判定しない。存在していても、
# 動いているOSやgccのバージョンと噛み合わない組み合わせだとヘッダーが引けず
# ビルドが壊れる(例: Leopard/Snow LeopardでMacOSX10.4u.sdkを掴んでstdarg.hや
# float.hが見つからないエラーになったケースが実際にあった)。
# システム側のヘッダーが本当に無い場合(OSアップデート等で消えた等)に限って、
# SDKへのフォールバックを試みる。
ifeq ($(wildcard /System/Library/Frameworks/Cocoa.framework/Headers/Cocoa.h),)
SDKROOT ?= $(firstword \
    $(wildcard /Developer/SDKs/MacOSX10.4u.sdk) \
    $(wildcard /Developer/SDKs/MacOSX10.5.sdk) \
    $(wildcard /Developer/SDKs/MacOSX10.6.sdk))
endif

CC ?= gcc
CFLAGS += -std=gnu99 -Wall -fobjc-exceptions -I$(LIBSMB2_INC)
ifneq ($(SDKROOT),)
CFLAGS += -isysroot $(SDKROOT)
LDFLAGS += -isysroot $(SDKROOT)
endif
LDFLAGS += -framework Cocoa -framework Security

OBJS = main.o AppDelegate.o WebDAVServer.o LocalWebDAVServer.o

# 「取り外す」がGUIの管理者権限ダイアログでは失敗する環境向けの、setuid root
# ヘルパー(詳細はaqualink-umount-helper.cとsmb3/README.md参照)。Cocoaに
# 依存しないただのCプログラムなので、アプリ本体と別にビルドしてResourcesへ置く。
HELPER = aqualink-umount-helper

all: $(APPBUNDLE)

RESOURCES = $(CONTENTS)/Resources

$(APPBUNDLE): $(MACOS)/$(APPNAME) Info.plist $(APPNAME).icns $(RESOURCES)/$(HELPER)
	mkdir -p $(CONTENTS)
	mkdir -p $(RESOURCES)
	cp Info.plist $(CONTENTS)/Info.plist
	cp $(APPNAME).icns $(RESOURCES)/$(APPNAME).icns
	printf 'APPL????' > $(CONTENTS)/PkgInfo

$(RESOURCES)/$(HELPER): $(HELPER).c
	mkdir -p $(RESOURCES)
	$(CC) -std=gnu99 -Wall -o $@ $(HELPER).c

$(MACOS)/$(APPNAME): $(OBJS) $(LIBSMB2_A)
	mkdir -p $(MACOS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBSMB2_A)

%.o: %.m
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(OBJS) $(APPBUNDLE) $(HELPER)

.PHONY: all clean
