// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
module main;

import core.rt.format : vrt_format_i64;
import core.rt.thread;
import lsp = vls.lsp;
import watt = [watt.path, watt.io, watt.io.file, watt.text.string,
	watt.process.spawn, watt.process.environment, watt.text.sink,
	watt.text.getopt, watt.io.streams];
import monotonic = watt.io.monotonic;
import json = watt.json;
import vlsc.util.aio;

import outputThread = vlsc.outputThread;
import inputThread = vlsc.inputThread;
import streams = watt.io.streams;

import diagnostics = vlsc.diagnostics;
import workspaces  = vlsc.workspaces;

fn main(args: string[]) i32
{
	inputFilename: string;
	if (watt.getopt(ref args, "input", ref inputFilename)) {
		inputThread.setInputFile(inputFilename);
	} else {
		inputThread.setStandardInput();
	}

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
	ithread := vrt_thread_start_fn(inputThread.threadFunction);
	othread := vrt_thread_start_fn(outputThread.threadFunction);

	pool := new AsyncProcessPool();
	scope (exit) pool.cleanup();
	vls: AsyncProcess;
	buildServer: AsyncProcess;

	retval: u32 = 1;

	// TODO: Make this cleaner, not duplicated nonsense

	fn vlsReport(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason)
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
			while (str.length != 0) {
				msg: lsp.LspMessage;
				str = lsp.parseLspMessage(str, out msg);
				if (watt.indexOf(msg.content, "textDocument/publishDiagnostics") > 0) {
					ro := new lsp.RequestObject(msg.content);
					if (ro.methodName == "textDocument/publishDiagnostics") {
						uri := lsp.getStringKey(ro.params, "uri");
						if (uri !is null) {
							diagnostics.emitLanguageServerDiagnostic(uri, msg.content);
							return;
						}
					}
				}
				outputThread.addTask(msg.content);
			}
		}
	}

	fn buildReport(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason)
	{
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			watt.error.writeln("VlsController: build server crashed, relaunching process.");
			watt.error.flush();
			vls = pool.respawn(process, "VlsBuildServer.exe", null);
		} else if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := process.readResult();
			while (str.length != 0) {
				msg: lsp.LspMessage;
				str = lsp.parseLspMessage(str, out msg);
				ro := new lsp.RequestObject(msg.content);
				handleBuildServerRequest(ro, vls);
			}
		}
	}

	vls = pool.spawn(vlsReport, "vls.exe", null);
	buildServer = pool.spawn(buildReport, "VlsBuildServer.exe", null); 

	do {
		message: lsp.LspMessage;
		if (inputThread.getMessage(out message)) {
			ro := new lsp.RequestObject(message.content);
			if (workspaces.handleRequest(ro)) {
				continue;
			} else if (handleBuildMessage(ro, ref message)) {
				outputThread.addTask(message.content, buildServer);
			} else {
				outputThread.addTask(message.content, vls);
			}
		}
		pool.wait(ms:1);
	} while (retval != 0 && !inputThread.done());

	outputThread.stop();
	vrt_thread_join(ithread);
	vrt_thread_join(othread);
}

fn handleBuildServerRequest(ro: lsp.RequestObject, vlsOutput: watt.OutputStream)
{
	switch (ro.methodName) {
	case "textDocument/publishDiagnostics":
		uri := lsp.getStringKey(ro.params, "uri");
		if (uri !is null) {
			buildTag := lsp.getStringKey(ro.params, "buildTag");
			diagnostics.emitBuildServerDiagnostic(uri, buildTag, ro.originalText);
			if (buildTag !is null) {
				outputThread.addTask(lsp.buildShowMessage(lsp.MessageType.Error, new "Build failure: ${buildTag}"));
			}
		}
		break;
	case "vls/buildSuccess":
		buildTag := lsp.getStringKey(ro.params, "buildTag");
		if (buildTag !is null) {
			diagnostics.clearBuildTag(buildTag);
		}
		outputThread.addTask(lsp.buildShowMessage(lsp.MessageType.Info, new "Build success: ${buildTag}"));
		break;
	case "vls/buildFailure":
		buildTag := lsp.getStringKey(ro.params, "buildTag");
		outputThread.addTask(lsp.buildShowMessage(lsp.MessageType.Error, new "Build failure: ${buildTag}"));
		break;
	case "vls/buildPending":
		buildTag := lsp.getStringKey(ro.params, "buildTag");
		outputThread.addTask(lsp.buildShowMessage(lsp.MessageType.Warning, new "Old build still running: ${buildTag}"));
		break;
	case "vls/toolchainPresent":
		outputThread.addTask(ro.originalText, vlsOutput);
		break;
	case "vls/toolchainRetrievalFailure":
		if (shouldShowDownloadFailureMessage()) {
			outputThread.addTask(lsp.buildShowMessage(lsp.MessageType.Warning, "Toolchain archive could not be retrieved."));
		}
		break;
	default:
		break;
	}
}

/*!
 * Is given request a build server request?
 *
 * If `ro` is a message that should be passed to the
 * build server, perform any modifications required
 * to it and return `true`. Otherwise the request is
 * untouched, and `false` is returned.
 */
fn handleBuildMessage(ro: lsp.RequestObject, ref message: lsp.LspMessage) bool
{
	if (ro.methodName != "workspace/executeCommand") {
		return false;
	}
	command := lsp.getStringKey(ro.params, "command");
	switch (command) {
	case "vls.buildProject":
		return true;
	case "vls.buildAllProjects":
		message.content = getBuildAllContent(ro);
		return true;
	default:
		return false;
	}
}

fn getBuildAllContent(ro: lsp.RequestObject) string
{
	ss: watt.StringSink;
	ss.sink(`{"jsonrpc":"2.0","id":`);
	vrt_format_i64(ss.sink, ro.id.integer());
	ss.sink(`,"method":"workspace/executeCommand","params":{"command":"vls.buildAllProjects","arguments":[{},[]],`);
	ss.sink(`"workspaceUris":[`);
	uris := workspaces.getUris();
	foreach (i, uri; uris) {
		ss.sink(`"`);
		ss.sink(uri);
		ss.sink(`"`);
		if (i < uris.length - 1) {
			ss.sink(`,`);
		}
	}
	ss.sink(`]}}`);
	return ss.toString();
}

private:

global gLastDownloadFailure: i64;
global gNextDownloadFailure: i64;
global gStep:                i64;  // seconds

fn shouldShowDownloadFailureMessage() bool
{
	if (monotonic.ticks() >= gNextDownloadFailure) {
		gLastDownloadFailure = monotonic.ticks();
		nextStep();
		return true;
	}
	return false;
}

fn nextStep()
{
	switch (gStep) {
	case 0:
		gStep += 5;
		break;
	case 5:
		gStep += 10;
		break;
	case 15:
		gStep = 60;
		break;
	case 60:
		break;
	default:
		assert(false);
	}
	gNextDownloadFailure = gLastDownloadFailure + (gStep * monotonic.ticksPerSecond);
}
