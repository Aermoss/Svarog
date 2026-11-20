ZIRCON_PATH := $(abspath ../Zircon)
VELESC_PATH := $(abspath ../Veles)

INCLUDE := $(ZIRCON_PATH)/include
ZIRCONC := $(ZIRCON_PATH)/bin/zirconc.exe
VELESC := $(VELESC_PATH)/bin/velesc.exe

default: build

bin/svarog-as.exe: $(wildcard src/Assembler/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Assembler/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DASSEMBLER

bin/svarog-objdump.exe: $(wildcard src/Disassembler/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Disassembler/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DDISASSEMBLER

bin/svarog-ar.exe: $(wildcard src/Archiver/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Archiver/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DARCHIVER

bin/svarog-ld.exe: $(wildcard src/Linker/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Linker/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DLINKER

bin/svarog-emu.exe: $(wildcard src/Emulator/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Emulator/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -lucrt -DEMULATOR

bin/svarog-nm.exe: $(wildcard src/Symbols/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Symbols/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DSYMBOLS

bin/svarog-strings.exe: $(wildcard src/Strings/*.zir) $(wildcard src/Common/*.zir)
	$(ZIRCONC) src/Strings/Main.zir -o $@ -I$(INCLUDE) -lDbgHelp -DSTRINGS

%.o: bin/svarog-as.exe %.s
	$^ -o $@

boot.hex: bin/svarog-ld.exe boot.o
	$^ -o $@ --format=hex

program.s: program.zir
	$(ZIRCONC) $< -o $@ -S -target svarog -ffreestanding -emit-hir -emit-mir -emit-lir

program.bin: bin/svarog-ld.exe start.o program.o end.o
	$^ -o $@ --format=bin --origin=0x40000000

program.hex: bin/svarog-ld.exe start.o program.o end.o
	$^ -o $@ --format=hex

boot%.hex: boot.hex
	python -I -c "import sys; lane = int(sys.argv[1]); open(sys.argv[3], 'w', newline='').write(''.join(f'{int(word, 16) >> 8 * lane & 255:02x}\n' for word in open(sys.argv[2]).read().split()))" $* $< $@

rtl/build/Svarog.sv: $(wildcard rtl/*.vel)
	if not exist rtl\build mkdir rtl\build
	$(VELESC) rtl/Top.vel -o $@

build: rtl/build/Svarog.sv boot0.hex boot1.hex boot2.hex boot3.hex

emulate: bin/svarog-emu.exe boot.hex program.bin
	$< boot.hex --flash=program.bin

all: bin/svarog-as.exe bin/svarog-objdump.exe bin/svarog-ar.exe bin/svarog-ld.exe bin/svarog-emu.exe bin/svarog-nm.exe bin/svarog-strings.exe

bin/Count.exe: scripts/Count.zir
	$(ZIRCONC) $< -o $@ -I$(INCLUDE)

count: bin/Count.exe
	$<

clean:
	del /Q *.out *.fst *.o *.bin program.hex bin\*.exe *.hir *.mir *.lir
	if exist rtl\build rmdir /S /Q rtl\build
