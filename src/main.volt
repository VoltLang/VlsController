// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
module main;

import core.rt.thread;
import lsp = vls.lsp;
import watt = [watt.path, watt.io, watt.io.file, watt.io.seed, watt.text.string,
	watt.process.spawn, watt.process.environment, watt.math.random];
import vlsc.util.aio;
import inputThread = vlsc.inputThread;
import streams = watt.io.streams;

fn main(args: string[]) i32
{
	initLog();
	chdirToExtensionDirectory();
	loop();
	return 0;
}

//! Change directory to the extension directory.
fn chdirToExtensionDirectory()
{
	watt.chdir(watt.dirName(watt.getExecFile()));
}

fn initLog()
{
	rng: watt.RandomGenerator;
	rng.seed(watt.getHardwareSeedU32());
	inputPath := watt.getEnv("USERPROFILE") ~ "/Desktop/vlscLog." ~ rng.randomString(4) ~ ".txt";
}

//! Launch the language server process.
fn spawnVls() watt.Pid
{
	return watt.spawnProcess("vls.exe", null);
}

//! Spawn a language server and wait for it to exit cleanly.
fn loop()
{
	t := vrt_thread_start_fn(inputThread.threadFunction);
	pool := new AsyncProcessPool();
	scope (exit) pool.cleanup();
	vls: AsyncProcess;

	retval: u32 = 1;

	fn report(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason)
	{
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			if (process.closedRetval == 0) {
				retval = process.closedRetval;
			} else {
				watt.error.writeln("VlsController: vls crashed, relaunching vls process.");
				watt.error.flush();
				vls = pool.respawn(process, "vls.exe", null);
			}
		} else if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := skipHeaders(process.readResult());
			if (str is null) {
				return;
			}
			lsp.send(str);
		}
	}

	
	vls = pool.spawn(report, "vls.exe", null);

	do {
		message: lsp.LspMessage;
		if (inputThread.getMessage(out message)) {
			lsp.send(message.content, vls);
		}
		pool.wait(ms:10);
	} while (retval != 0);
}

fn skipHeaders(str: string) string
{
	index := watt.indexOf(str, "{");
	if (index == -1) {
		return null;
	}
	return str[index .. $];
}
