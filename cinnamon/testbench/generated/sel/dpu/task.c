
#include <stdint.h>
#include <stdio.h>
#include <defs.h>
#include <mram.h>
#include <alloc.h>
#include <perfcounter.h>
#include <handshake.h>
#include <barrier.h>

#include "../support/common.h"

__host dpu_arguments_t DPU_INPUT_ARGUMENTS;
__host dpu_results_t DPU_RESULTS[NR_TASKLETS];

uint32_t message[NR_TASKLETS];
uint32_t message_partial_count;

void loadRow(int *buffer, uint32_t mem_addr, uint32_t offset, int size){
	mram_read((__mram_ptr void const*) (mem_addr + offset), buffer,  size);
}

void storeRow(int *buffer, uint32_t mem_addr, uint32_t offset, int size){
    mram_write( buffer , (__mram_ptr void *) (mem_addr + offset), size);
}

BARRIER_INIT(my_barrier, NR_TASKLETS);

int main() {
    unsigned int tasklet_id = me();
    if (tasklet_id == 0){
        mem_reset();
    }
    barrier_wait(&my_barrier);

    dpu_results_t *result = &DPU_RESULTS[tasklet_id];

    uint32_t total_element = DPU_INPUT_ARGUMENTS.size;
    uint32_t BUFFER_DIM = DPU_INPUT_ARGUMENTS.buffer_size;


    uint32_t mram_base_addr_A = (uint32_t)DPU_MRAM_HEAP_POINTER;
    uint32_t mram_base_addr_B = (uint32_t)(DPU_MRAM_HEAP_POINTER + total_element * sizeof(int));

    uint32_t element_per_thread = total_element/NR_TASKLETS;

    uint32_t mram_curr_A = mram_base_addr_A + tasklet_id * element_per_thread * sizeof(int);
    uint32_t mram_curr_B = mram_base_addr_B + tasklet_id * element_per_thread * sizeof(int);

    int *cache_A = (int *) mem_alloc(BUFFER_DIM * sizeof(int));
    int *cache_B = (int *) mem_alloc(BUFFER_DIM * sizeof(int));

    if(tasklet_id == NR_TASKLETS - 1)
        message_partial_count = 0;
    barrier_wait(&my_barrier);
    loadRow(cache_A, mram_curr_A, 0, BUFFER_DIM * sizeof(int));


    int a_offset = 0 ;
    int b_offset = 0 ;
    int offset_size = sizeof(int) * BUFFER_DIM;
    int nr_load = total_element/BUFFER_DIM;
    for(unsigned int i= 0; i < nr_load; i++){
        loadRow(cache_A, mram_curr_A, a_offset, BUFFER_DIM * sizeof(int));
        a_offset += offset_size;
        int pos = 0;
        for(int j = 0 ; j < BUFFER_DIM; j++){
            if(!pred(cache_A[j])) {
                cache_B[pos] = cache_A[j];
                pos++;
            }
        }
        storeRow(cache_B, mram_curr_B, b_offset, pos * sizeof(int));
        b_offset += pos * sizeof(int);
        result->t_count += pos;
    }

    return 0;
}
