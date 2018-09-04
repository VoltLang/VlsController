// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
//! Asynchronous IO implementation for Unix/Unix-like OSes.
module vlsc.util.aio.unix;

import core.exception;
import core.c.posix.unistd;
import core.c.posix.sys.select;
import core.c.posix.sys.time;
import core.c.posix.fcntl;
import watt.conv;
import watt.process;
import watt.text.utf;
import watt.io.streams;

import vlsc.util.aio.common;

private enum WNOHANG = 1;

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
	mFdSet: fd_set;

public:
	this()
	{
	}

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
		mProcesses ~= p;
		return p;
	}

	//! Like `spawn`, but spawn over an old process's slot.
	fn respawn(oldProcess: AsyncProcess, filename: string, args: string[]) AsyncProcess
	{
		foreach (ref process; mProcesses) {
			if (process is oldProcess) {
				process = new AsyncProcess(filename, args, this, oldProcess.mReportDelegate);
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
		readSet: fd_set;
		FD_ZERO(&readSet);

		nfds: i32;
		foreach (process; mProcesses) {
			if (!process.isAlive) {
				process.mReportDelegate(process, InterruptReason.ProcessComplete);
			} else {
				FD_SET(process.readFd, &readSet);
				if (process.readFd > nfds) {
					nfds = process.readFd;
				}
			}
		}
		nfds++;

		tv: timeval;
		tv.tv_sec  = ms / 1000;
		tv.tv_usec = (ms % 1000) * 1000;

		retval := select(nfds, &readSet, null, null, &tv);
		if (retval == 0) {
			// time out
			return;
		} else if (retval == -1) {
			throw new Exception("select() failure");
		}

		fn getProcess(fd: i32) AsyncProcess
		{
			foreach (process; mProcesses) {
				if (process.readFd == fd) {
					return process;
				}
			}
			throw new Exception("couldn't find ready process associated with fd");
		}

		for (i: i32 = 0; i < nfds && retval > 0; ++i) {
			if (FD_ISSET(i, &readSet)) {
				retval--;
				p := getProcess(i);
				/* This is obviously wrong.
				 * TODO: Replace with actual working (for large input sets) code.
				 */
				buf := new char[](AsyncProcess.BufSize);
				n := read(i, cast(void*)buf.ptr, buf.length);
				if (n <= 0) {
					throw new Exception("read() failure");
				}
				p.mResultString = cast(string)buf[0 .. n];
			}
		}
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
		return mResultString;
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
	mChildPid: pid_t;
	mParent2Child: i32[2];
	mChild2Parent: i32[2];
	mResultString: string;

public:
	/*!
	 * Spawn a process from a path to an executable file.
	 */
	this(filename: string, args: string[], pool: AsyncProcessPool, reportDelegate: scope dg(AsyncProcess, InterruptReason))
	{
		mPool = pool;
		mReportDelegate = reportDelegate;
		spawn(filename, args);
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
	@property fn isAlive() bool
	{
		status: i32;
		if (waitpid(mChildPid, &status, WNOHANG) != 0) {
			closedRetval = cast(u32)status;
			return true;
		}
		return false;
	}

	/*!
	 * Return the file descriptor that the parent process
	 * must read from to retrieve the child process's output.
	 */
	@property fn readFd() i32
	{
		return mChild2Parent[0];
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
		.write(mParent2Child[1], cast(void*)s.ptr, s.length);
	}

private:
	fn spawn(filename: string, args: string[])
	{
		createPipe(ref mParent2Child);
		createPipe(ref mChild2Parent);
		setNonBlocking(mChild2Parent[0]);
		mChildPid = spawnProcessPosix(
			filename, args,    // the executable to spawn, and its arguments
			mParent2Child[0],  // standard input
			mChild2Parent[1],  // standard output
			STDERR_FILENO,     // standard error
			null               // use default environment
		);
	}

	fn createPipe(ref pipefd: i32[2])
	{
		retval := pipe(ref pipefd);
		if (retval != 0) {
			throw new Exception("pipe() failure");
		}
	}

	fn setNonBlocking(fd: i32)
	{
		flags := fcntl(fd, F_GETFL);
		if (flags == -1) {
			throw new Exception("fcntl() failed to retrieve FD flags");
		}
		retval := fcntl(fd, F_SETFL, flags | O_NONBLOCK);
		if (retval == -1) {
			throw new Exception("fcntl() failed to set FD to non-blocking");
		}
	}
}
