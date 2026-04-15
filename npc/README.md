260408:log
● 已完成：现在运行仿真会输出 FST 
  波形文件，路径是 
  build/wave.fst。

  我做了两处必要改动：在 Makefile 的 
  Verilator
  参数里加入了 --trace-fst（通过 
  TRACE_FLAGS
  ），并在 csrc/main.cpp 中启用 
  tracing（
  Verilated::traceEverOn(true)、
  dut.trace(...)、
  tfp.open("build/wave.fst")、每个时
  钟沿 
  tfp.dump(...)）。
