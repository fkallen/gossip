#pragma once

#include <numeric>
#include <vector>

#include "config.h"
#include "error_checking.hpp"
#include "context.cuh"
#include "common.cuh"
#include "all_to_all_plan.hpp"
#include "kernels.cuh"

namespace gossip {

class all2all_t {

    const context_t * context;

    transfer_plan_t transfer_plan;
    bool plan_valid;

public:
    all2all_t (
        const context_t& context_)
        : context(&context_),
          transfer_plan( all2all::default_plan(context->get_num_devices()) ),
          plan_valid( transfer_plan.valid() )
    {
        check(context->is_valid(),
              "You have to pass a valid context!");
    }

    all2all_t (
        const context_t& context_,
        const transfer_plan_t& transfer_plan_)
        : context(&context_),
          transfer_plan(transfer_plan_),
          plan_valid(false)
    {
        check(context->is_valid(),
              "You have to pass a valid context!");

        if(!transfer_plan.valid())
            all2all::verify_plan(transfer_plan);

        check(get_num_devices() == transfer_plan.num_gpus(),
              "Plan does fit number of gpus of context!");

        plan_valid = (get_num_devices() == transfer_plan.num_gpus()) &&
                     transfer_plan.valid();
    }

public:
    void show_plan() const {
        if(!plan_valid)
            std::cout << "WARNING: plan does fit number of gpus\n";

        transfer_plan.show_plan();
    }

private:
    struct transfer {
        const gpu_id_t src_gpu;
        const size_t src_pos;
        const gpu_id_t trg_gpu;
        const size_t trg_pos;
        const size_t len;

        transfer(const gpu_id_t src_gpu,
                 const size_t src_pos,
                 const gpu_id_t trg_gpu,
                 const size_t trg_pos,
                 const size_t len) :
            src_gpu(src_gpu),
            src_pos(src_pos),
            trg_gpu(trg_gpu),
            trg_pos(trg_pos),
            len(len)
        {}

        void show() const {
            std::cout <<   "src:" << int(src_gpu)
                        << ", pos:" << src_pos
                        << ", trg:" << int(trg_gpu)
                        << ", pos:" << trg_pos
                        << ", len:" << len
                        << std::endl;
        }
    };

    template<typename table_t>
    struct transfer_handler {
        const context_t * context;

        std::vector<std::vector<size_t> > src_offsets;
        std::vector<std::vector<size_t> > phases_offsets;
        std::vector<std::vector<size_t> > trg_offsets;

        const std::vector<std::vector<size_t> >& src_displacements;
        const std::vector<std::vector<table_t> >& sizes;

        size_t num_phases;
        std::vector<std::vector<transfer> > phases;

        size_t num_chunks;

        transfer_handler(
            const context_t * context_,
            const std::vector<std::vector<table_t>>& src_displacements,
            const std::vector<std::vector<table_t>>& trg_displacements,
            const std::vector<std::vector<table_t>>& sizes,
            const size_t num_phases_,
            const size_t num_chunks_ = 1
        ) :
            context(context_),
            src_offsets(src_displacements), // src offsets begin at src displacements
            phases_offsets(),
            trg_offsets(trg_displacements), // trg offsets begin at trg displacements
            src_displacements(src_displacements),
            sizes(sizes),
            num_phases(num_phases_),
            phases(num_phases),
            num_chunks(num_chunks_)
        {
            if(num_phases > 1)
                phases_offsets.resize(num_phases-1, std::vector<size_t>(context->get_num_devices()));
        }

        bool push_back(
            const std::vector<gpu_id_t>& sequence,
            const size_t chunks = 1
        ) {
            if(!check(sequence.size() == num_phases+1,
                      "sequence size does not match number of phases."))
                return false;

            const size_t size_per_chunk = SDIV(sizes[sequence.front()][sequence.back()], num_chunks);
            size_t transfer_size = size_per_chunk * chunks;

            const size_t src_offset = src_offsets[sequence.front()][sequence.back()];
            const size_t trg_offset = trg_offsets[sequence.front()][sequence.back()];
            // check bounds
            const size_t limit = src_displacements[sequence.front()][sequence.back()]
                               + sizes[sequence.front()][sequence.back()];
            if (src_offset + transfer_size > limit)
                transfer_size = limit - src_offset;

            if (num_phases == 1) {
                size_t phase = 0;
                phases[phase].emplace_back(sequence[phase], src_offset,
                                           sequence[phase+1], trg_offset,
                                           transfer_size);
            }
            else {
                size_t phase = 0;
                phases[phase].emplace_back(sequence[phase], src_offset,
                                           sequence[phase+1], phases_offsets[phase][sequence[phase+1]],
                                           transfer_size);

                for (phase = 1; phase < num_phases-1; ++phase) {
                    phases[phase].emplace_back(sequence[phase], phases_offsets[phase-1][sequence[phase]],
                                               sequence[phase+1], phases_offsets[phase][sequence[phase+1]],
                                               transfer_size);
                }

                phase = num_phases-1;
                phases[phase].emplace_back(sequence[phase], phases_offsets[phase-1][sequence[phase]],
                                           sequence[phase+1], trg_offset,
                                           transfer_size);
            }

            src_offsets[sequence.front()][sequence.back()] += transfer_size;
            for (size_t phase = 0; phase < num_phases-1; ++phase) {
                phases_offsets[phase][sequence[phase+1]] += transfer_size;
            }
            trg_offsets[sequence.front()][sequence.back()] += transfer_size;

            return true;
        }

        void show_phase(const size_t phase) const {
            for(const transfer& t : phases[phase]) {
                t.show();
            }
        }

        template<typename value_t>
        bool execute_phase(
            const size_t phase,
            const std::vector<value_t *>& srcs,
            const std::vector<value_t *>& dsts
        ) const {
            std::cerr << "phase " << phase << "\n";
            for(const transfer& t : phases[phase]) {
                const gpu_id_t src = context->get_device_id(t.src_gpu);
                const gpu_id_t trg = context->get_device_id(t.trg_gpu);
                const auto stream  = context->get_streams(t.src_gpu)[t.trg_gpu];
                cudaSetDevice(src);
                const size_t size = t.len * sizeof(value_t);
                value_t * from = srcs[t.src_gpu] + t.src_pos;
                value_t * to   = dsts[t.trg_gpu] + t.trg_pos;

                //cudaMemcpyPeerAsync(to, trg, from, src, size, stream);

                cudaMemcpyAsync(to, from, size, cudaMemcpyDeviceToDevice, stream);

                // dim3 block(256, 1, 1);
                // dim3 grid(SDIV(t.len, block.x), 1, 1);
                // copyKernel<<<grid, block, 0, stream>>>(from, t.len, to);
            } CUERR

            return true;
        }
    };



    template<typename table_t>
    struct transfer_handler_graph {
        const context_t * context;

        std::vector<std::vector<size_t> > src_offsets;
        std::vector<std::vector<size_t> > phases_offsets;
        std::vector<std::vector<size_t> > trg_offsets;

        const std::vector<std::vector<size_t> >& src_displacements;
        const std::vector<std::vector<table_t> >& sizes;

        size_t num_phases;
        std::vector<std::vector<transfer> > phases;

        size_t num_chunks;

        std::vector<cudaGraph_t> graphPerPhase;
        std::vector<cudaGraphExec_t> execgraphPerPhase;
        cudaGraphExec_t execgraphTotal = nullptr;

        cudaStream_t captureStream;
        cudaEvent_t captureEvent;
        int gpuId;

        transfer_handler_graph(
            const context_t * context_,
            const std::vector<std::vector<table_t>>& src_displacements,
            const std::vector<std::vector<table_t>>& trg_displacements,
            const std::vector<std::vector<table_t>>& sizes,
            const size_t num_phases_,
            const size_t num_chunks_ = 1
        ) :
            context(context_),
            src_offsets(src_displacements), // src offsets begin at src displacements
            phases_offsets(),
            trg_offsets(trg_displacements), // trg offsets begin at trg displacements
            src_displacements(src_displacements),
            sizes(sizes),
            num_phases(num_phases_),
            phases(num_phases),
            num_chunks(num_chunks_)
        {
            if(num_phases > 1)
                phases_offsets.resize(num_phases-1, std::vector<size_t>(context->get_num_devices()));

            graphPerPhase.resize(num_phases, nullptr);
            execgraphPerPhase.resize(num_phases, nullptr);

            cudaStreamCreate(&captureStream); CUERR;
            cudaEventCreateWithFlags(&captureEvent, cudaEventDisableTiming); CUERR;
            cudaGetDevice(&gpuId); CUERR;

            // for(auto& g : graphPerPhase){
            //     cudaGraphCreate(&g, 0); CUERR;
            // }

            // for(auto& g : execgraphPerPhase){
            //     cudaGraphCreate(&g, 0); CUERR;
            // }
            
        }

        ~transfer_handler_graph(){
            int cur;
            cudaGetDevice(&cur);
            cudaSetDevice(gpuId);

            for(auto& g : graphPerPhase){
                if(g != nullptr)
                    cudaGraphDestroy(g); CUERR;
            }

            graphPerPhase.clear();

            for(auto& g : execgraphPerPhase){
                if(g != nullptr)
                    cudaGraphExecDestroy(g); CUERR;
            }

            execgraphPerPhase.clear();

            if(execgraphTotal != nullptr){
                cudaGraphExecDestroy(execgraphTotal);
            }

            cudaStreamDestroy(captureStream); CUERR;
            cudaEventDestroy(captureEvent); CUERR;

            cudaSetDevice(cur);
        }

        void begin_transfer_setup(){

        }

        void end_transfer_setup(){

        }

        bool add_transfer(
            const std::vector<gpu_id_t>& sequence,
            const size_t chunks = 1
        ) {
            if(!check(sequence.size() == num_phases+1,
                      "sequence size does not match number of phases."))
                return false;

            const size_t size_per_chunk = SDIV(sizes[sequence.front()][sequence.back()], num_chunks);
            size_t transfer_size = size_per_chunk * chunks;

            const size_t src_offset = src_offsets[sequence.front()][sequence.back()];
            const size_t trg_offset = trg_offsets[sequence.front()][sequence.back()];
            // check bounds
            const size_t limit = src_displacements[sequence.front()][sequence.back()]
                               + sizes[sequence.front()][sequence.back()];
            if (src_offset + transfer_size > limit)
                transfer_size = limit - src_offset;

            if (num_phases == 1) {
                size_t phase = 0;
                phases[phase].emplace_back(sequence[phase], src_offset,
                                           sequence[phase+1], trg_offset,
                                           transfer_size);
            }
            else {
                size_t phase = 0;
                phases[phase].emplace_back(sequence[phase], src_offset,
                                           sequence[phase+1], phases_offsets[phase][sequence[phase+1]],
                                           transfer_size);

                for (phase = 1; phase < num_phases-1; ++phase) {
                    phases[phase].emplace_back(sequence[phase], phases_offsets[phase-1][sequence[phase]],
                                               sequence[phase+1], phases_offsets[phase][sequence[phase+1]],
                                               transfer_size);
                }

                phase = num_phases-1;
                phases[phase].emplace_back(sequence[phase], phases_offsets[phase-1][sequence[phase]],
                                           sequence[phase+1], trg_offset,
                                           transfer_size);
            }

            src_offsets[sequence.front()][sequence.back()] += transfer_size;
            for (size_t phase = 0; phase < num_phases-1; ++phase) {
                phases_offsets[phase][sequence[phase+1]] += transfer_size;
            }
            trg_offsets[sequence.front()][sequence.back()] += transfer_size;

            return true;
        }

        void show_phase(const size_t phase) const {
            for(const transfer& t : phases[phase]) {
                t.show();
            }
        }

        template<typename value_t>
        bool update_phase_graph(
            const size_t phase,
            const std::vector<value_t *>& srcs,
            const std::vector<value_t *>& dsts
        ) {
            cudaGraph_t graph;
            cudaGraphExecUpdateResult updateResult;
            cudaGraphNode_t errorNode;

            cudaStream_t captureStream = context->get_streams(0)[0];
            cudaEvent_t captureEvent = context->get_events(0)[0];
            cudaStreamBeginCapture(captureStream, cudaStreamCaptureModeRelaxed); CUERR;

            cudaEventRecord(captureEvent, captureStream); CUERR;

            for(const transfer& t : phases[phase]) {
                const gpu_id_t src = context->get_device_id(t.src_gpu);
                const gpu_id_t trg = context->get_device_id(t.trg_gpu);
                const auto stream  = context->get_streams(t.src_gpu)[t.trg_gpu];
                const auto event = context->get_events(t.src_gpu)[t.trg_gpu];
                cudaSetDevice(src); CUERR;

                cudaStreamWaitEvent(stream, captureEvent, 0); CUERR;

                const size_t size = t.len * sizeof(value_t);
                value_t * from = srcs[t.src_gpu] + t.src_pos;
                value_t * to   = dsts[t.trg_gpu] + t.trg_pos;

                //cudaMemcpyPeerAsync(to, trg, from, src, size, stream);

                cudaMemcpyAsync(to, from, size, cudaMemcpyDeviceToDevice, stream); CUERR;

                cudaEventRecord(event, stream); CUERR;

                // dim3 block(256, 1, 1);
                // dim3 grid(SDIV(t.len, block.x), 1, 1);
                // copyKernel<<<grid, block, 0, stream>>>(from, t.len, to);

                cudaStreamWaitEvent(captureStream, event, 0); CUERR;
            } 

            cudaStreamEndCapture(captureStream, &graph); CUERR;

            // If we've already instantiated the graph, try to update it directly
            // and avoid the instantiation overhead
            if (execgraphPerPhase[phase] != NULL) {
                // If the graph fails to update, errorNode will be set to the
                // node causing the failure and updateResult will be set to a
                // reason code.
                cudaGraphExecUpdate(execgraphPerPhase[phase], graph, &errorNode, &updateResult);
            }

            // Instantiate during the first iteration or whenever the update
            // fails for any reason
            if (execgraphPerPhase[phase] == NULL || updateResult != cudaGraphExecUpdateSuccess) {

                // If a previous update failed, destroy the cudaGraphExec_t
                // before re-instantiating it
                if (execgraphPerPhase[phase] != NULL) {
                    cudaGraphExecDestroy(execgraphPerPhase[phase]);
                }   
                // Instantiate graphExec from graph. The error node and
                // error message parameters are unused here.
                cudaGraphInstantiate(&execgraphPerPhase[phase], graph, NULL, NULL, 0);
            }   

            cudaGraphDestroy(graph);

            CUERR;

            return true;
        }

        template<typename value_t>
        bool execute_phase(
            const size_t phase,
            const std::vector<value_t *>& srcs,
            const std::vector<value_t *>& dsts
        ) {
            update_phase_graph(phase, srcs, dsts);

            update_phase_graph(phase, srcs, dsts);

            assert(execgraphPerPhase[phase] != nullptr);

            cudaGraphLaunch(execgraphPerPhase[phase], context->get_streams(0)[0]);

            return true;
        }


        template<typename value_t>
        bool update_graph(
            const std::vector<value_t *>& srcs,
            const std::vector<value_t *>& dsts
        ){
            cudaGraph_t graph;
            cudaGraphExecUpdateResult updateResult;
            cudaGraphNode_t errorNode;

            const int numGpus = context->get_num_devices();
            std::cerr << "numGPus " << numGpus << "\n";

            cudaStreamBeginCapture(captureStream, cudaStreamCaptureModeRelaxed); CUERR;

            for (size_t p = 0; p < num_phases; ++p) {

                const std::vector<value_t *>& current_srcs = p % 2 == 0 ? srcs : dsts;
                const std::vector<value_t *>& current_dsts = p % 2 == 0 ? dsts : srcs;

                cudaEventRecord(captureEvent, captureStream); CUERR;

                for(const transfer& t : phases[p]) {
                    const gpu_id_t src = context->get_device_id(t.src_gpu);
                    const gpu_id_t trg = context->get_device_id(t.trg_gpu);
                    const auto stream  = context->get_streams(t.src_gpu)[t.trg_gpu];
                    const auto event = context->get_events(t.src_gpu)[t.trg_gpu];
                    cudaSetDevice(src); CUERR;

                    cudaStreamWaitEvent(stream, captureEvent, 0); CUERR;

                    const size_t size = t.len * sizeof(value_t);
                    value_t * from = current_srcs[t.src_gpu] + t.src_pos;
                    value_t * to   = current_dsts[t.trg_gpu] + t.trg_pos;

                    //cudaMemcpyPeerAsync(to, trg, from, src, size, stream);

                    cudaMemcpyAsync(to, from, size, cudaMemcpyDeviceToDevice, stream); CUERR;

                    

                    // dim3 block(256, 1, 1);
                    // dim3 grid(SDIV(t.len, block.x), 1, 1);
                    // copyKernel<<<grid, block, 0, stream>>>(from, t.len, to);

                    //cudaStreamWaitEvent(captureStream, event, 0); CUERR;

                    cudaEventRecord(event, stream); CUERR;
                } 

                // join all events to capture stream, i.e. "sync" between phases
                for(int i = 0; i < numGpus; i++){
                    for(auto event : context->get_events(i)){
                        cudaStreamWaitEvent(captureStream, event, 0); CUERR;
                    }
                }
            }

            cudaStreamEndCapture(captureStream, &graph); CUERR;

            // If we've already instantiated the graph, try to update it directly
            // and avoid the instantiation overhead
            if (execgraphTotal != NULL) {
                // If the graph fails to update, errorNode will be set to the
                // node causing the failure and updateResult will be set to a
                // reason code.
                cudaGraphExecUpdate(execgraphTotal, graph, &errorNode, &updateResult);
            }

            // Instantiate during the first iteration or whenever the update
            // fails for any reason
            if (execgraphTotal == NULL || updateResult != cudaGraphExecUpdateSuccess) {

                // If a previous update failed, destroy the cudaGraphExec_t
                // before re-instantiating it
                if (execgraphTotal != NULL) {
                    cudaGraphExecDestroy(execgraphTotal);
                }   
                // Instantiate graphExec from graph. The error node and
                // error message parameters are unused here.
                cudaGraphInstantiate(&execgraphTotal, graph, NULL, NULL, 0);
            }   

            cudaGraphDestroy(graph);

            CUERR;

            return true;
        }

        template<typename value_t>
        bool execute(
            const std::vector<value_t *>& srcs,
            const std::vector<value_t *>& dsts
        ) {
            update_graph(srcs, dsts);

            update_graph(srcs, dsts);

            assert(execgraphTotal != nullptr);

            cudaGraphLaunch(execgraphTotal, context->get_streams(0)[0]);

            return true;
        }

        
    };

public:
    template <
        typename value_t,
        typename index_t,
        typename table_t>
    bool execAsync (
        std::vector<value_t *>& srcs,                   // src[k] resides on device_ids[k]
        const std::vector<index_t  >& srcs_lens,        // src_len[k] is length of src[k]
        std::vector<value_t *>& dsts,                   // dst[k] resides on device_ids[k]
        const std::vector<index_t  >& dsts_lens,        // dst_len[k] is length of dst[k]
        const std::vector<std::vector<table_t> >& send_counts, // [src_gpu, partition]
        bool verbose = false
    ) const {
        if (!check(plan_valid, "Invalid plan. Abort."))
            return false;

        if (!check(srcs.size() == get_num_devices(),
                    "srcs size does not match number of gpus."))
            return false;
        if (!check(srcs_lens.size() == get_num_devices(),
                    "srcs_lens size does not match number of gpus."))
            return false;
        if (!check(dsts.size() == get_num_devices(),
                    "dsts size does not match number of gpus."))
            return false;
        if (!check(dsts_lens.size() == get_num_devices(),
                    "dsts_lens size does not match number of gpus."))
            return false;
        if (!check(send_counts.size() == get_num_devices(),
                    "table size does not match number of gpus."))
            return false;
        for (const auto& counts : send_counts) {
            if (!check(counts.size() == get_num_devices(),
                        "table size does not match number of gpus."))
                return false;
        }

        const auto num_phases = transfer_plan.num_steps();
        const auto num_chunks = transfer_plan.num_chunks();

        std::vector<std::vector<size_t> > src_displacements(get_num_devices(), std::vector<size_t>(get_num_devices()+1));
        // horizontal scan to get initial offsets
        for (gpu_id_t gpu = 0; gpu < get_num_devices(); ++gpu) {
            std::partial_sum(send_counts[gpu].begin(), send_counts[gpu].end(), src_displacements[gpu].begin() + 1);
        }

        std::vector<std::vector<size_t> > trg_displacements(get_num_devices()+1, std::vector<size_t>(get_num_devices()));
        // vertical scan to get trg offsets
        for (gpu_id_t gpu = 0; gpu < get_num_devices(); ++gpu) {
            for (gpu_id_t part = 0; part < get_num_devices(); ++part) {
                trg_displacements[part+1][gpu] = send_counts[part][gpu]+trg_displacements[part][gpu];
            }
        }

#if 1        
        transfer_handler_graph<table_t> transfers(context,
                                            src_displacements,
                                            trg_displacements,
                                            send_counts,
                                            num_phases, num_chunks);

        transfers.begin_transfer_setup();

        // prepare transfers according to transfer_plan
        for (const auto& sequence : transfer_plan.transfer_sequences()) {
            transfers.add_transfer(sequence.seq, sequence.size);
        }

        transfers.end_transfer_setup();
#else 

        transfer_handler<table_t> transfers(context,
            src_displacements,
            trg_displacements,
            send_counts,
            num_phases, num_chunks);

        // prepare transfers according to transfer_plan
        for (const auto& sequence : transfer_plan.transfer_sequences()) {
            transfers.push_back(sequence.seq, sequence.size);
        }

#endif

        if(verbose) {
            for (size_t p = 0; p < num_phases; ++p) {
                transfers.show_phase(p);
            }
        }
        for (size_t p = 0; p < num_phases-1; ++p) {
            if(!check_size(transfers.phases_offsets[p], dsts_lens)) return false;
        }
        if(!check_size(transfers.trg_offsets[get_num_devices()], dsts_lens)) return false;

#if 1
        transfers.execute(srcs, dsts);
        context->sync_all_streams();
        if(num_phases % 2 == 0){
            std::swap(srcs,dsts);
        }
#else
        for (size_t p = 0; p < num_phases; ++p) {
            transfers.execute_phase(p, srcs, dsts);

            if (p < num_phases-1) {
                // swap srcs and dsts for next phase
                srcs.swap(dsts);

                // mandatory sync between phases
                context->sync_all_streams();
            }
        }
#endif

        return true;
    }

    gpu_id_t get_num_devices () const noexcept {
        return context->get_num_devices();
    }

    void sync () const noexcept {
        context->sync_all_streams();
    }

    void sync_hard () const noexcept {
        context->sync_hard();
    }

    const context_t& get_context() const noexcept {
        return *context;
    }
};

} // namespace
