module vlsc.util.aio.common;

//! The reason wait returned.
enum InterruptReason
{
	Invalid,            //!< A valid reason was not given. This will not be returned by `wait`.
	ReadContinues,      //!< A read has started or continues. This will not be returned by `wait`.
	ReadComplete,       //!< The process has completed a read operation.
	ProcessComplete,    //!< The process has exited.
}