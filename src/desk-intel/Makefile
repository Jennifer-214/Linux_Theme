CXX = g++
CXXFLAGS = -std=c++17 -O3 -Wall -fPIC
LIBS = -lcurl
PREFIX = $(HOME)/.local/bin

all: libdesk-intel.a findex fask

libdesk-intel.a: desk_intel.o
	ar rcs $@ $^

desk_intel.o: desk_intel.cpp desk_intel.hpp ../desk-common/json.hpp
	$(CXX) $(CXXFLAGS) -c desk_intel.cpp -o $@

findex: findex.cpp libdesk-intel.a
	$(CXX) $(CXXFLAGS) findex.cpp -o findex -L. -ldesk-intel $(LIBS)

fask: fask.cpp libdesk-intel.a
	$(CXX) $(CXXFLAGS) fask.cpp -o fask -L. -ldesk-intel $(LIBS)

install: all
	mkdir -p $(PREFIX)
	cp findex fask $(PREFIX)/
	@echo "Binaries installed to $(PREFIX)"

clean:
	rm -f *.o *.a findex fask
