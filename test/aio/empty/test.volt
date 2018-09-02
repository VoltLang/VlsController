module test;

import vlsc.util.aio;

fn main() i32
{
	pool := new AsyncProcessPool();
	scope (exit) pool.cleanup();
	return 0;
}