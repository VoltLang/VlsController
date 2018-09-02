//! This vtestEcho utility executable is used to test the AIO module.
module main;

import io = watt.io;

fn main() i32
{
	while (!io.input.eof()) {
		inputLine := io.input.readln();
		if (inputLine == "QUIT") {
			break;
		}
		io.output.writeln(inputLine);
		io.output.flush();
	}
	return 0;
}