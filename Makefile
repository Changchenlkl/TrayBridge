.PHONY: build package test diagnose run clean

build:
	./Scripts/build.sh

package: build
	./Scripts/package.sh

test: build
	./Scripts/test.sh

diagnose: build
	./Scripts/app.sh diagnose

run: build
	./Scripts/app.sh run

clean:
	rm -rf work/build work/package
