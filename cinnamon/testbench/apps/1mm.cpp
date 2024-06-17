#include "../lib/bench/testbench.hpp"
#include <cstdint>

extern "C" {
int32_t *mm_dimm4_nopt(int32_t *, int32_t *);
int32_t *mm_dimm4_opt(int32_t *, int32_t *);
int32_t *mm_dimm8_nopt(int32_t *, int32_t *);
// TODO
// int32_t *mm_dimm8_opt(int32_t *, int32_t *);
// int32_t *mm_dimm16_nopt(int32_t *, int32_t *);
// int32_t *mm_dimm16_opt(int32_t *, int32_t *);
}

#define REPS 15
#define WARMUP 5

#define BENCH_MM(ty, M, K, N, fun_name)                                        \
  do {                                                                         \
    ty *A = init_matrix<ty, M, K>();                                           \
    ty *B = init_matrix<ty, K, N>();                                           \
    DO_BENCH(REPS, WARMUP, fun_name(A, B));                                    \
    free(A);                                                                   \
    free(B);                                                                   \
  } while (false)

int main(void) {
  srand(0);

  BENCH_MM(int32_t, 8, 1024, 256, mm_dimm4_nopt);
  BENCH_MM(int32_t, 16, 1024, 128, mm_dimm4_opt);

  BENCH_MM(int32_t, 8, 1024, 128, mm_dimm8_nopt);
  // BENCH_MM(int32_t, 16, 1024, 64, mm_dimm8_opt);

  // BENCH_MM(int32_t, 8, 1024, 64, mm_dimm16_nopt);
  // BENCH_MM(int32_t, 16, 1024, 32, mm_dimm16_opt);

  return 0;
}