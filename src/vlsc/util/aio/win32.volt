// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
//! Windows implementation of asynchronous IO.
module vlsc.util.aio.win32;

import core.exception;
import core.c.string : memset;
import core.c.windows.windows;
import watt.process;
import watt.conv;
import watt.text.utf;
import watt.text.sink;
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
		p.zeroOverlapped();
		p.startRead();
		mProcesses ~= p;
		return p;
	}

	//! Like `spawn`, but spawn over an old process's slot.
	fn respawn(oldProcess: AsyncProcess, filename: string, args: string[]) AsyncProcess
	{
		foreach (ref process; mProcesses) {
			if (process is oldProcess) {
				process = new AsyncProcess(filename, args, this, oldProcess.mReportDelegate);
				process.zeroOverlapped();
				process.startRead();
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
			if (process.mDead) {
				process.mReportDelegate(process, InterruptReason.ProcessComplete);
			}
		}
		SleepEx(ms, TRUE);
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
		str := mStringSink.toString();
		mStringSink.reset();
		zeroOverlapped();
		startRead();
		return str;
	}

public:
	override fn close()
	{
	}

	override @property fn isOpen() bool
	{
		return !mDead;
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

	mProcessHandle: HANDLE;
	/* We keep and manage the handles here, rather than
	 * letting the input/output objects handle them so
	 * we can safely call `cleanup` in the destructor.
	 */
	mServerOutput, mClientInput: HANDLE;
	mServerInput, mClientOutput: HANDLE;

	mReadOverlapped: OVERLAPPED;
	mReadBuffer: u8[BufSize];
	mStringSink: StringSink;
	mDead: bool;


private:
	global gId: u64;  // For the pipe name.

public:
	/*!
	 * Spawn a process from a path to an executable file.
	 */
	this(filename: string, args: string[], pool: AsyncProcessPool, reportDelegate: scope dg(AsyncProcess, InterruptReason))
	{
		mPool = pool;
		mReportDelegate = reportDelegate;
		createPipes();
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
		cleanupHandle(ref mServerOutput);
		cleanupHandle(ref mServerInput);
		cleanupHandle(ref mProcessHandle);
		// These two should already be cleaned up, but just to be safe.
		cleanupHandle(ref mClientInput);
		cleanupHandle(ref mClientOutput);
	}

	/*!
	 * Is the process still running?
	 *
	 * If the process is not running, this returns `false`
	 * and `retval` is set to the return value of the process.
	 */
	fn isAlive(out retval: u32) bool
	{
		bResult := GetExitCodeProcess(mProcessHandle, &retval);
		if (bResult == 0) {
			err := GetLastError();
			throw new Exception(new "GetExitCodeProcess failure ${err}");
		}
		mDead = !(retval == STILL_ACTIVE);
		return !mDead;
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
		writeFile(cast(LPCVOID)s.ptr, cast(DWORD)s.length);
	}

private:
	fn cleanupHandle(ref handle: HANDLE)
	{
		if (handle !is null) {
			CloseHandle(handle);
			handle = null;
		}
	}

	/* Called when we have data to read, after readStart.  
	 * This gets called from the first callback that readStart sets up.
	 * This should be then called repeatedly, until there's no data on the pipe.
	 * At which point this process object sets itself back into a neutral state.  
	 * The parent pool is in charge of clearing the sync and calling readStart.
	 */
	fn readContent()
	{
		if (mDead) {
			return;
		}
		dwRead, dwAvail, dwThisMessage: DWORD;
		bResult := PeekNamedPipe(mServerInput, null, 0, &dwRead, &dwAvail, &dwThisMessage);
		checkErrorInAPC("PeekNamedPipe", bResult == 0);

		if (dwAvail == 0) {
			mPool.readComplete(this);
			return;
		}

		if (mDead) {
			return;
		}

		memset(cast(void*)&mReadOverlapped, 0, typeid(OVERLAPPED).size);
		mReadOverlapped.hEvent = cast(void*)this;
		bResult = ReadFileEx(mServerInput, cast(void*)mReadBuffer.ptr,
			cast(DWORD)mReadBuffer.length, &mReadOverlapped, readRoutine);
		checkErrorInAPC("ReadFileEx", bResult == 0);
	}

	// Zero the OVERLAPPED struct for this process.
	fn zeroOverlapped()
	{
		//mReadOverlapped = OVERLAPPED.init;  @TODO this should work
		memset(cast(void*)&mReadOverlapped, 0, typeid(OVERLAPPED).size);
	}

	// Start watching this process for available input.
	fn startRead()
	{
		if (mDead) {
			return;
		}
		if (mReadOverlapped.hEvent !is null) {
			throw new Exception("startEvent() called before completion of previous read");
		}
		mReadOverlapped.hEvent = cast(void*)this;
		bResult := ReadFileEx(mServerInput, null,
			0, &mReadOverlapped, readProbeRoutine);
		checkErrorInAPC("ReadFileEx", bResult == 0);
	}

	fn writeFile(ptr: LPCVOID, len: DWORD)
	{
		if (mDead) {
			return;
		}
		dwWritten: DWORD;
		bResult := WriteFile(mServerOutput, ptr, len, &dwWritten, null);
		if (bResult == 0) {
			err := GetLastError();
			if (!isAlive(out closedRetval)) {
				mReportDelegate(this, InterruptReason.ProcessComplete);
				return;
			}
			throw new Exception(new "WriteFile failure ${err}");
		}
		if (dwWritten != len) {
			throw new Exception("WriteFile didn't write all bytes to the synchronous handle");
		}
	}

	// Check a win32 function for error in a method called as a result of APC.
	fn checkErrorInAPC(functionName: string, isError: bool)
	{
		if (isError) {
			err := GetLastError();
			retval: u32;
			if (!isAlive(out closedRetval)) {
				mReportDelegate(this, InterruptReason.ProcessComplete);
				return;
			}
			throw new Exception(new "${functionName} failure ${err}");
		}
	}

	fn spawn(filename: string, args: string[])
	{
		mProcessHandle = spawnProcessWindows(filename, args, mClientInput,
			mClientOutput, GetStdHandle(STD_ERROR_HANDLE), null);
		// We don't need these ends of the pipes.
		cleanupHandle(ref mClientInput);
		cleanupHandle(ref mClientOutput);
	}

	fn createPipes()
	{
		saAttr: SECURITY_ATTRIBUTES;
		saAttr.nLength = cast(u32)typeid(saAttr).size;
		saAttr.bInheritHandle = true;
		saAttr.lpSecurityDescriptor = null;
		bResult := CreatePipe(&mClientInput, &mServerOutput, &saAttr, 0);
		if (bResult == 0) {
			err := GetLastError();
			throw new Exception(new "CreatePipe failure ${err}");
		}
		bResult = SetHandleInformation(mServerOutput, HANDLE_FLAG_INHERIT, 0);
		if (bResult == 0) {
			err := GetLastError();
			throw new ProcessException(new "SetHandleInformation failure ${err}");
		}

		readName := getPipeName();
		mServerInput = createPipe(pipeName:readName, writePipe:false);
		mClientOutput = createBlockingPipeEnd(pipeName:readName, writePipe:false);
	}

	fn getPipeName() string
	{
		return new "\\\\.\\pipe\\VlsController${getpid()}${gId++}";
	}

	//! Create a pipe, the server end.
	fn createPipe(pipeName: string, writePipe: bool) HANDLE
	{
		// No security attributes, we don't want this handle to be inheritable.
		handle := CreateNamedPipeA(
			toStringz(pipeName),
			(writePipe ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) |
			FILE_FLAG_OVERLAPPED, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE |
			PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, BufSize, BufSize, 0, null);
		
		if (cast(i32)handle == INVALID_HANDLE_VALUE) {
			throw new Exception(new "could not create pipe ${GetLastError()}");
		}

		return handle;
	}

	//! Open a client end to an existing pipe.
	fn createBlockingPipeEnd(pipeName: string, writePipe: bool) HANDLE
	{
		saAttr: SECURITY_ATTRIBUTES;
		saAttr.nLength = cast(u32)typeid(saAttr).size;
		saAttr.bInheritHandle = true;
		saAttr.lpSecurityDescriptor = null;
		// It's write from our perspective, read from the clients'.
		handle := CreateFileA(toStringz(pipeName), writePipe ? GENERIC_READ : GENERIC_WRITE,
			0, &saAttr, OPEN_EXISTING, 0, null);
		if (cast(i32)handle == INVALID_HANDLE_VALUE) {
			throw new Exception(new "could not open pipe ${GetLastError()}");
		}
		return handle;
	}
}

// Callback that indicates data is present on the pipe for us to read.
extern (Windows) fn readProbeRoutine(dwErrorCode: DWORD, dwNumberOfBytesTransferred: DWORD, lpOverlapped: LPOVERLAPPED)
{
	process := cast(AsyncProcess)lpOverlapped.hEvent;
	if (process.mDead) {
		return;
	}
	process.readContent();
}

// Callback that indicates actual data has been read.
extern (Windows) fn readRoutine(dwErrorCode: DWORD, dwNumberOfBytesTransferred: DWORD, lpOverlapped: LPOVERLAPPED)
{
	process := cast(AsyncProcess)lpOverlapped.hEvent;
	if (process.mDead) {
		return;
	}
	process.mStringSink.sink(cast(string)process.mReadBuffer[0 .. dwNumberOfBytesTransferred]);
	process.readContent();
}
