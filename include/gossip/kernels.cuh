#pragma once

namespace gossip{

    template<class T>
    __global__
    void copyKernel(
        const T* __restrict__ src,
        size_t numElements,
        T* __restrict__ dest
    ){
        const size_t tid = size_t(threadIdx.x) + size_t(blockIdx.x) * size_t(blockDim.x);
        //const size_t stride = size_t(blockDim.x) * size_t(gridDim.x);

        //for(size_t index = tid; index < numElements; index += stride){
        if(tid < numElements){
            dest[tid] = src[tid];
        }

        // if(tid < numElements / 4){
        //     ((float4*)dest)[tid] = ((const float4*)src)[tid];
        // }

        // const size_t remaining = numElements % 4;
        // if(tid < remaining){
        //     dest[tid + (numElements/4) * 4] = src[tid + (numElements/4) * 4];
        // }
    }

}

