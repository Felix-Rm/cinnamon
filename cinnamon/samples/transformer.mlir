// transformer model for https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin
// dim: 288
// hidden_dim: 768
// kv_dim: 288
// kv_mul: 1
// n_layers: 6
// n_heads: 6
// n_kv_heads: 6
// head_size: 48
// vocab_size: 32000
// seq_len: 256

func.func @forward(%token : index, %pos : index,
	// state
	%key_cache : tensor<6x256x288xf32>,
	%value_cache : tensor<6x256x288xf32>,
	// weights
	%embedding_table : tensor<32000x288xf32>,
	%rms_att_weights : tensor<6x288xf32>,
	%wq : tensor<6x288x288xf32>,
	%wk : tensor<6x288x288xf32>,
	%wv : tensor<6x288x288xf32>,
	%wo : tensor<6x288x288xf32>,
	%w1 : tensor<6x768x288xf32>,
	%w2 : tensor<6x288x768xf32>,
	%w3 : tensor<6x768x288xf32>,
	%rms_ffn_weights : tensor<6x288xf32>,
	%rms_final_weight : tensor<288xf32>,
	%wcls : tensor<32000x288xf32>
) -> (tensor<32000xf32>, tensor<6x256x288xf32>, tensor<6x256x288xf32>) {
	%c0 = arith.constant 0 : index
	%c1 = arith.constant 1 : index
	%c2 = arith.constant 2 : index
	%c6 = arith.constant 6 : index
	%c48 = arith.constant 48 : index
	%c288 = arith.constant 288 : index
	%c768 = arith.constant 768 : index
	%c0f = arith.constant 0.0 : f32
	%c1f = arith.constant 1.0 : f32
	%c48f = arith.constant 48.0 : f32
	%c10000f = arith.constant 10000.0 : f32

	%content_row = tensor.extract_slice %embedding_table [%token, 0] [1, 288] [1, 1] : tensor<32000x288xf32> to tensor<288xf32>

	%x, %kc, %vc = scf.for %layer = %c0 to %c6 step %c1 iter_args(%x = %content_row, %kc = %key_cache, %vc = %value_cache) -> (tensor<288xf32>, tensor<6x256x288xf32>, tensor<6x256x288xf32>) {
		%rms_att_weight = tensor.extract_slice %rms_att_weights [%layer, 0] [1, 288] [1, 1] : tensor<6x288xf32> to tensor<288xf32>
		%xb = func.call @rmsnorm(%x, %rms_att_weight) : (tensor<288xf32>, tensor<288xf32>) -> tensor<288xf32>

		// qkv matmuls
		%wqs = tensor.extract_slice %wq [%layer, 0, 0] [1, 288, 288] [1, 1, 1] : tensor<6x288x288xf32> to tensor<288x288xf32>
		%wks = tensor.extract_slice %wk [%layer, 0, 0] [1, 288, 288] [1, 1, 1] : tensor<6x288x288xf32> to tensor<288x288xf32>
		%wvs = tensor.extract_slice %wv [%layer, 0, 0] [1, 288, 288] [1, 1, 1] : tensor<6x288x288xf32> to tensor<288x288xf32>
		%q, %k, %v = cinm.compute attributes { workgroupShape = array<i64: 6,48> } -> tensor<288xf32>, tensor<288xf32>, tensor<288xf32> {
			%q = cinm.op.gemv %wqs, %xb : (tensor<288x288xf32>, tensor<288xf32>) -> tensor<288xf32>
			%k = cinm.op.gemv %wks, %xb : (tensor<288x288xf32>, tensor<288xf32>) -> tensor<288xf32>
			%v = cinm.op.gemv %wvs, %xb : (tensor<288x288xf32>, tensor<288xf32>) -> tensor<288xf32>
			cinm.yield %q, %k, %v : tensor<288xf32>, tensor<288xf32>, tensor<288xf32>
		}

		// RoPE relative positional encoding: complex-valued rotate q and k in each head
		%posi = arith.index_cast %pos : index to i64
		%posf = arith.uitofp %posi : i64 to f32
		%q2, %k2 = scf.for %i = %c0 to %c288 step %c2 iter_args(%qi = %q, %ki = %k) -> (tensor<288xf32>, tensor<288xf32>) {
			%head_dim = arith.remui %i, %c48 : index
			%head_dimi = arith.index_cast %head_dim : index to i64
			%head_dimf = arith.uitofp %head_dimi : i64 to f32
			%0 = arith.divf %head_dimf, %c48f : f32
			%1 = math.powf %c10000f, %0 : f32
			%freq = arith.divf %c1f, %1 : f32
			%val = arith.mulf %posf, %freq : f32
			%fcr = math.cos %val : f32
			%fci = math.sin %val : f32

			%qr = func.call @rot(%qi, %i, %fcr, %fci) : (tensor<288xf32>, index, f32, f32) -> tensor<288xf32>

			%cond = arith.cmpi ult, %i, %c288 : index
			%kr = scf.if %cond -> (tensor<288xf32>) {
				%kr = func.call @rot(%ki, %i, %fcr, %fci) : (tensor<288xf32>, index, f32, f32) -> tensor<288xf32>
				scf.yield %kr : tensor<288xf32>
			} else {
				scf.yield %ki : tensor<288xf32>
			}

			scf.yield %qr, %kr : tensor<288xf32>, tensor<288xf32>
		}

		%kc2 = tensor.insert_slice %k2 into %kc [%layer, %pos, 0] [1, 1, 288] [1, 1, 1] : tensor<288xf32> into tensor<6x256x288xf32>
		%vc2 = tensor.insert_slice %v into %vc [%layer, %pos, 0] [1, 1, 288] [1, 1, 1] : tensor<288xf32> into tensor<6x256x288xf32>

		// multi head attention
		%kc_slice = tensor.extract_slice %kc2 [%layer, 0, 0] [1, 256, 288] [1, 1, 1] : tensor<6x256x288xf32> to tensor<256x288xf32>
		%vc_slice = tensor.extract_slice %vc2 [%layer, 0, 0] [1, 256, 288] [1, 1, 1] : tensor<6x256x288xf32> to tensor<256x288xf32>
		%xb2 = func.call @mha(%q2, %kc_slice, %vc_slice, %pos) : (tensor<288xf32>, tensor<256x288xf32>, tensor<256x288xf32>, index) -> tensor<288xf32>

		%wo_slice = tensor.extract_slice %wo [%layer, 0, 0] [1, 288, 288] [1, 1, 1] : tensor<6x288x288xf32> to tensor<288x288xf32>
		%xb4 = cinm.compute attributes { workgroupShape = array<i64: 6,48> } -> tensor<288xf32> {
			// final matmul to get the output of the attention
			%xb3 = cinm.op.gemv %wo_slice, %xb2 : (tensor<288x288xf32>, tensor<288xf32>) -> tensor<288xf32>

			// residual connection back into x
			%xb4 = cinm.op.add %x, %xb3 : tensor<288xf32>
			cinm.yield %xb4 : tensor<288xf32>
		}

		// ffn rmsnorm
		%rms_ffn_weight = tensor.extract_slice %rms_ffn_weights [%layer, 0] [1, 288] [1, 1] : tensor<6x288xf32> to tensor<288xf32>
		%xb5 = func.call @rmsnorm(%xb4, %rms_ffn_weight) : (tensor<288xf32>, tensor<288xf32>) -> tensor<288xf32>

		// Now for FFN in PyTorch we have: self.w2(F.silu(self.w1(x)) * self.w3(x))
		// first calculate self.w1(x) and self.w3(x)
		%w1_slice = tensor.extract_slice %w1 [%layer, 0, 0] [1, 768, 288] [1, 1, 1] : tensor<6x768x288xf32> to tensor<768x288xf32>
		%w3_slice = tensor.extract_slice %w3 [%layer, 0, 0] [1, 768, 288] [1, 1, 1] : tensor<6x768x288xf32> to tensor<768x288xf32>
		%hb1, %hb2 = cinm.compute attributes { workgroupShape = array<i64: 48> } -> tensor<768xf32>, tensor<768xf32> {
			%hb1 = cinm.op.gemv %w1_slice, %xb5 : (tensor<768x288xf32>, tensor<288xf32>) -> tensor<768xf32>
			%hb2 = cinm.op.gemv %w3_slice, %xb5 : (tensor<768x288xf32>, tensor<288xf32>) -> tensor<768xf32>
			cinm.yield %hb1, %hb2 : tensor<768xf32>, tensor<768xf32>
		}

		// SwiGLU non-linearity
		%hb3 = scf.for %i = %c0 to %c768 step %c1 iter_args(%hb = %hb1) -> (tensor<768xf32>) {
			%0 = tensor.extract %hb [%i] : tensor<768xf32>
			%1 = tensor.extract %hb2 [%i] : tensor<768xf32>
			%2 = math.exp %0 : f32
			%3 = arith.addf %c1f, %2 : f32
			%4 = arith.divf %c1f, %3 : f32
			%5 = arith.mulf %1, %4 : f32
			%hbr = tensor.insert %5 into %hb [%i] : tensor<768xf32>
			scf.yield %hbr : tensor<768xf32>
		}

		%w2_slice = tensor.extract_slice %w2 [%layer, 0, 0] [1, 288, 768] [1, 1, 1] : tensor<6x288x768xf32> to tensor<288x768xf32>
		%xb7 = cinm.compute attributes { workgroupShape = array<i64: 6,48> } -> tensor<288xf32> {
			// final matmul to get the output of the ffn
			%xb6 = cinm.op.gemv %w2_slice, %hb3 : (tensor<288x768xf32>, tensor<768xf32>) -> tensor<288xf32>

			// residual connection
			%xb7 = cinm.op.add %x, %xb6 : tensor<288xf32>
			cinm.yield %xb7 : tensor<288xf32>
		}

		scf.yield %xb7, %kc2, %vc2 : tensor<288xf32>, tensor<6x256x288xf32>, tensor<6x256x288xf32>
	}

	%x2 = func.call @rmsnorm(%x, %rms_final_weight) : (tensor<288xf32>, tensor<288xf32>) -> tensor<288xf32>
	%logits = cinm.compute attributes { workgroupShape = array<i64: 256,3> } -> tensor<32000xf32> {
		%wcls2 = tensor.pad %wcls low[0,0] high[768,0] {
		^bb0(%arg1: index, %arg2: index):
			tensor.yield %c0f : f32
		} : tensor<32000x288xf32> to tensor<32768x288xf32>
		%logits = cinm.op.gemv %wcls2, %x2 : (tensor<32768x288xf32>, tensor<288xf32>) -> tensor<32768xf32>
		%logits2 = tensor.extract_slice %logits [0] [32000] [1] : tensor<32768xf32> to tensor<32000xf32>
		cinm.yield %logits2 : tensor<32000xf32>
	}

	return %logits, %kc, %vc : tensor<32000xf32>, tensor<6x256x288xf32>, tensor<6x256x288xf32>
}

func.func @rot(%v: tensor<288xf32>, %i: index, %fcr : f32, %fci : f32) -> tensor<288xf32> {
	%c1 = arith.constant 1 : index
	%i2 = arith.addi %i, %c1 : index
	%v0 = tensor.extract %v [%i] : tensor<288xf32>
	%v1 = tensor.extract %v [%i2] : tensor<288xf32>
	%0 = arith.mulf %v0, %fcr : f32
	%1 = arith.mulf %v1, %fci : f32
	%2 = arith.subf %0, %1 : f32
	%r0 = tensor.insert %2 into %v[%i] : tensor<288xf32>
	%3 = arith.mulf %v0, %fci : f32
	%4 = arith.mulf %v1, %fcr : f32
	%5 = arith.addf %3, %4 : f32
	%r1 = tensor.insert %2 into %r0[%i] : tensor<288xf32>
	return %r1 : tensor<288xf32>
}

func.func @mha(%q: tensor<288xf32>, %kc: tensor<256x288xf32>, %vc: tensor<256x288xf32>, %pos: index) -> tensor<288xf32> {
	%c0 = arith.constant 0 : index
	%c1 = arith.constant 1 : index
	%c6 = arith.constant 6 : index
	%c48 = arith.constant 48 : index

	%xb_init = tensor.empty() : tensor<288xf32>
	%xb = scf.for %head = %c0 to %c6 step %c1 iter_args(%xbi = %xb_init) -> (tensor<288xf32>) {
		%hoff = arith.muli %head, %c48 : index
		%q_slice = tensor.extract_slice %q [%hoff] [48] [1] : tensor<288xf32> to tensor<48xf32>
		%kc_slice = tensor.extract_slice %kc [0, %hoff] [256, 48] [1, 1] : tensor<256x288xf32> to tensor<256x48xf32>
		%vc_slice = tensor.extract_slice %vc [0, %hoff] [256, 48] [1, 1] : tensor<256x288xf32> to tensor<256x48xf32>
		%xb_slice = func.call @attn(%q_slice, %kc_slice, %vc_slice, %pos) : (tensor<48xf32>, tensor<256x48xf32>, tensor<256x48xf32>, index) -> tensor<48xf32>
		%xbr = tensor.insert_slice %xb_slice into %xbi [%hoff] [48] [1] : tensor<48xf32> into tensor<288xf32>
		scf.yield %xbr : tensor<288xf32>
	}

	return %xb : tensor<288xf32>
}

func.func @attn(%q: tensor<48xf32>, %kc: tensor<256x48xf32>, %vc: tensor<256x48xf32>, %pos: index) -> tensor<48xf32> {
	%c0 = arith.constant 0 : index
	%c1 = arith.constant 1 : index
	%scale = arith.constant 6.92820323028 : f32 // sqrt(head_size)

	%ninf = arith.constant 0xFF800000 : f32
	%attn = tensor.generate {
	^bb0(%arg1: index):
		tensor.yield %ninf : f32
	} : tensor<256xf32>

	%attn2 = scf.for %i = %c0 to %pos step %c1 iter_args(%attn_i = %attn) -> (tensor<256xf32>) {
		%k = tensor.extract_slice %kc [%i, 0] [1, 48] [1, 1] : tensor<256x48xf32> to tensor<48xf32>
		%score = cinm.compute attributes { workgroupShape = array<i64: 48> } -> f32 {
			%0 = cinm.op.mul %q, %k : tensor<48xf32>
			%1 = cinm.op.reduce add (%0) : tensor<48xf32>
			%2 = arith.divf %1, %scale : f32
			cinm.yield %2 : f32
		}
		%attn_i2 = tensor.insert %score into %attn_i [%i] : tensor<256xf32>
		scf.yield %attn_i2 : tensor<256xf32>
	}

	%attn3 = call @softmax(%attn2) : (tensor<256xf32>) -> tensor<256xf32>

	%xb_init = tensor.empty() : tensor<48xf32>
	%xb = scf.for %i = %c0 to %pos step %c1 iter_args(%xbi = %xb_init) -> (tensor<48xf32>) {
		%v = tensor.extract_slice %vc [%i, 0] [1, 48] [1, 1] : tensor<256x48xf32> to tensor<48xf32>
		%a = tensor.extract %attn3 [%i] : tensor<256xf32>
		%xbs = cinm.compute attributes { workgroupShape = array<i64: 48> } -> tensor<48xf32>{
			%0 = cinm.op.muls %v, %a : tensor<48xf32>
			%1 = cinm.op.add %0, %xbi : tensor<48xf32>
			cinm.yield %1 : tensor<48xf32>
		}
		scf.yield %xbs : tensor<48xf32>
	}

	return %xb : tensor<48xf32>
}

func.func @rmsnorm(%v : tensor<288xf32>, %w : tensor<288xf32>) -> tensor<288xf32> {
	%epsilon = arith.constant 1.0e-5 : f32
	%c1 = arith.constant 1.0 : f32
	%c288 = arith.constant 288.0 : f32

	%r = cinm.compute attributes { workgroupShape = array<i64: 6,48> } -> tensor<288xf32> {
		%0 = cinm.op.mul %v, %v : tensor<288xf32>
		%ss = cinm.op.reduce add (%0) : tensor<288xf32>
		%s0 = arith.divf %ss, %c288 : f32
		%s1 = arith.addf %s0, %epsilon : f32
		%s = math.rsqrt %s1 : f32
		%x = cinm.op.muls %v, %s : tensor<288xf32>
		%r = cinm.op.mul %x, %w : tensor<288xf32>
		cinm.yield %r : tensor<288xf32>
	}
	return %r : tensor<288xf32>
}

func.func @softmax(%vec : tensor<256xf32>) -> tensor<256xf32> {
	%r = cinm.compute attributes { workgroupShape = array<i64: 16,16> } -> tensor<256xf32> {
		%max = cinm.op.reduce max (%vec) : tensor<256xf32>
		%t = cinm.op.subs %vec, %max : tensor<256xf32>
		%shape = tensor.empty() : tensor<256xf32>
		%e = linalg.exp ins(%t : tensor<256xf32>) outs(%shape : tensor<256xf32>) -> tensor<256xf32>
		%s = cinm.op.reduce add (%e) : tensor<256xf32>
		%r = cinm.op.divs %e, %s : tensor<256xf32>
		cinm.yield %r : tensor<256xf32>
	}

	return %r : tensor<256xf32>
}