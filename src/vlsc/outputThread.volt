// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*!
 * A thread that handles sending output to the client and child processes.
 *
 * We have to be reading and writing to the pipes simultaneously to
 * prevent deadlock situations where one process is waiting on a write
 * and the other on a read and vice-versa.
 */
module vlsc.outputThread;

import io = [watt.io, watt.io.streams];
import stack = watt.containers.stack;
import lsp = vls.lsp;
import core.rt.thread;

//! Send messages in a loop.
fn threadFunction()
{
	while (gRunning) {
		processTasks();
		vrt_sleep(10);
	}
}

//! Queue a message to be sent over stdout.
fn addTask(message: string)
{
	addTask(message, io.output);
}

//! Queue a message to be sent over an output stream.
fn addTask(message: string, destination: io.OutputStream)
{
	vrt_mutex_lock(gLock);
	scope (exit) vrt_mutex_unlock(gLock);
	gTasks.push(Task.create(message, destination));
}

//! Stop the loop that is sending messages.
fn stop()
{
	gRunning = false;
}

private:

struct Task
{
public:
	message: string;
	destination: io.OutputStream;

public:
	global fn create(message: string, destination: io.OutputStream) Task
	{
		t: Task;
		t.message = message;
		t.destination = destination;
		return t;
	}
}

struct TaskStack = mixin stack.Stack!Task;

global gLock: vrt_mutex*;
global gTasks: TaskStack;
global gRunning := true;

global this()
{
	gLock = vrt_mutex_new();
}

global ~this()
{
	vrt_mutex_delete(gLock);
}

fn processTasks()
{
	do {
		task: Task;
		if (!getTask(out task)) {
			break;
		}
		if (task.destination is io.output) {
			lsp.send(task.message);
		} else {
			lsp.send(task.message, task.destination);
		}
	} while (true);
}

fn getTask(out task: Task) bool
{
	vrt_mutex_lock(gLock);
	scope (exit) vrt_mutex_unlock(gLock);
	if (gTasks.length == 0) {
		return false;
	}
	task = gTasks.pop();
	return true;
}
