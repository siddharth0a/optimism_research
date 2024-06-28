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
        uint32 futexAddr;
        uint32 futexVal;
        uint64 futexTimeoutStep;
        uint32 pc;
        uint32 nextPC;
        uint32 lo;
        uint32 hi;
        uint32[32] registers;
    }

    /// @notice Stores the VM state.
    ///         Total state size: 32 + 32 + 4 * 4 + 1 + 1 + 8 + 4 + 1 + 32 + 32 = 159 bytes
    ///         If nextPC != pc + 4, then the VM is executing a branch/jump delay slot.
    struct State {
        bytes32 memRoot;
        bytes32 preimageKey;
        uint32 preimageOffset;
        uint32 heap;
        uint8 exitCode;
        bool exited;
        uint64 step;
        uint32 wakeup;
        bool traverseRight;
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

    // The offset of the start of proof calldata (_threadWitness.offset) in the step() function
    uint256 internal constant THREAD_PROOF_OFFSET = 356;

    // The offset of the start of proof calldata (_memProof.offset) in the step() function
    uint256 internal constant MEM_PROOF_OFFSET = 612;

    // The empty thread root - keccak256(bytes32(0) ++ bytes32(0))
    bytes32 internal constant EMPTY_THREAD_ROOT = hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5";

    /// @param _oracle The address of the preimage oracle contract.
    constructor(IPreimageOracle _oracle) {
        ORACLE = _oracle;
    }

    /// @notice Executes a single step of the multi-threaded vm.
    ///         Will revert if any required input state is missing.
    /// @param _stateData The encoded state witness data.
    /// @param _threadWitness The encoded proof data for thread contexts.
    ///                     It's a packed tuple of the thread context and the immediate inner root of current thread stack.
    /// @param _memProof The encoded proof data for leaves within the MIPS VM's memory.
    /// @param _localContext The local key context for the preimage oracle. Optional, can be set as a constant
    ///                      if the caller only requires one set of local keys.
    function step(bytes calldata _stateData, bytes calldata _threadWitness, bytes calldata _memProof, bytes32 _localContext) public returns (bytes32) {
        unchecked {
            State memory state;
            ThreadContext memory thread;

            assembly {
                if iszero(eq(state, 0x80)) {
                    // expected state mem offset check
                    revert(0, 0)
                }
                if iszero(eq(thread, 0x1e0)) {
                    // expected thread mem offset check
                    revert(0, 0)
                }
                if iszero(eq(mload(0x40), shl(5, 58))) {
                    // 4 + 11 state slots + 43 thread slots = 58 expected memory check
                    revert(0, 0)
                }
                if iszero(eq(_stateData.offset, 164)) {
                    // 32*5+4=164 expected state data offset
                    revert(0, 0)
                }
                if iszero(eq(_threadWitness.offset, THREAD_PROOF_OFFSET)) {
                    // 164+160+32=356 expected thread proof offset
                    revert(0, 0)
                }
                // TODO: move this to later. Only check proof when actually needed at instruction read
                if iszero(eq(_memProof.offset, MEM_PROOF_OFFSET)) {
                    // 356+224+32=612 expected memory proof offset
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
                c, m := putField(c, m, 4) // wakeup
                c, m := putField(c, m, 1) // traverseRight
                c, m := putField(c, m, 32) // leftThreadStack
                c, m := putField(c, m, 32) // rightThreadStack
            }

            if (state.exited) {
                return outputState();
            }

            state.step += 1;

            // If we've completed traversing both stacks
            if (state.traverseRight && state.rightThreadStack == EMPTY_THREAD_ROOT) {
                state.traverseRight = false;
                state.wakeup = 0xFF_FF_FF_FF;
                return outputState();
            }

            setThreadContextFromCalldata(thread);
            validateThreadWitness(state, thread);

            // Skip thread if it already exited
            if (thread.exited) {
                preemptThread(state, thread);
                return outputState();
            }

           	// Search for the first thread blocked by the wakeup call, if wakeup is set
	        // Don't allow regular execution until we resolved if we have woken up any thread.
            if (state.wakeup != 0xFF_FF_FF_FF && state.wakeup != thread.futexAddr) {
                preemptThread(state, thread);
                return outputState();
            }

            // check if thread is blocked on a futex
            if (thread.futexAddr != 0xFF_FF_FF_FF) { // if set, then check futex
                // check timeout first
                if (thread.futexTimeoutStep > state.step) {
                    // timeout! Allow execution
                    return onWaitComplete(state, thread);
                } else {
                    uint32 mem = MIPSMemory.readMem(state.memRoot, thread.futexAddr & 0xFFffFFfc, MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1));
                    if (thread.futexVal == mem) {
                        // still got expected value, continue sleeping, try next thread.
                        preemptThread(state, thread);
                        return outputState();
                    } else {
                        // wake thread up, the value at its address changed!
				        // Userspace can turn thread back to sleep if it was too sporadic.
                        return onWaitComplete(state, thread);
                    }
                }
            }

            // instruction fetch
            uint256 insnProofOffset = MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 0);
            (uint32 insn, uint32 opcode, uint32 fun) =
                ins.getInstructionDetails(thread.pc, state.memRoot, insnProofOffset);

            // Handle syscall separately
            // syscall (can read and write)
            if (opcode == 0 && fun == 0xC) {
                return handleSyscall(_localContext);
            }

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
        unchecked {
            // Load state from memory
            State memory state;
            ThreadContext memory thread;
            assembly {
                state := 0x80
                thread := 0x160
            }

            // Load the syscall numbers and args from the registers
            (uint32 syscall_no, uint32 a0, uint32 a1, uint32 a2, uint32 a3) = sys.getSyscallArgs(thread.registers);
            uint32 v0 = 0;
            uint32 v1 = 0;

            if (syscall_no == sys.SYS_MMAP) {
                (v0, v1, state.heap) = sys.handleSysMmap(a0, a1, state.heap);
            } else if (syscall_no == sys.SYS_BRK) {
                // brk: Returns a fixed address for the program break at 0x40000000
                v0 = BRK_START;
            } else if (syscall_no == sys.SYS_CLONE) {
                // TODO: Offchain, the thread ID must be monotonic and unique
                v0 = thread.threadID;
                v1 = 0;
                ThreadContext memory newThread = ThreadContext({
                    threadID: thread.threadID + 1,
                    exitCode: 0,
                    exited: false,
                    futexAddr: 0xFF_FF_FF_FF,
                    futexVal: 0,
                    futexTimeoutStep: 0,
                    pc: thread.nextPC,
                    nextPC: thread.nextPC + 4,
                    lo: thread.lo,
                    hi: thread.hi,
                    registers: thread.registers
                });
                newThread.registers[29] = a1; // set stack pointer
                // the child will perceive a 0 value as returned value instead, and no error
                newThread.registers[2] = 0;
                newThread.registers[7] = 0;

                // add the new thread context to the state
                pushThread(state, newThread);
            } else if (syscall_no == sys.SYS_EXIT_GROUP) {
                // exit group: Sets the Exited and ExitCode states to true and argument 0.
                state.exited = true;
                state.exitCode = uint8(a0);
                return outputState();
            } else if (syscall_no == sys.SYS_READ) {
                sys.SysReadParams memory args = sys.SysReadParams({
                    a0: a0,
                    a1: a1,
                    a2: a2,
                    preimageKey: state.preimageKey,
                    preimageOffset: state.preimageOffset,
                    localContext: _localContext,
                    oracle: ORACLE,
                    proofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
                    memRoot: state.memRoot
                });
                (v0, v1, state.preimageOffset, state.memRoot) = sys.handleSysRead(args);
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
                return outputState();
            } else if (syscall_no == sys.SYS_FUTEX) {
                // args: a0 = addr, a1 = op, a2 = val, a3 = timeout
                thread.futexAddr = a0;
                if (a1 == sys.FUTEX_WAIT_PRIVATE) {
                    uint32 mem = MIPSMemory.readMem(state.memRoot, a0 & 0xFFffFFfc, MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1));
                    if (mem != a2) {
                        v0 = 0xFF_FF_FF_FF;
                        v1 = sys.EAGAIN;
                    } else {
                        thread.futexVal = a2;
                        if (a3 != 0) {
                            thread.futexTimeoutStep = state.step + sys.FUTEX_TIMEOUT_STEPS;
                        }
                    }
                } else if (a1 == sys.FUTEX_WAKE_PRIVATE) {
                    // Trigger thread traversal starting from the left stack until we find one waiting on the wakeup address
                    state.wakeup = a0;
                    preemptThread(state, thread);
                    state.traverseRight = false;
                    // Don't indicate to the program that we've woken up a waiting thread, as there are no guarantees.
                    // The woken up thread should indicate this in userspace.
                    v0 = 0;
                    v1 = 0;
               } else {
                    v0 = 0xFF_FF_FF_FF;
                    v1 = sys.EINVAL;
               }
            } else if (syscall_no == sys.SYS_SCHED_YIELD) {
                preemptThread(state, thread);
            } else if (syscall_no == sys.SYS_OPEN) {
                v0 = 0xFF_FF_FF_FF;
                v1 = sys.EBADF;
            } else if (syscall_no == sys.SYS_NANOSLEEP) {
                preemptThread(state, thread);
            }
            // TODO: no-op on the remaining whitelisted syscalls

            st.CpuScalars memory cpu = getCpuScalars(thread);
            sys.handleSyscallUpdates(cpu, thread.registers, v0, v1);
            setStateCpuScalars(thread, cpu);

            out_ = outputState();
        }
    }

    /// @notice Computes the hash of the MIPS state.
    /// @return out_ The hashed MIPS state.
    function outputState() internal returns (bytes32 out_) {
        updateCurrentThreadRoot();

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
            from, to := copyMem(from, to, 4) // wakeup
            from, to := copyMem(from, to, 1) // traverseRight
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

    /// @notice Updates the current thread stack root.
    function updateCurrentThreadRoot() internal pure {
        State memory state;
        ThreadContext memory thread;
        assembly {
            state := 0x80
            thread := 0x160
        }
        bytes32 updatedRoot = computeThreadRoot(loadInnerThreadRoot(), thread);
        if (state.traverseRight) {
            state.rightThreadStack = updatedRoot;
        } else {
            state.leftThreadStack = updatedRoot;
        }
    }

    /// @notice Completes the FUTEX_WAIT syscall.
    function onWaitComplete(State memory _state, ThreadContext memory _thread) internal returns (bytes32 out_) {
        // Clear the futex state
        _thread.futexAddr = 0xFF_FF_FF_FF;
        _thread.futexVal = 0;
        _thread.futexTimeoutStep = 0;

        // Complete the FUTEX_WAIT syscall
        _thread.registers[2] = 0; // 0 because caaller is woken up
        _thread.registers[7] = 0; // 0 because no error
	    _thread.pc = _thread.nextPC;
	    _thread.nextPC = _thread.nextPC + 4;

        _state.wakeup = 0xFF_FF_FF_FF;
        out_ = outputState();
    }

    /// @notice Preempts the current thread for another and updates the VM state.
    function preemptThread(State memory _state, ThreadContext memory _thread) internal pure {
        // pop thread from the current stack and push to the other stack
        if (_state.traverseRight) {
            require(_state.rightThreadStack != EMPTY_THREAD_ROOT, "empty right thread stack");
            _state.rightThreadStack = loadInnerThreadRoot();
            _state.leftThreadStack = computeThreadRoot(_state.leftThreadStack, _thread);
       }  else {
            require(_state.leftThreadStack != EMPTY_THREAD_ROOT, "empty left thread stack");
           _state.leftThreadStack = loadInnerThreadRoot();
            _state.rightThreadStack = computeThreadRoot(_state.rightThreadStack, _thread);
        }
        bytes32 current = _state.traverseRight ? _state.rightThreadStack : _state.leftThreadStack;
        if (current == EMPTY_THREAD_ROOT) {
            _state.traverseRight = !_state.traverseRight;
        }
    }

    /// @notice Pushes a thread to the current thread stack.
    function pushThread(State memory _state, ThreadContext memory _thread) internal pure {
        if (_state.traverseRight) {
            _state.rightThreadStack = computeThreadRoot(_state.rightThreadStack, _thread);
        } else {
            _state.leftThreadStack = computeThreadRoot(_state.leftThreadStack, _thread);
        }
    }

    function computeThreadRoot(bytes32 _currentRoot, ThreadContext memory _thread) internal pure returns (bytes32 _out) {
        // w_i = hash(w_0 ++ hash(thread))
        bytes32 threadRoot = outputThreadState(_thread);
        _out = keccak256(abi.encodePacked(_currentRoot, threadRoot));
    }

    function outputThreadState(ThreadContext memory _thread) internal pure returns (bytes32 out_) {
        assembly {
            // copies 'size' bytes, right-aligned in word at 'from', to 'to', incl. trailing data
            function copyMem(from, to, size) -> fromOut, toOut {
                mstore(to, mload(add(from, sub(32, size))))
                fromOut := add(from, 32)
                toOut := add(to, size)
            }

            // From points to the ThreadContext
            let from := _thread

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
            //log0(start, sub(to, start))

            // Compute the hash of the resulting ThreadContext
            out_ := keccak256(start, sub(to, start))
        }
    }

    function getCpuScalars(ThreadContext memory _tc) internal pure returns (st.CpuScalars memory cpu_) {
        cpu_ = st.CpuScalars({ pc: _tc.pc, nextPC: _tc.nextPC, lo: _tc.lo, hi: _tc.hi });
    }

    function setStateCpuScalars(ThreadContext memory _tc, st.CpuScalars memory _cpu) internal pure {
        _tc.pc = _cpu.pc;
        _tc.nextPC = _cpu.nextPC;
        _tc.lo = _cpu.lo;
        _tc.hi = _cpu.hi;
    }

    /// @notice Validates the thread witness in calldata against the current thread.
    function validateThreadWitness(State memory _state, ThreadContext memory _thread) internal pure {
        bytes32 witnessRoot = computeThreadRoot(loadInnerThreadRoot(), _thread);
        bytes32 expectedRoot = _state.traverseRight ? _state.rightThreadStack : _state.leftThreadStack;
        require(expectedRoot == witnessRoot, "invalid thread witness");
    }

    /// @notice Sets the thread context from calldata.
    function setThreadContextFromCalldata(ThreadContext memory _thread) internal pure {
        uint256 s = 0;
        assembly {
            s := calldatasize()
        }
        // verify we have enough calldata
        require(s >= (THREAD_PROOF_OFFSET + 166), "insufficient calldata for thread witness");

        unchecked {
            assembly {
                function putField(callOffset, memOffset, size) -> callOffsetOut, memOffsetOut {
                    // calldata is packed, thus starting left-aligned, shift-right to pad and right-align
                    let w := shr(shl(3, sub(32, size)), calldataload(callOffset))
                    mstore(memOffset, w)
                    callOffsetOut := add(callOffset, size)
                    memOffsetOut := add(memOffset, 32)
                }

                let c := THREAD_PROOF_OFFSET
                let m := _thread
                c, m := putField(c, m, 4) // threadID
                c, m := putField(c, m, 1) // exitCode
                c, m := putField(c, m, 1) // exited
                c, m := putField(c, m, 4) // futexAddr
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
            }
        }
    }

    /// @notice Loads the inner root for the current thread hash onion from calldata.
    function loadInnerThreadRoot() internal pure returns (bytes32 innerThreadRoot_) {
        uint256 s = 0;
        assembly {
            s := calldatasize()
            innerThreadRoot_ := calldataload(add(THREAD_PROOF_OFFSET, 166))
        }
        // verify we have enough calldata
        require(s >= (THREAD_PROOF_OFFSET + 198), "insufficient calldata for thread witness"); // 166 + 32
    }
}
