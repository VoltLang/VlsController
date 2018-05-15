// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
/*
 * 08:17 <+Prf_Jakob> Also it's okay if the controller is win32 only for now, so
 *                 feel free to hack together Win32 API based Async IO for all
 *                 of this in the controller repo.
 * 08:17 <+Prf_Jakob> I can deal with posix/linux/osx version of it
 */
module vlsc.util.aio;

class Pipe
{
}
module main;

import io = watt.io;
import core.exception;
import core.c.windows.windows;
import watt.io.streams;
import watt.process;
import watt.conv;

enum N = 5;

fn main(args: string[]) i32
{
	children: AsyncProcess[N];
//	foreach (i; 0 .. N) {
		children[0] = new AsyncProcess("Child.exe", null);
//	}
	while (true) {
	}
}

enum BufSize = 1;

/*!
 * Class that spawns a process and supports asynchronous reads and writes
 * from the parents end, while the child process using standard blocking
 * input and output.
 */
class AsyncProcess
{
public:
	//! Stream for reading from the child process.
	input: AsyncInput;

	//! Stream for writing to the process.
	output: AsyncOutput;

private:
	mProcessHandle: HANDLE;

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

public:
	/*!
	 * Close handles etc.
	 */
	fn cleanup()
	{
		if (input !is null) {
			input.cleanup();
			input = null;
		}
		if (output !is null) {
			output.cleanup();
			output = null;
		}
		if (mProcessHandle !is null) {
			CloseHandle(mProcessHandle);
			mProcessHandle = null;
		}
	}

private:
	fn spawn(filename: string, args: string[])
	{
		io.writeln(new "CREATING PIPE ${gId}");
		io.output.flush();
		mProcessHandle = spawnProcessWindows(filename, args, output.mBlockHandle,
			input.mBlockHandle, null, null);
	}

	fn createPipes()
	{
		writeName := getPipeName();
		writeHandle := createPipe(pipeName:writeName, writePipe:true);
		writeBlock  := createBlockingPipeEnd(pipeName:writeName, writePipe:true);
		output = new AsyncOutput(writeHandle, writeBlock);

		readName := getPipeName();
		readHandle  := createPipe(pipeName:readName, writePipe:false);
		readBlock   := createBlockingPipeEnd(pipeName:readName, writePipe:false);
		input = new AsyncInput(readHandle, readBlock);
	}

	fn getPipeName() string
	{
		return new "\\\\.\\pipe\\VlsController${gId++}";
	}

	fn createPipe(pipeName: string, writePipe: bool) HANDLE
	{
		saAttr: SECURITY_ATTRIBUTES;
		saAttr.nLength = cast(u32)typeid(saAttr).size;
		saAttr.bInheritHandle = true;
		saAttr.lpSecurityDescriptor = null;

		handle := CreateNamedPipeA(
			toStringz(pipeName),
			(writePipe ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) |
			FILE_FLAG_OVERLAPPED, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE |
			PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, BufSize, BufSize, 0, &saAttr);
		
		if (cast(i32)handle == INVALID_HANDLE_VALUE) {
			throw new Exception(new "could not create pipe ${GetLastError()}");
		}

		if (!writePipe) {
			bRet := SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
			if (!bRet) {
				throw new Exception("failed to set pipeRead info");
			}
		}

		return handle;
	}

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

class AsyncInput : InputStream
{
private:
	mAsyncHandle: HANDLE;
	mBlockHandle: HANDLE;

public:
	this(async: HANDLE, block: HANDLE)
	{
		mAsyncHandle = async;
		mBlockHandle = block;
	}

public:
	fn cleanup()
	{
		CloseHandle(mAsyncHandle);
		CloseHandle(mBlockHandle);
	}

public:
	override fn close()
	{
	}

	@property override fn isOpen() bool
	{
		return false;
	}

	override fn get() dchar
	{
		return '\0';
	}

	override fn read(buffer: u8[]) u8[]
	{
		return null;
	}

	override fn eof() bool
	{
		return true;
	}
}

class AsyncOutput : OutputStream
{
private:
	mAsyncHandle: HANDLE;
	mBlockHandle: HANDLE;

public:
	this(async: HANDLE, block: HANDLE)
	{
		mAsyncHandle = async;
		mBlockHandle = block;
	}

public:
	fn cleanup()
	{
		CloseHandle(mAsyncHandle);
		CloseHandle(mBlockHandle);
	}

public:
	override fn close()
	{
	}

	@property override fn isOpen() bool
	{
		return false;
	}

	override fn put(c: dchar)
	{
	}

	override fn flush()
	{
	}
}
