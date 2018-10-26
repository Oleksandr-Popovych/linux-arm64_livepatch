/*
 * arch/arm64/kernel/entry-ftrace.S
 *
 * Copyright (C) 2013 Linaro Limited
 * Author: AKASHI Takahiro <takahiro.akashi@linaro.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/linkage.h>
#include <asm/assembler.h>
#include <asm/ftrace.h>
#include <asm/insn.h>
#include <asm/asm-offsets.h>
#include <asm/assembler.h>

/*
 * Gcc with -pg will put the following code in the beginning of each function:
 *      mov x0, x30
 *      bl _mcount
 *	[function's body ...]
 * "bl _mcount" may be replaced to "bl ftrace_caller" or NOP if dynamic
 * ftrace is enabled.
 *
 * Please note that x0 as an argument will not be used here because we can
 * get lr(x30) of instrumented function at any time by winding up call stack
 * as long as the kernel is compiled without -fomit-frame-pointer.
 * (or CONFIG_FRAME_POINTER, this is forced on arm64)
 *
 * stack layout after mcount_enter in _mcount():
 *
 * current sp/fp =>  0:+-----+
 * in _mcount()        | x29 | -> instrumented function's fp
 *                     +-----+
 *                     | x30 | -> _mcount()'s lr (= instrumented function's pc)
 * old sp       => +16:+-----+
 * when instrumented   |     |
 * function calls      | ... |
 * _mcount()           |     |
 *                     |     |
 * instrumented => +xx:+-----+
 * function's fp       | x29 | -> parent's fp
 *                     +-----+
 *                     | x30 | -> instrumented function's lr (= parent's pc)
 *                     +-----+
 *                     | ... |
 */

	.macro mcount_enter
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	.endm

	.macro mcount_exit
	ldp	x29, x30, [sp], #16
	ret
	.endm

	.macro mcount_adjust_addr rd, rn
	sub	\rd, \rn, #AARCH64_INSN_SIZE
	.endm

	/* for instrumented function's parent */
	.macro mcount_get_parent_fp reg
	ldr	\reg, [x29]
	ldr	\reg, [\reg]
	.endm

	/* for instrumented function */
	.macro mcount_get_pc0 reg
	mcount_adjust_addr	\reg, x30
	.endm

	.macro mcount_get_pc reg
	ldr	\reg, [x29, #8]
	mcount_adjust_addr	\reg, \reg
	.endm

	.macro mcount_get_lr reg
	ldr	\reg, [x29]
	ldr	\reg, [\reg, #8]
	.endm

	.macro mcount_get_lr_addr reg
	ldr	\reg, [x29]
	add	\reg, \reg, #8
	.endm

#ifndef CONFIG_DYNAMIC_FTRACE
/*
 * void _mcount(unsigned long return_address)
 * @return_address: return address to instrumented function
 *
 * This function makes calls, if enabled, to:
 *     - tracer function to probe instrumented function's entry,
 *     - ftrace_graph_caller to set up an exit hook
 */
ENTRY(_mcount)
	mcount_enter

	ldr_l	x2, ftrace_trace_function
	adr	x0, ftrace_stub
	cmp	x0, x2			// if (ftrace_trace_function
	b.eq	skip_ftrace_call	//     != ftrace_stub) {

	mcount_get_pc	x0		//       function's pc
	mcount_get_lr	x1		//       function's lr (= parent's pc)
	blr	x2			//   (*ftrace_trace_function)(pc, lr);

#ifndef CONFIG_FUNCTION_GRAPH_TRACER
skip_ftrace_call:			//   return;
	mcount_exit			// }
#else
	mcount_exit			//   return;
					// }
skip_ftrace_call:
	ldr_l	x2, ftrace_graph_return
	cmp	x0, x2			//   if ((ftrace_graph_return
	b.ne	ftrace_graph_caller	//        != ftrace_stub)

	ldr_l	x2, ftrace_graph_entry	//     || (ftrace_graph_entry
	adr_l	x0, ftrace_graph_entry_stub //     != ftrace_graph_entry_stub))
	cmp	x0, x2
	b.ne	ftrace_graph_caller	//     ftrace_graph_caller();

	mcount_exit
#endif /* CONFIG_FUNCTION_GRAPH_TRACER */
ENDPROC(_mcount)

#else /* CONFIG_DYNAMIC_FTRACE */
#ifndef CONFIG_DYNAMIC_FTRACE_WITH_REGS
/*
 * _mcount() is used to build the kernel with -pg option, but all the branch
 * instructions to _mcount() are replaced to NOP initially at kernel start up,
 * and later on, NOP to branch to ftrace_caller() when enabled or branch to
 * NOP when disabled per-function base.
 */
ENTRY(_mcount)
	ret
ENDPROC(_mcount)

/*
 * void ftrace_caller(unsigned long return_address)
 * @return_address: return address to instrumented function
 *
 * This function is a counterpart of _mcount() in 'static' ftrace, and
 * makes calls to:
 *     - tracer function to probe instrumented function's entry,
 *     - ftrace_graph_caller to set up an exit hook
 */
ENTRY(ftrace_caller)
	mcount_enter

	mcount_get_pc0	x0		//     function's pc
	mcount_get_lr	x1		//     function's lr

	.global ftrace_call
ftrace_call:				// tracer(pc, lr);
	nop				// This will be replaced with "bl xxx"
					// where xxx can be any kind of tracer.

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
	.global ftrace_graph_call
ftrace_graph_call:			// ftrace_graph_caller();
	nop				// If enabled, this will be replaced
					// "b ftrace_graph_caller"
#endif

	mcount_exit
ENDPROC(ftrace_caller)
#else /* CONFIG_DYNAMIC_FTRACE_WITH_REGS */

/*
 * Since no -pg or similar compiler flag is used, there should really be
 * no reference to _mcount; so do not define one. Only some value for
 * MCOUNT_ADDR is needed for comparison. Let it point here to have some
 * sort of magic value that can be recognised when debugging.
 */
	.global _mcount
_mcount:
	ret	/* make it differ from regs caller */

ENTRY(ftrace_regs_caller)
	/* callee's preliminary stack frame: */
	stp	fp, x9, [sp, #-16]!
	mov	fp, sp

	/* our stack frame: */
	stp	fp, lr, [sp, #-S_FRAME_SIZE]!
	add	x9, sp, #16	/* offset to pt_regs */

	stp	x10, x11, [x9, #S_X10]
	stp	x12, x13, [x9, #S_X12]
	stp	x14, x15, [x9, #S_X14]
	stp	x16, x17, [x9, #S_X16]
	stp	x18, x19, [x9, #S_X18]
	stp	x20, x21, [x9, #S_X20]
	stp	x22, x23, [x9, #S_X22]
	stp	x24, x25, [x9, #S_X24]
	stp	x26, x27, [x9, #S_X26]

	b	ftrace_common
ENDPROC(ftrace_regs_caller)

ENTRY(ftrace_caller)
	/* callee's preliminary stack frame: */
	stp	fp, x9, [sp, #-16]!
	mov	fp, sp

	/* our stack frame: */
	stp	fp, lr, [sp, #-S_FRAME_SIZE]!
	add	x9, sp, #16	/* offset to pt_regs */

ftrace_common:
	/*
	 * At this point we have 2 new stack frames, and x9 pointing
	 * at a pt_regs which we can populate as needed.
	 */

	/* save function arguments */
	stp	x0, x1, [x9]
	stp	x2, x3, [x9, #S_X2]
	stp	x4, x5, [x9, #S_X4]
	stp	x6, x7, [x9, #S_X6]
	stp	x8, x9, [x9, #S_X8]

	ldr	x0, [fp]
	stp	x28, x0, [x9, #S_X28]	/* FP in pt_regs + "our" x28 */

	/* The program counter just after the ftrace call site */
	str	lr, [x9, #S_PC]
	/* The stack pointer as it was on ftrace_caller entry... */
	add	x28, fp, #16
	str	x28, [x9, #S_SP]
	/* The link Register at callee entry */
	ldr	x28, [fp, 8]
	str	x28, [x9, #S_LR]	/* to pt_regs.r[30] */

#if defined(CONFIG_LIVEPATCH) && defined(CONFIG_FUNCTION_GRAPH_TRACER)
	mov	x28, lr		/* remember old return address */
#endif

	ldr_l	x2, function_trace_op, x0
	ldr	x1, [fp, #8]
	sub	x0, lr, #8	/* function entry == IP */
	mov	x3, x9		/* pt_regs are @x9 */

	mov	fp, sp

	.global ftrace_call
ftrace_call:

	bl	ftrace_stub

#if defined(CONFIG_LIVEPATCH) && defined(CONFIG_FUNCTION_GRAPH_TRACER)
	/* Is the trace function a live patcher an has messed with
	 * the return address?
	 */
	add	x9, sp, #16	/* advance to pt_regs for restore */
	ldr	x0, [x9, #S_PC]
	cmp	x0, x28		/* compare with the value we remembered */
	/* to not call graph tracer's "call" mechanism twice! */
	b.ne	ftrace_common_return
#endif

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
	.global ftrace_graph_call
ftrace_graph_call:			// ftrace_graph_caller();
	nop				// If enabled, this will be replaced
					// "b ftrace_graph_caller"
#endif

ftrace_common_return:
	add	x9, sp, #16	/* advance to pt_regs for restore */

	ldp	x0, x1, [x9]
	ldp	x2, x3, [x9, #S_X2]
	ldp	x4, x5, [x9, #S_X4]
	ldp	x6, x7, [x9, #S_X6]
	ldp	x8, x9, [x9, #S_X8]

	ldp	x28, fp, [x9, #S_X28]

	ldr	lr, [x9, #S_LR]
	ldr	x9, [x9, #S_PC]
	/* clean up both frames, ours and callee preliminary */
	add	sp, sp, #S_FRAME_SIZE + 16

	ret	x9

ENDPROC(ftrace_caller)

#endif /* CONFIG_DYNAMIC_FTRACE_WITH_REGS */
#endif /* CONFIG_DYNAMIC_FTRACE */

ENTRY(ftrace_stub)
	ret
ENDPROC(ftrace_stub)

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
	/* save return value regs*/
	.macro save_return_regs
	sub sp, sp, #64
	stp x0, x1, [sp]
	stp x2, x3, [sp, #16]
	stp x4, x5, [sp, #32]
	stp x6, x7, [sp, #48]
	.endm

	/* restore return value regs*/
	.macro restore_return_regs
	ldp x0, x1, [sp]
	ldp x2, x3, [sp, #16]
	ldp x4, x5, [sp, #32]
	ldp x6, x7, [sp, #48]
	add sp, sp, #64
	.endm

/*
 * void ftrace_graph_caller(void)
 *
 * Called from _mcount() or ftrace_caller() when function_graph tracer is
 * selected.
 * This function w/ prepare_ftrace_return() fakes link register's value on
 * the call stack in order to intercept instrumented function's return path
 * and run return_to_handler() later on its exit.
 */
ENTRY(ftrace_graph_caller)
#ifndef CONFIG_DYNAMIC_FTRACE_WITH_REGS
	mcount_get_lr_addr	  x0	//     pointer to function's saved lr
	mcount_get_pc		  x1	//     function's pc
	mcount_get_parent_fp	  x2	//     parent's fp
	bl	prepare_ftrace_return	// prepare_ftrace_return(&lr, pc, fp)

	mcount_exit
#else
	add	x9, sp, #16	/* advance to pt_regs to gather args */
	add	x0, x9, #S_LR		   /* &lr */
	ldr	x1, [x9, #S_PC]		   /* pc */
	ldr	x2, [x9, #S_STACKFRAME]	   /* fp */
	bl	prepare_ftrace_return
	b	ftrace_common_return
#endif
ENDPROC(ftrace_graph_caller)

/*
 * void return_to_handler(void)
 *
 * Run ftrace_return_to_handler() before going back to parent.
 * @fp is checked against the value passed by ftrace_graph_caller()
 * only when HAVE_FUNCTION_GRAPH_FP_TEST is enabled.
 */
ENTRY(return_to_handler)
	save_return_regs
	mov	x0, x29			//     parent's fp
	bl	ftrace_return_to_handler// addr = ftrace_return_to_hander(fp);
	mov	x30, x0			// restore the original return address
	restore_return_regs
	ret
END(return_to_handler)
#endif /* CONFIG_FUNCTION_GRAPH_TRACER */
