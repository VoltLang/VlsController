module main;

import watt.path;
import watt.io;
import watt.io.file;
import watt.process.spawn;

fn main(args: string[]) i32
{
	chdir(dirName(getExecFile()));
	pid := spawnProcess("vls.exe", args[1 .. $]);
	return pid.wait();
}
