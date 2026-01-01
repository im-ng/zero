usage:
	ps -p $(pgrep -d',' basic) -o %cpu,%mem

trace:
	strace -c zig build basic > /dev/null

top:
	top -pid $(pgrep -d',' basic)

clean:
	rm -rf .zig-cache zig-out
	rm -rf examples/zero-auth/.zig-cache examples/zero-auth/zig-out
	rm -rf examples/zero-basic/.zig-cache examples/zero-basic/zig-out
	rm -rf examples/zero-cronz/.zig-cache examples/zero-cronz/zig-out
	rm -rf examples/zero-migration/.zig-cache examples/zero-migration/zig-out
	rm -rf examples/zero-mqtt-publisher/.zig-cache examples/zero-mqtt-publisher/zig-out
	rm -rf examples/zero-mqtt-subscriber/.zig-cache examples/zero-mqtt-subscriber/zig-out
	rm -rf examples/zero-redis/.zig-cache examples/zero-redis/zig-out
	rm -rf examples/zero-service-client/.zig-cache examples/zero-service-client/zig-out
	rm -rf examples/zero-stream/.zig-cache examples/zero-stream/zig-out
	rm -rf examples/zero-todo-htmx/.zig-cache examples/zero-todo-htmx/zig-out
	rm -rf examples/zero-websocket/.zig-cache examples/zero-websocket/zig-out
	rm -rf examples/zero-kafka-publisher/.zig-cache examples/zero-kafka-publisher/zig-out
	rm -rf examples/zero-kafka-subscriber/.zig-cache examples/zero-kafka-subscriber/zig-out

release:
	zig build --release=fast

log:
	git log --pretty=format:"%h%x09%an%x09%ad%x09%s"
