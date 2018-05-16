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
import core.c.windows.windows;
import watt.process;
import watt.conv;

/*!
 * Spawn a process with an asynchronous pipe to its input.
 *
 * The `write` call is wired to the child's stdin, and is a regular
 * blocking call. `read` is wired to the child's stdout, and uses
 * asynchronous IO.
 */
class AsyncProcess
{
private:
	mProcessHandle: HANDLE;
	/* We keep and manage the handles here, rather than
	 * letting the input/output objects handle them so
	 * we can safely call `cleanup` in the destructor.
	 */
	mServerOutput, mClientInput: HANDLE;
	mServerInput, mClientOutput: HANDLE;
	mOverlapped: OVERLAPPED;

private:
	global gId: u64;

public:
	/*!
	 * Spawn a process from a path to an executable file.
	 */
	this(filename: string, args: string[])
	{
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
	 * If there is no input waiting, immediately return null.
	 * Otherwise, block until pending input is read.
	 */
	fn read() u8[]
	{
		dwRead, dwAvail, dwThisMessage: DWORD;
		bResult := PeekNamedPipe(mServerInput, null, 0, &dwRead, &dwAvail, &dwThisMessage);
		if (bResult == 0) {
			err := GetLastError();
			throw new Exception(new "PeekNamedPipe failure ${err}");
		}
		if (dwAvail == 0) {
			return null;
		}
		ol: OVERLAPPED;
		buf := new u8[](dwAvail);
		bResult = ReadFile(mServerInput,
			cast(LPVOID)buf.ptr, dwAvail,
			null, &ol);
		if (bResult != 0) {
			return buf[0 .. cast(size_t)ol.InternalHigh];
		}
		err := GetLastError();
		if (err != ERROR_IO_PENDING) {
			throw new Exception(new "ReadFile failure ${err}");
		}
		dwTransferred: DWORD;
		bResult = GetOverlappedResult(mServerInput, &ol, &dwTransferred, TRUE);
		if (bResult == 0) {
			err = GetLastError();
			throw new Exception(new "GetOverlappedResult failure ${err}");
		}
		io.error.writeln(new "${dwTransferred} / ${dwAvail}");
		return buf[0 .. dwTransferred];
	}

	fn put(c: dchar)
	{
		writeFile(cast(LPCVOID)&c, cast(DWORD)typeid(c).size);
	}

	fn write(s: scope const(char)[])
	{
		writeFile(cast(LPCVOID)s.ptr, cast(DWORD)s.length);
	}

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

	fn writeFile(ptr: LPCVOID, len: DWORD)
	{
		dwWritten: DWORD;
		bResult := WriteFile(mServerOutput, ptr, len, &dwWritten, null);
		if (bResult == 0) {
			err := GetLastError();
			throw new Exception(new "WriteFile failure ${err}");
		}
		if (dwWritten != len) {
			throw new Exception("uh");
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
			PIPE_NOWAIT, PIPE_UNLIMITED_INSTANCES, 1024, 1024, 0, null);
		
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
		// write from our perspective, read from the clients'
		handle := CreateFileA(toStringz(pipeName), writePipe ? GENERIC_READ : GENERIC_WRITE,
			0, &saAttr, OPEN_EXISTING, 0, null);
		if (cast(i32)handle == INVALID_HANDLE_VALUE) {
			throw new Exception(new "could not open pipe ${GetLastError()}");
		}
		return handle;
	}
}
