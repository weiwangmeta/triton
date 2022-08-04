// RUN: triton-opt %s --mlir-disable-threading -test-print-allocation 2>&1 | FileCheck %s

#AL = #triton_gpu.blocked<{sizePerThread = [1, 4], threadsPerWarp = [4, 8], warpsPerCTA = [4, 1], order = [1, 0]}>
#BL = #triton_gpu.blocked<{sizePerThread = [1, 4], threadsPerWarp = [1, 32], warpsPerCTA = [4, 1], order = [1, 0]}>
#A = #triton_gpu.shared<{vec = 2, perPhase = 2, maxPhase = 4, order = [1, 0]}>
#B = #triton_gpu.shared<{vec = 2, perPhase = 2, maxPhase = 4, order = [1, 0]}>
#C = #triton_gpu.mma<{version = 2, warpsPerCTA = [4, 1]}>

func @matmul_loop(%lb : index, %ub : index, %step : index, %A : !tt.ptr<f16>, %B : !tt.ptr<f16>) {
  %a_ptr_init = tt.broadcast %A : (!tt.ptr<f16>) -> tensor<128x32x!tt.ptr<f16>, #AL>
  %b_ptr_init = tt.broadcast %B : (!tt.ptr<f16>) -> tensor<32x128x!tt.ptr<f16>, #BL>

  %a_mask = arith.constant dense<true> : tensor<128x32xi1, #AL>
  %a_other = arith.constant dense<0.00e+00> : tensor<128x32xf16, #AL>
  %b_mask = arith.constant dense<true> : tensor<32x128xi1, #BL>
  %b_other = arith.constant dense<0.00e+00> : tensor<32x128xf16, #BL>
  %c_init = arith.constant dense<0.00e+00> : tensor<128x128xf32, #C>

  %a_off = arith.constant dense<4> : tensor<128x32xi32, #AL>
  %b_off = arith.constant dense<4> : tensor<32x128xi32, #BL>

  scf.for %iv = %lb to %ub step %step iter_args(%a_ptr = %a_ptr_init, %b_ptr = %b_ptr_init, %prev_c = %c_init) -> (tensor<128x32x!tt.ptr<f16>, #AL>, tensor<32x128x!tt.ptr<f16>, #BL>, tensor<128x128xf32, #C>) {
    %a_ = tt.load %a_ptr, %a_mask, %a_other {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<128x32xf16, #AL>
    // CHECK: offset = 0, size = 8192
    %a = triton_gpu.convert_layout %a_ : (tensor<128x32xf16, #AL>) -> tensor<128x32xf16, #A>
    %b_ = tt.load %b_ptr, %b_mask, %b_other {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<32x128xf16, #BL>
    // CHECK: offset = 8192, size = 8192
    %b = triton_gpu.convert_layout %b_ : (tensor<32x128xf16, #BL>) -> tensor<32x128xf16, #B>

    %c = tt.dot %a, %b, %prev_c {allowTF32 = true} : tensor<128x32xf16, #A> * tensor<32x128xf16, #B> -> tensor<128x128xf32, #C>

    %next_a_ptr = tt.getelementptr %a_ptr, %a_off : tensor<128x32x!tt.ptr<f16>, #AL>
    %next_b_ptr = tt.getelementptr %b_ptr, %b_off : tensor<32x128x!tt.ptr<f16>, #BL>
    scf.yield %next_a_ptr, %next_b_ptr, %c : tensor<128x32x!tt.ptr<f16>, #AL>, tensor<32x128x!tt.ptr<f16>, #BL>, tensor<128x128xf32, #C>
  }
  return
  // CHECK: size = 16384
}

// Shared memory is available after a tensor's liveness range ends
func @synthesized_reusable(%A : !tt.ptr<f16>) {
  %cst1 = arith.constant dense<true> : tensor<128x32xi1, #AL>
  %cst2 = arith.constant dense<0.000000e+00> : tensor<128x32xf16, #AL>
  %cst3 = arith.constant dense<true> : tensor<32x128xi1, #AL>
  %cst4 = arith.constant dense<0.000000e+00> : tensor<32x128xf16, #AL>
  %c_init = arith.constant dense<0.00e+00> : tensor<128x128xf32, #C>

  %a_ptr = tt.broadcast %A : (!tt.ptr<f16>) -> tensor<128x32x!tt.ptr<f16>, #AL>
  %b_ptr = tt.broadcast %A : (!tt.ptr<f16>) -> tensor<32x128x!tt.ptr<f16>, #AL>
  %a1_ = tt.load %a_ptr, %cst1, %cst2 {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<128x32xf16, #AL>
  // CHECK: offset = 0, size = 8192 
  %a1 = triton_gpu.convert_layout %a1_ : (tensor<128x32xf16, #AL>) -> tensor<128x32xf16, #A>
  %a2_ = tt.load %b_ptr, %cst3, %cst4 {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<32x128xf16, #AL>
  // CHECK: offset = 8192, size = 8192
  %a2 = triton_gpu.convert_layout %a2_ : (tensor<32x128xf16, #AL>) -> tensor<32x128xf16, #A>
  %a3_ = tt.load %a_ptr, %cst1, %cst2 {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<128x32xf16, #AL>
  // CHECK: offset = 16384, size = 8192
  %a3 = triton_gpu.convert_layout %a3_ : (tensor<128x32xf16, #AL>) -> tensor<128x32xf16, #A>
  %c = tt.dot %a1, %a2, %c_init {allowTF32 = true} : tensor<128x32xf16, #A> * tensor<32x128xf16, #B> -> tensor<128x128xf32, #C>
  %a4_ = tt.load %b_ptr, %cst3, %cst4 {cache = 1 : i32, evict = 1 : i32, isVolatile = false} : tensor<32x128xf16, #AL>
  // CHECK: offset = 0, size = 8192
  %a4 = triton_gpu.convert_layout %a4_ : (tensor<32x128xf16, #AL>) -> tensor<32x128xf16, #A>
  %c1 = tt.dot %a3, %a4, %c {allowTF32 = true} : tensor<128x32xf16, #A> * tensor<32x128xf16, #B> -> tensor<128x128xf32, #C>
  return
  // CHECK: size = 24576
}

// A tensor's shared memory offset is larger than it needs to accommodate further tensors
// %cst0->%c
// %cst1->%cst4
// %cst3->%g->%h->%i
func @synthesize_preallocate(%A : !tt.ptr<f16>) {
  // CHECK: offset = 0, size = 512
  %cst0 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1024, size = 512
  %cst1 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1536, size = 512
  %cst2 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 2048, size = 1024
  %a = tt.cat %cst0, %cst1 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 3072, size = 1024
  %b = tt.cat %cst0, %cst2 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 0, size = 1024
  %c = tt.cat %cst1, %cst2 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 1024, size = 1024
  %cst4 = arith.constant dense<0.000000e+00> : tensor<32x16xf16, #A>
  // CHECK: offset = 6144, size = 2048
  %e = tt.cat %a, %cst4 {axis = 0} : (tensor<32x16xf16, #A>, tensor<32x16xf16, #A>) -> tensor<64x16xf16, #A>
  // CHECK: offset = 8192, size = 2048
  %d = tt.cat %b, %cst4 {axis = 0} : (tensor<32x16xf16, #A>, tensor<32x16xf16, #A>) -> tensor<64x16xf16, #A>
  // CHECK: offset = 10240, size = 2048
  %f = tt.cat %c, %cst4 {axis = 0} : (tensor<32x16xf16, #A>, tensor<32x16xf16, #A>) -> tensor<64x16xf16, #A>
  // CHECK: offset = 0, size = 2048
  %cst5 = arith.constant dense<0.000000e+00> : tensor<64x16xf16, #A>
  // CHECK: offset = 2048, size = 4096
  %g = tt.cat %e, %cst5 {axis = 0} : (tensor<64x16xf16, #A>, tensor<64x16xf16, #A>) -> tensor<128x16xf16, #A>
  // CHECK: offset = 2048, size = 4096
  %h = tt.cat %d, %cst5 {axis = 0} : (tensor<64x16xf16, #A>, tensor<64x16xf16, #A>) -> tensor<128x16xf16, #A>
  // CHECK: offset = 2048, size = 4096
  %i = tt.cat %f, %cst5 {axis = 0} : (tensor<64x16xf16, #A>, tensor<64x16xf16, #A>) -> tensor<128x16xf16, #A>
  return
  // CHECK: size = 12288
}

// Unused tensors are immediately released
func @synthesize_unused(%A : !tt.ptr<f16>) {
  // CHECK: offset = 0, size = 1024
  %cst0 = arith.constant dense<0.000000e+00> : tensor<32x16xf16, #A>
  // CHECK: offset = 0, size = 512
  %cst1 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 512, size = 512
  %cst2 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1024, size = 1024
  %a = tt.cat %cst1, %cst2 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  return
  // CHECK: size = 2048
}

// cst0 is alive through the entire function, it cannot be released before the end of the function
func @synthesize_longlive(%A : !tt.ptr<f16>) {
  // CHECK: offset = 0, size = 512
  %cst0 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 512, size = 512
  %cst1 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1024, size = 512
  %cst2 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1536, size = 1024
  %a = tt.cat %cst1, %cst2 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 512, size = 512
  %cst3 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1024, size = 512
  %cst4 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1536, size = 1024
  %b = tt.cat %cst3, %cst4 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 1536, size = 512
  %cst5 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1536, size = 512
  %cst6 = arith.constant dense<0.000000e+00> : tensor<16x16xf16, #A>
  // CHECK: offset = 1536, size = 1024
  %c = tt.cat %cst3, %cst4 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  // CHECK: offset = 512, size = 1024
  %d = tt.cat %cst0, %cst0 {axis = 0} : (tensor<16x16xf16, #A>, tensor<16x16xf16, #A>) -> tensor<32x16xf16, #A>
  return
  // CHECK: size = 2560
}
