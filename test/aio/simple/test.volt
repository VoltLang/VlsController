//T macro:passpath
module test;

import watt.io;
import watt.path;
import watt.text.path;
import watt.text.string;

import vlsc.util.aio;

enum A1 = "Hello, world.";
enum B1 = "This is a test.";
enum C1 = "This is another test.";

enum A2 = "Hellu, world.";
enum B2 = "Thiu is a test.";
enum C2 = "Thus is another test.";

fn main(args: string[]) i32
{
	pool := new AsyncProcessPool();
	scope (exit) pool.cleanup();

	complete: i32;
	adone, bdone: bool;
	looping := true;

	fn report1(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason) {
		if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := strip(process.readResult());
			output.writeln(new "1:${str}"); output.flush();
			if (str == A1) {
				process.writeln(B1);
			}
			if (str == B1) {
				process.writeln(C1);
			}
			if (str == C1) {
				process.writeln("QUIT");
			}
		}
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			adone = true;
		}
		if (adone && bdone) {
			looping = false;
		}
	}

	fn report2(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason) {
		if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := strip(process.readResult());
			output.writeln(new "2:${str}"); output.flush();
			if (str == A2) {
				process.writeln(B2);
			}
			if (str == B2) {
				process.writeln(C2);
			}
			if (str == C2) {
				process.writeln("QUIT");
			}
		}
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			bdone = true;
		}
		if (adone && bdone) {
			looping = false;
		}
	}

	exe := getEchoExecutable(args[1]);
	p1  := pool.spawn(report1, exe, null);
	p2  := pool.spawn(report2, exe, null);
	p1.writeln(A1);
	p2.writeln(A2);

	while (looping) {
		pool.wait(10);
	}

	return adone && bdone ? 0 : 1;
}

fn getEchoExecutable(path: string) string
{
	thePath := fullPath(path);
	thePath  = concatenatePath(thePath, "../../../vtestEcho/VlsController.vtestEcho");
	version (Windows) {
		thePath ~= ".exe";
	}
	return normalisePath(thePath);
}