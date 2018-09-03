// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
//! Asynchronous IO implementation for Unix/Unix-like OSes.
module vlsc.util.aio.unix;

import core.exception;
import watt.text.utf;
import watt.io.streams;

import vlsc.util.aio.common;

/*!
 * Write and read to long lived process's stdin and stdout.  
 *
 * Use `AsyncProcessPool.spawn` to create `AsyncProcess` objects,
 * and use `AsyncProcessPool.wait` to wait for input from one
 * of those processes, or for one of them to close.
 */
class AsyncProcessPool
{
private:
	mProcesses: AsyncProcess[];
	mRunning: bool = true;

public:
	/*!
	 * Clean up resources associated with the processes.  
	 * Call with `scope (exit)` after creating this pool.
	 */
	fn cleanup()
	{
		foreach (id, process; mProcesses) {
			process.cleanup();
		}
	}

	/*!
	 * Spawn an AsyncProcess.
	 *
	 * This pool manages all processes spawned through this method.
	 * Use this pool to determine if there is input to be read.
	 *
	 * @Param id A unique (for this pool) number to identify the process by.
	 * @Param filename The executable to spawn the process from.
	 * @Param args Command line argument to pass to the process (if any).
	 * @Returns The `AsyncProcess` object that was created.
	 */
	fn spawn(dgt: scope dg(AsyncProcess, InterruptReason), filename: string, args: string[]) AsyncProcess
	{
		p := new AsyncProcess(filename, args, this, dgt);
//		p.zeroOverlapped();
//		p.startRead();
		mProcesses ~= p;
		return p;
	}

	//! Like `spawn`, but spawn over an old process's slot.
	fn respawn(oldProcess: AsyncProcess, filename: string, args: string[]) AsyncProcess
	{
		foreach (ref process; mProcesses) {
			if (process is oldProcess) {
				process = new AsyncProcess(filename, args, this, oldProcess.mReportDelegate);
//				process.zeroOverlapped();
//				process.startRead();
				return process;
			}
		}
		throw new Exception("AsyncProcessPool.replace oldProcess not in process table");
	}

	/*!
	 * Wait for `ms` milliseconds, or for an event, whichever comes
	 * first.
	 */
	fn wait(ms: u32)
	{
		foreach (process; mProcesses) {
//			if (process.mDead) {
//				process.mReportDelegate(process, InterruptReason.ProcessComplete);
//			}
		}
//		SleepEx(ms, TRUE);
	}

private:
	fn readComplete(process: AsyncProcess)
	{
		process.mReportDelegate(process, InterruptReason.ReadComplete);
    }

	fn processComplete(process: AsyncProcess)
	{
		process.mReportDelegate(process, InterruptReason.ProcessComplete);
	}
}
/*!
 * Spawn a process with an asynchronous pipe to its input.
 *
 * The `write` call is wired to the child's stdin, and is a regular
 * blocking call. `read` is wired to the child's stdout, and uses
 * asynchronous IO.
 */
class AsyncProcess : OutputStream
{
public:
	enum BufSize = 4096;

public:
	closedRetval: u32;

public:
	fn readResult() string
	{
		return null;
	}

public:
	override fn close()
	{
	}

	override @property fn isOpen() bool
	{
		return false;
	}

	override fn flush()
	{
		/* If we flush sending to child processes, we're likely
		 * to deadlock. If we want this to flush, we can't write
		 * on the same thread as we read.
		 */
	}

private:
	mPool: AsyncProcessPool;
	mReportDelegate: scope dg(AsyncProcess, InterruptReason);

public:
	/*!
	 * Spawn a process from a path to an executable file.
	 */
	this(filename: string, args: string[], pool: AsyncProcessPool, reportDelegate: scope dg(AsyncProcess, InterruptReason))
	{
		mPool = pool;
		mReportDelegate = reportDelegate;
	}

	~this()
	{
		cleanup();
	}

public:
	/*!
	 * Close handles if they haven't been closed.
	 *
	 * This is called by the destructor, but should be manually
	 * called ASAP, usually via `scope (exit)`.
	 */
	fn cleanup()
	{
	}

	/*!
	 * Is the process still running?
	 *
	 * If the process is not running, this returns `false`
	 * and `retval` is set to the return value of the process.
	 */
	fn isAlive(out retval: u32) bool
	{
		return false;
	}

	/*!
	 * Write a single character to the process.  
	 * The process can read this from stdin.
	 */
	override fn put(c: dchar)
	{
		write(encode(c));
	}

	/*!
	 * Write a string to the process.  
	 * The process can read this from stdin.
	 */
	override fn write(s: scope const(char)[])
	{
	}
}