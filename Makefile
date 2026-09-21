usage:
	ps -p $(pgrep -d',' basic) -o %cpu,%mem

trace:
	strace -c zig build basic > /dev/null

top:
	top -pid $(pgrep -d',' basic)

clean:
	rm -rf .zig-cache zig-out zig-pkg
	@for ex in examples/*/; do \
		rm -rf "$$ex.zig-cache" "$$ex.zig-out" "$$ex.zig-pkg"; \
	done

fast:
	zig build --release=fast --summary all

small:
	zig build --release=small --summary all
	zig build bench --release=small --summary all

base:
	zig build -Dcpu=baseline --release=safe --summary all
	
coverage:
	zig build test -Dcoverage --summary all

log:
	git log --pretty=format:"%h%x09%an%x09%ad%x09%s"

size:
	ls -alth ./zig-out/bin
