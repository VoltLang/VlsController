// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
module main;

import lsp = vls.lsp;
import watt = [watt.path, watt.io, watt.io.file, watt.process.spawn];

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
	pid: watt.Pid;
	retval: i32;
	do {
		pid = spawnVls();
		retval = pid.wait();
		if (retval != 0) {
			watt.error.writeln("VlsController: vls crashed, relaunching vls process.");
			watt.error.flush();
		}
	} while (retval != 0);
}
