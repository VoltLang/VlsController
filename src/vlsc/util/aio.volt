// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*
 * 08:17 <+Prf_Jakob> Also it's okay if the controller is win32 only for now, so
 *                 feel free to hack together Win32 API based Async IO for all
 *                 of this in the controller repo.
 * 08:17 <+Prf_Jakob> I can deal with posix/linux/osx version of it
 */
module vlsc.util.aio;

import core.exception;
import core.c.string : memset;
import core.c.windows.windows;
import watt.process;
import watt.conv;
import watt.text.utf;
import watt.text.sink;


/*!
 * Write and read to long lived process's stdin and stdout.  
 *
 * Use `AsyncProcessPool.spawn` to create `AsyncProcess` objects,
 * and use `AsyncProcessPool.wait` to wait for input from one
 * of those processes, or for one of them to close.
 */
class AsyncProcessPool
{
public:
	//! The reason wait returned.
	enum InterruptReason
	{
		Invalid,            //!< A valid reason was not given. This will not be returned by `wait`.
		ReadContinues,      //!< A read has started or continues. This will not be returned by `wait`.
		ReadComplete,       //!< The process has completed a read operation.
		ProcessComplete,    //!< The process has exited.
	}

private:
	mProcesses: AsyncProcess[size_t];
	mWakeUpReason: InterruptReason;
	mWakeUpId: size_t;
	mDiedTooYoung: size_t[];  // Processes that died before we had a chance to issue an APC call.

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
	fn spawn(id: size_t, filename: string, args: string[]) AsyncProcess
	{
		p := new AsyncProcess(filename, args, this, id);
		p.zeroOverlapped();
		p.startRead();
		mProcesses[id] = p;
		return p;
	}

	/*!
	 * Get the return value of the process associated with `id`.
	 */
	fn getRetval(id: size_t) u32
	{
		p := id in mProcesses;
		if (p is null) {
			throw new Exception("passed invalid process id to AsyncProcessPool.getRetval");
		}
		retval: u32;
		if (p.isAlive(out retval)) {
			throw new Exception("called AsyncProcessPool.getRetval for a running process");
		}
		return retval;
	}

	/*!
	 * Get the input read from the process associated with `id`.  
	 * This clears the internal buffer, and starts a new async read operation;
	 * if you discard this data, there's no way to retrieve it.
	 */
	fn getReadResult(id: size_t) string
	{
		p := id in mProcesses;
		if (p is null) {
			throw new Exception("passed invalid process id to AsyncProcessPool.getReadResult");
		}
		str := p.mStringSink.toString();
		p.mStringSink.reset();
		p.zeroOverlapped();
		p.startRead();
		return str;
	}

	fn wait(out id: size_t) InterruptReason
	{
		if (mDiedTooYoung.length != 0) {
			id = mDiedTooYoung[0];
			mDiedTooYoung = mDiedTooYoung[1 .. $];
			return InterruptReason.ProcessComplete;
		}
		while (true) {
			mWakeUpReason = InterruptReason.Invalid;
			SleepEx(INFINITE, TRUE);
			if (mWakeUpReason == InterruptReason.Invalid) {
				throw new Exception("woke up with no reason set");
			}
			if (mWakeUpReason == InterruptReason.ReadContinues) {
				continue;
			}
			break;
		}
		retval: u32;
		p := mProcesses[mWakeUpId];
		if (!p.isAlive(out retval) && mWakeUpReason != InterruptReason.ProcessComplete) {
			// Let the user get the input, but call it dead next time wait is called.
			mDiedTooYoung ~= p.mId;
			p.mDead = true;
		}

		assert(mWakeUpReason != InterruptReason.Invalid);
		assert(mWakeUpReason != InterruptReason.ReadContinues);
		id = mWakeUpId;
		return mWakeUpReason;
	}

private:
	fn readContinues(id: size_t)
	{
		mWakeUpId = id;
		mWakeUpReason = InterruptReason.ReadContinues;
	}

	fn readComplete(id: size_t)
	{
		mWakeUpId = id;
		mWakeUpReason = InterruptReason.ReadComplete;
    }

	fn processComplete(id: size_t)
	{
		mWakeUpId = id;
		mWakeUpReason = InterruptReason.ProcessComplete;
		mProcesses[id].mDead = true;
	}
}

/*!
 * Spawn a process with an asynchronous pipe to its input.
 *
 * The `write` call is wired to the child's stdin, and is a regular
 * blocking call. `read` is wired to the child's stdout, and uses
 * asynchronous IO.
 */
class AsyncProcess
{
public:
	enum BufSize = 1024;

private:
	mPool: AsyncProcessPool;
	mId: size_t;

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
	global gId: u64;

public:
	/*!
	 * Spawn a process from a path to an executable file.
	 */
	this(filename: string, args: string[], pool: AsyncProcessPool, id: size_t)
	{
		mPool = pool;
		mId = id;
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
		return retval == STILL_ACTIVE;
	}

	/*!
	 * Write a single character to the process.  
	 * The process can read this from stdin.
	 */
	fn put(c: dchar)
	{
		write(encode(c));
	}

	/*!
	 * Write a string to the process.  
	 * The process can read this from stdin.
	 */
	fn write(s: scope const(char)[])
	{
		writeFile(cast(LPCVOID)s.ptr, cast(DWORD)s.length);
	}

	/*!
	 * Write a string and a newline character to the process.  
	 * The process can read this from stdin.
	 */
	fn writeln(s: scope const(char)[])
	{
		write(s);
		put('\n');
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
		dwRead, dwAvail, dwThisMessage: DWORD;
		bResult := PeekNamedPipe(mServerInput, null, 0, &dwRead, &dwAvail, &dwThisMessage);
		checkErrorInAPC("PeekNamedPipe", bResult == 0);

		if (dwAvail == 0) {
			mPool.readComplete(mId);
			return;
		}

		memset(cast(void*)&mReadOverlapped, 0, typeid(OVERLAPPED).size);
		mReadOverlapped.hEvent = cast(void*)this;
		bResult = ReadFileEx(mServerInput, cast(void*)mReadBuffer.ptr,
			cast(DWORD)mReadBuffer.length, &mReadOverlapped, readRoutine);
		checkErrorInAPC("ReadFileEx", bResult == 0);

		mPool.readContinues(mId);
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
			retval: u32;
			if (!isAlive(out retval)) {
				mDead = true;
				mPool.mDiedTooYoung ~= mId;
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
			if (!isAlive(out retval)) {
				mPool.processComplete(mId);
				return;
			}
			throw new Exception(new "${functionName} failure ${err}");
		}
	}

	fn spawn(filename: string, args: string[])
	{
		mProcessHandle = spawnProcessWindows(filename, args, mClientInput,
			mClientOutput, mClientOutput, null);
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
			PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 1024, 1024, 0, null);
		
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
		process.mPool.readContinues(process.mId);
		return;
	}
	process.readContent();
}

// Callback that indicates actual data has been read.
extern (Windows) fn readRoutine(dwErrorCode: DWORD, dwNumberOfBytesTransferred: DWORD, lpOverlapped: LPOVERLAPPED)
{
	process := cast(AsyncProcess)lpOverlapped.hEvent;
	if (process.mDead) {
		process.mPool.readContinues(process.mId);
		return;
	}
	process.mStringSink.sink(cast(string)process.mReadBuffer[0 .. dwNumberOfBytesTransferred]);
	process.readContent();
}
