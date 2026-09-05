usage:
	ps -p $(pgrep -d',' basic) -o %cpu,%mem

trace:
	strace -c zig build basic > /dev/null

top:
	top -pid $(pgrep -d',' basic)

clean:
	rm -rf .zig-cache zig-out zig-pkg
	rm -rf examples/zero-auth/.zig-cache examples/zero-auth/zig-out	examples/zero-auth/zig-pkg
	rm -rf examples/zero-basic/.zig-cache examples/zero-basic/zig-out examples/zero-basic/zig-pkg 
	rm -rf examples/zero-cronz/.zig-cache examples/zero-cronz/zig-out	examples/zero-cronz/zig-pkg
	rm -rf examples/zero-migration/.zig-cache examples/zero-migration/zig-out	examples/zero-migration/zig-pkg
	rm -rf examples/zero-mqtt-publisher/.zig-cache examples/zero-mqtt-publisher/zig-out	examples/zero-mqtt-publisher/zig-pkg
	rm -rf examples/zero-mqtt-subscriber/.zig-cache examples/zero-mqtt-subscriber/zig-out examples/zero-mqtt-subscriber/zig-pkg
	rm -rf examples/zero-redis/.zig-cache examples/zero-redis/zig-out	examples/zero-redis/zig-pkg
	rm -rf examples/zero-service-client/.zig-cache examples/zero-service-client/zig-out	examples/zero-service-client/zig-pkg
	rm -rf examples/zero-stream/.zig-cache examples/zero-stream/zig-out	examples/zero-stream/zig-pkg
	rm -rf examples/zero-todo-htmx/.zig-cache examples/zero-todo-htmx/zig-out	examples/zero-todo-htmx/zig-pkg
	rm -rf examples/zero-websocket/.zig-cache examples/zero-websocket/zig-out	examples/zero-websocket/zig-pkg
	rm -rf examples/zero-kafka-publisher/.zig-cache examples/zero-kafka-publisher/zig-out	examples/zero-kafka-publisher/zig-pkg
	rm -rf examples/zero-kafka-subscriber/.zig-cache examples/zero-kafka-subscriber/zig-out	examples/zero-kafka-subscriber/zig-pkg
	rm -rf examples/zero-sqlite/.zig-cache examples/zero-sqlite/zig-out	examples/zero-sqlite/zig-pkg
	rm -rf examples/zero-nats-publisher/.zig-cache examples/zero-nats-publisher/zig-out	examples/zero-nats-publisher/zig-pkg
	rm -rf examples/zero-nats-subscriber/.zig-cache examples/zero-nats-subscriber/zig-out examples/zero-nats-subscriber/zig-pkg

release:
	zig build --release=fast

release-prod:
	zig build --release=small --summary all

ut:
	zig build test -Dcoverage --summary all

log:
	git log --pretty=format:"%h%x09%an%x09%ad%x09%s"
