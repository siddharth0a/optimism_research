// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { ISemver } from "src/universal/ISemver.sol";
import { IPreimageOracle } from "./interfaces/IPreimageOracle.sol";
import { MIPSMemory } from "src/cannon/libraries/MIPSMemory.sol";
import { MIPSSyscalls as sys } from "src/cannon/libraries/MIPSSyscalls.sol";
import { MIPSState as st } from "src/cannon/libraries/MIPSState.sol";
import { MIPSInstructions as ins } from "src/cannon/libraries/MIPSInstructions.sol";

/// @title MIPS2
/// @notice The MIPS2 contract emulates a single MIPS instruction.
///         It differs from MIPS.sol in that it supports multi-threading.
contract MIPS2 is ISemver {
    /// @notice The thread context.
    ///         Total state size: 4 + 1 + 1 + 4 + 4 + 8 + 4 + 4 + 4 + 4 + 32 * 4 = 166 bytes
    struct ThreadContext {
        // metadata
        uint32 threadID;
        uint8 exitCode;
        bool exited;
        // state
        uint32 futextAddr;
        uint32 futexVal;
        uint64 futexTimeoutStep;
        uint32 pc;
        uint32 nextPC;
        uint32 lo;
        uint32 hi;
        uint32[32] registers;
    }

    /// @notice Stores the VM state.
    ///         Total state size: 32 + 32 + 4 * 4 + 1 + 1 + 8 + 1 + 32 + 32 = 155 bytes
    ///         If nextPC != pc + 4, then the VM is executing a branch/jump delay slot.
    struct State {
        bytes32 memRoot;
        bytes32 preimageKey;
        uint32 preimageOffset;
        uint32 heap;
        uint8 exitCode;
        bool exited;
        uint64 step;
        bool traverseLeft;
        bytes32 leftThreadStack;
        bytes32 rightThreadStack;
    }

    /// @notice Start of the data segment.
    uint32 public constant BRK_START = 0x40000000;

    /// @notice The semantic version of the MIPS2 contract.
    /// @custom:semver 0.0.1
    string public constant version = "0.0.1-beta";

    /// @notice The preimage oracle contract.
    IPreimageOracle internal immutable ORACLE;

    // The offset of the start of proof calldata (_memProof.offset) in the step() function
    uint256 internal constant MEM_PROOF_OFFSET = 356;

    // The offset of the start of proof calldata (_threadWitness.offset) in the step() function
    uint256 internal constant THREAD_PROOF_OFFSET = 1284;

    /// @notice Executes a single step of the multi-threaded vm.
    ///         Will revert if any required input state is missing.
    /// @param _stateData The encoded state witness data.
    /// @param _memProof The encoded proof data for leaves within the MIPS VM's memory.
    /// @param _threadWitness The encoded proof data for thread contexts.
    ///                     It consists of the thread context and the previous root of current thread stack. These two components are packed.
    /// @param _localContext The local key context for the preimage oracle. Optional, can be set as a constant
    ///                      if the caller only requires one set of local keys.
    function step(bytes calldata _stateData, bytes calldata _memProof, bytes calldata _threadWitness, bytes32 _localContext) public returns (bytes32) {
        unchecked {
            State memory state;
            ThreadContext memory thread;
            bytes32 previousThreadRoot;
            bytes32 witnessRoot;

            assembly {
                if iszero(eq(state, 0x80)) {
                    // expected state mem offset check
                    revert(0, 0)
                }
                if iszero(eq(thread, 0x120)) {
                    // expected thread mem offset check
                    revert(0, 0)
                }
                if iszero(eq(mload(0x40), shl(5, 58))) { // 4 + 10 + 43 + 1 = 58
                    // expected memory check
                    revert(0, 0)
                }
                if iszero(eq(_stateData.offset, 132)) {
                    // 32*5+4=164 expected state data offset
                    revert(0, 0)
                }
                if iszero(eq(_memProof.offset, MEM_PROOF_OFFSET)) {
                    // 164+160+32=356 expected proof offset
                    revert(0, 0)
                }
                if iszero(eq(_threadWitness.offset, THREAD_PROOF_OFFSET)) {
                    // 356+(28*32)+32=1284 expected thread proof offset
                    revert(0, 0)
                }

                function putField(callOffset, memOffset, size) -> callOffsetOut, memOffsetOut {
                    // calldata is packed, thus starting left-aligned, shift-right to pad and right-align
                    let w := shr(shl(3, sub(32, size)), calldataload(callOffset))
                    mstore(memOffset, w)
                    callOffsetOut := add(callOffset, size)
                    memOffsetOut := add(memOffset, 32)
                }

                // Unpack state from calldata into memory
                let c := _stateData.offset // calldata offset
                let m := 0x80 // mem offset
                c, m := putField(c, m, 32) // memRoot
                c, m := putField(c, m, 32) // preimageKey
                c, m := putField(c, m, 4) // preimageOffset
                c, m := putField(c, m, 4) // heap
                c, m := putField(c, m, 1) // exitCode
                c, m := putField(c, m, 1) // exited
                c, m := putField(c, m, 8) // step
                c, m := putField(c, m, 1) // traverseLeft
                c, m := putField(c, m, 32) // leftThreadStack
                c, m := putField(c, m, 32) // rightThreadStack

                // Unpack thread from calldata into memory
                c := _threadWitness.offset
                m := 0x120 // thread mem offset
                c, m := putField(c, m, 4) // threadID
                c, m := putField(c, m, 1) // exitCode
                c, m := putField(c, m, 1) // exited
                c, m := putField(c, m, 4) // futextAddr
                c, m := putField(c, m, 4) // futexVal
                c, m := putField(c, m, 8) // futexTimeoutStep
                c, m := putField(c, m, 4) // pc
                c, m := putField(c, m, 4) // nextPC
                c, m := putField(c, m, 4) // lo
                c, m := putField(c, m, 4) // hi
                // Unpack register calldata into memory
                mstore(m, add(m, 32)) // offset to registers
                m := add(m, 32)
                for { let i := 0 } lt(i, 32) { i := add(i, 1) } { c, m := putField(c, m, 4) }

                // Unpack previous thread root (i.e. w_{i-1}) in witness
                // It's right after the thread context, so leave c untouched
                previousThreadRoot := calldataload(c)

                // compute hash onion
                let memptr := mload(0x40)
                calldatacopy(memptr, THREAD_PROOF_OFFSET, 166) // threadContext.length
                mstore(0x40, add(memptr, 166))
                let threadRoot := keccak256(memptr, 166)

                memptr := mload(0x40)
                mstore(memptr, previousThreadRoot)
                calldatacopy(add(memptr, 32), add(THREAD_PROOF_OFFSET, 166), 32)
                mstore(0x40, add(memptr, 64))
                witnessRoot := keccak256(memptr, 64)
            }

            // verify thread stack proof
            bytes32 currThreadRoot = state.traverseLeft ? state.leftThreadStack : state.rightThreadStack;
            require(currThreadRoot == witnessRoot, "invalid thread stack proof");

            if (state.exited) {
                return outputState();
            }

            state.step += 1;
            // instruction fetch
            uint256 insnProofOffset = MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 0);
            (uint32 insn, uint32 opcode, uint32 fun) =
                ins.getInstructionDetails(thread.pc, state.memRoot, insnProofOffset);
            // Handle syscall separately
            // syscall (can read and write)
            if (opcode == 0 && fun == 0xC) {
                return handleSyscall(_localContext);
            }

            // TODO: Implement MIPS2 instruction execution
            // Exec the rest of the step logic
            st.CpuScalars memory cpu = getCpuScalars(thread);
            (state.memRoot) = ins.execMipsCoreStepLogic({
                _cpu: cpu,
                _registers: thread.registers,
                _memRoot: state.memRoot,
                _memProofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
                _insn: insn,
                _opcode: opcode,
                _fun: fun
            });
            setStateCpuScalars(thread, cpu);
            return outputState();
        }
    }

    function handleSyscall(bytes32 _localContext) internal returns (bytes32 out_) {
        revert("not implemented");
        unchecked {
            // Load state from memory
            State memory state;
            ThreadContext memory thread;
            assembly {
                state := 0x80
                thread := 0x120
            }

            // Load the syscall numbers and args from the registers
            (uint32 syscall_no, uint32 a0, uint32 a1, uint32 a2) = sys.getSyscallArgs(state.registers);
            uint32 v0 = 0;
            uint32 v1 = 0;

            if (syscall_no == sys.SYS_MMAP) {
                (v0, v1, state.heap) = sys.handleSysMmap(a0, a1, state.heap);
            } else if (syscall_no == sys.SYS_BRK) {
                // brk: Returns a fixed address for the program break at 0x40000000
                v0 = BRK_START;
            } else if (syscall_no == sys.SYS_CLONE) {
                // TODO
            } else if (syscall_no == sys.EXIT_GROUP) {
                // exit group: Sets the Exited and ExitCode states to true and argument 0.
                state.exited = true;
                state.exitCode = uint8(a0);
                return outputState();
            } else if (syscall_no == sys.SYS_READ) {
                (v0, v1, state.preimageOffset, state.memRoot) = sys.handleSysRead({
                    _a0: a0,
                    _a1: a1,
                    _a2: a2,
                    _preimageKey: state.preimageKey,
                    _preimageOffset: state.preimageOffset,
                    _localContext: _localContext,
                    _oracle: ORACLE,
                    _proofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
                    _memRoot: state.memRoot
                });
            } else if (syscall_no == sys.SYS_WRITE) {
                (v0, v1, state.preimageKey, state.preimageOffset) = sys.handleSysWrite({
                    _a0: a0,
                    _a1: a1,
                    _a2: a2,
                    _preimageKey: state.preimageKey,
                    _preimageOffset: state.preimageOffset,
                    _proofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
                    _memRoot: state.memRoot
                });
            } else if (syscall_no == sys.SYS_FCNTL) {
                (v0, v1) = sys.handleSysFcntl(a0, a1);
            } else if (syscall_no == sys.SYS_GETTID) {
                v0 = thread.threadID;
                v1 = 0;
            } else if (syscall_no == sys.SYS_EXIT) {
                thread.exited = true;
                thread.exitCode = uint8(a0);
                // TODO: preempt
                return outputState();
            } else if (syscall_no == sys.SYS_FUTEX) {
                // TODO
            } else if (syscall_no == sys.SYS_SCHED_YIELD) {
                // TODO
            }

            st.CpuScalars memory cpu = getCpuScalars(state);
            sys.handleSyscallUpdates(cpu, state.registers, v0, v1);
            setStateCpuScalars(state, cpu);

            out_ = outputState();
        }
    }

    /// @notice Computes the hash of the MIPS state.
    /// @return out_ The hashed MIPS state.
    function outputState() internal returns (bytes32 out_) {
        assembly {
            // copies 'size' bytes, right-aligned in word at 'from', to 'to', incl. trailing data
            function copyMem(from, to, size) -> fromOut, toOut {
                mstore(to, mload(add(from, sub(32, size))))
                fromOut := add(from, 32)
                toOut := add(to, size)
            }

            // From points to the MIPS State
            let from := 0x80

            // Copy to the free memory pointer
            let start := mload(0x40)
            let to := start

            // Copy state to free memory
            from, to := copyMem(from, to, 32) // memRoot
            from, to := copyMem(from, to, 32) // preimageKey
            from, to := copyMem(from, to, 4) // preimageOffset
            from, to := copyMem(from, to, 4) // heap
            let exitCode := mload(from)
            from, to := copyMem(from, to, 1) // exitCode
            let exited := mload(from)
            from, to := copyMem(from, to, 1) // exited
            from, to := copyMem(from, to, 8) // step
            from, to := copyMem(from, to, 1) // traverseLeft
            from, to := copyMem(from, to, 32) // leftThreadStack
            from, to := copyMem(from, to, 32) // rightThreadStack

            // Clean up end of memory
            mstore(to, 0)

            // Log the resulting MIPS state, for debugging
            log0(start, sub(to, start))

            // Determine the VM status
            let status := 0
            switch exited
            case 1 {
                switch exitCode
                // VMStatusValid
                case 0 { status := 0 }
                // VMStatusInvalid
                case 1 { status := 1 }
                // VMStatusPanic
                default { status := 2 }
            }
            // VMStatusUnfinished
            default { status := 3 }

            // Compute the hash of the resulting MIPS state and set the status byte
            out_ := keccak256(start, sub(to, start))
            out_ := or(and(not(shl(248, 0xFF)), out_), shl(248, status))
        }
    }

    function preemptThread(State memory state, ThreadContext memory thread, bytes32 previousThreadRoot) internal pure {
        // pop thread from the current stack
        if (state.traverseLeft) {
            state.leftThreadStack = previousThreadRoot;
        }  else {
            state.rightThreadStack = previousThreadRoot;
        }

        // push thread to the other stack
        state.traverseLeft = !state.traverseLeft;
        updateThreadStack(state, thread);
    }

    function updateThreadStack(State memory state, ThreadContext memory thread) internal pure {
        // w_i = hash(w_0 ++ hash(thread))
        bytes32 newRoot;
        bytes32 currentRoot = state.traverseLeft ? state.leftThreadStack : state.rightThreadStack;
        bytes32 threadRoot = outputThreadState(thread);
        assembly {
            let memptr := mload(0x40) // free memory pointer
            mstore(memptr, currentRoot)
            mstore(add(memptr, 0x20), threadRoot)
            mstore(0x40, add(memptr, 0x40))
            newRoot := keccak256(memptr, 0x40)
        }
        if (state.traverseLeft) {
            state.leftThreadStack = newRoot;
        } else {
            state.rightThreadStack = newRoot;
        }
    }

    function outputThreadState(ThreadContext memory thread) internal pure returns (bytes32 out_) {
        assembly {
            // copies 'size' bytes, right-aligned in word at 'from', to 'to', incl. trailing data
            function copyMem(from, to, size) -> fromOut, toOut {
                mstore(to, mload(add(from, sub(32, size))))
                fromOut := add(from, 32)
                toOut := add(to, size)
            }

            // From points to the ThreadContext
            let from := thread

            // Copy to the free memory pointer
            let start := mload(0x40)
            let to := start

            // Copy state to free memory
            from, to := copyMem(from, to, 4) // threadID
            from, to := copyMem(from, to, 1) // exitCode
            from, to := copyMem(from, to, 1) // exited
            from, to := copyMem(from, to, 4) // futexAddr
            from, to := copyMem(from, to, 4) // futexVal
            from, to := copyMem(from, to, 8) // futexTimeoutStep
            from, to := copyMem(from, to, 4) // pc
            from, to := copyMem(from, to, 4) // nextPC
            from, to := copyMem(from, to, 4) // lo
            from, to := copyMem(from, to, 4) // hi
            from := add(from, 32) // offset to registers
            // Copy registers
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } { from, to := copyMem(from, to, 4) }

            // Clean up end of memory
            mstore(to, 0)

            // Log the resulting ThreadContext, for debugging
            log0(start, sub(to, start))

            // Compute the hash of the resulting ThreadContext
            out_ := keccak256(start, sub(to, start))
        }
    }

    function getCpuScalars(ThreadContext memory _tc) internal pure returns (st.CpuScalars memory) {
        return st.CpuScalars({ pc: _tc.pc, nextPC: _tc.nextPC, lo: _tc.lo, hi: _tc.hi });
    }

    function setStateCpuScalars(ThreadContext memory _tc, st.CpuScalars memory _cpu) internal pure {
        _tc.pc = _cpu.pc;
        _tc.nextPC = _cpu.nextPC;
        _tc.lo = _cpu.lo;
        _tc.hi = _cpu.hi;
    }
}
