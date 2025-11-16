ps:
	ps -p $(pgrep -d',' basic) -o %cpu,%mem

trace:
	strace -c zig build basic > /dev/null

top:
	top -pid $(pgrep -d',' basic)