// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*!
 * A thread that checks vlsc's input for client messages.
 */
module vlsc.inputThread;

import io = watt.io;
import lsp = vls.lsp;
import core.rt.thread;

private global gLock: vrt_mutex*;  // This lock covers reading or writing all of the g* stuff here.
private global gMessage: lsp.LspMessage;
private global gMessageEmpty: bool = true;

global this()
{
	gLock = vrt_mutex_new();
}

global ~this()
{
	vrt_mutex_delete(gLock);
}

/*!
 * Fill the message slot until LSP says to stop.
 */
fn threadFunction()
{
	fn listenDg(msg: lsp.LspMessage) bool
	{
		insertMessage(msg);
		return true;
	}
	while (lsp.listen(listenDg, io.input)) {
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

// Block until we successfully write the message to the slot.
private fn insertMessage(message: lsp.LspMessage)
{
	do {
		if (tryInsertMessage(message)) {
			return;
		}
		vrt_sleep(10);
	} while (true);
}

// Write the given message to the slot and return true, or fail and return false.
private fn tryInsertMessage(message: lsp.LspMessage) bool
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
