// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*!
 * A thread that checks vlsc's input for client messages.
 */
module vlsc.inputThread;

import io = [watt.io, watt.io.streams];
import lsp = vls.lsp;
import core.rt.thread;

fn done() bool
{
	return gDone;
}

/*!
 * Read input from a file.
 */
fn setInputFile(filename: string)
{
	vrt_mutex_lock(gLock);
	scope (exit) vrt_mutex_unlock(gLock);
	gInputStream = new io.InputFileStream(filename);
}

/*!
 * Read input from stdin.
 */
fn setStandardInput()
{
	/* In a perfect world we'd do this in the global
	 * constructor, but as it stands there's a chance
	 * that our global constructor runs *after* watt.io's,
	 * and io.input could be null.
	 */
	gInputStream = io.input;
}

/*!
 * Fill the message slot until LSP says to stop.
 */
fn threadFunction()
{
	assert(gInputStream !is null);
	fn listenDg(msg: lsp.LspMessage) bool
	{
		insertMessage(msg);
		return true;
	}
	while (lsp.listen(listenDg, gInputStream)) {
	}
	gDone = true;
	while (!gMessageEmpty) {
		vrt_sleep(10);
	}
}

/*!
 * Copy the pending message if present.
 *
 * If there is a pending message, copy it to `message`
 * and return `true`. If there is no message present,
 * `message` is invalid and this function returns `false`.
 */
fn getMessage(out message: lsp.LspMessage) bool
{
	vrt_mutex_lock(gLock);
	scope (exit) vrt_mutex_unlock(gLock);
	if (gMessageEmpty) {
		return false;
	}
	message = gMessage.dup;
	gMessageEmpty = true;
	return true;
}

private:

global this()
{
	gLock = vrt_mutex_new();
}

global ~this()
{
	vrt_mutex_delete(gLock);
}

global gLock: vrt_mutex*;  // This lock covers reading or writing all of the g* stuff here.
global gMessage: lsp.LspMessage;
global gMessageEmpty: bool = true;
global gInputStream: io.InputStream;
global gDone: bool;

//! Block until we successfully write the message to the slot.
fn insertMessage(message: lsp.LspMessage)
{
	do {
		if (tryInsertMessage(message)) {
			return;
		}
		vrt_sleep(10);
	} while (true);
}

//! Write the given message to the slot and return true, or fail and return false.
fn tryInsertMessage(message: lsp.LspMessage) bool
{
	vrt_mutex_lock(gLock);
	scope (exit) vrt_mutex_unlock(gLock);
	if (!gMessageEmpty) {
		return false;
	}
	gMessage = message;
	gMessageEmpty = false;
	return true;
}
