module vlsc.util.aio;

public import vlsc.util.aio.common;

version (Windows) {
	public import vlsc.util.aio.win32;
} else {
	public import vlsc.util.aio.unix;
}

alias ReportDelegate = scope dg(AsyncProcess, InterruptReason);
