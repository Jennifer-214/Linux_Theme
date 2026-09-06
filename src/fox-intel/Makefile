CXX = g++
CXXFLAGS = -std=c++17 -O3 -Wall -fPIC
LIBS = -lcurl
PREFIX = $(HOME)/.local/bin

all: libfox-intel.a findex fask

libfox-intel.a: fox_intel.o
	ar rcs $@ $^

fox_intel.o: fox_intel.cpp fox_intel.hpp ../fox-common/json.hpp
	$(CXX) $(CXXFLAGS) -c fox_intel.cpp -o $@

findex: findex.cpp libfox-intel.a
	$(CXX) $(CXXFLAGS) findex.cpp -o findex -L. -lfox-intel $(LIBS)

fask: fask.cpp libfox-intel.a
	$(CXX) $(CXXFLAGS) fask.cpp -o fask -L. -lfox-intel $(LIBS)

install: all
	mkdir -p $(PREFIX)
	cp findex fask $(PREFIX)/
	@echo "Binaries installed to $(PREFIX)"

clean:
	rm -f *.o *.a findex fask
