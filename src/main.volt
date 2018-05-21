// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
module main;

import lsp = vls.lsp;
import watt = [watt.path, watt.io, watt.io.file, watt.process.spawn];
import vlsc.util.aio;

fn main(args: string[]) i32
{
	chdirToExtensionDirectory();
	loop();
	return 0;
}

//! Change directory to the extension directory.
fn chdirToExtensionDirectory()
{
	watt.chdir(watt.dirName(watt.getExecFile()));
}

//! Launch the language server process.
fn spawnVls() watt.Pid
{
	return watt.spawnProcess("vls.exe", null);
}

//! Spawn a language server and wait for it to exit cleanly.
fn loop()
{
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
			str := process.readResult();
			lsp.send(str);
		}
	}

	vls = pool.spawn(report, "vls.exe", null);

	do {
		line := watt.input.readln();
		vls.writeln(line);
		pool.waitOnce();
	} while (retval != 0);
}
