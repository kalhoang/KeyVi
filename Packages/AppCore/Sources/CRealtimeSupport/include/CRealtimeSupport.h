// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lock-free atomic operations on 8-, 32- and 64-bit words for RealtimeSupport's `Atomic`, `UnsafeAtomic` and
// `AtomicUInt64Array` (docs/decisions/0315-minimum-macos-12.md). The Swift `Synchronization` module needs
// macOS 15 and the floor is macOS 12 (PLT-R106), so these wrap the compiler's `__atomic` builtins.
//
// Every function is `static inline` and always inlined: a call from Swift compiles to the instruction (or the
// load-linked/store-conditional loop) the memory order asks for, with no call, lock or allocation (PLT-R304).
// `order` takes the `__ATOMIC_*` values; Swift passes constants, so the order switch folds away.

#ifndef CREALTIMESUPPORT_H
#define CREALTIMESUPPORT_H

#include <stdbool.h>
#include <stdint.h>

#define CRT_INLINE static inline __attribute__((always_inline))

// The Swift ordering types hard-code these values.
_Static_assert(__ATOMIC_RELAXED == 0, "relaxed order value");
_Static_assert(__ATOMIC_ACQUIRE == 2, "acquire order value");
_Static_assert(__ATOMIC_RELEASE == 3, "release order value");
_Static_assert(__ATOMIC_ACQ_REL == 4, "acquire-release order value");
_Static_assert(__ATOMIC_SEQ_CST == 5, "sequentially consistent order value");

// PLT-R105: both slices of the universal binary (arm64, x86_64) have lock-free words of every width used.
_Static_assert(__atomic_always_lock_free(sizeof(uint8_t), 0), "8-bit atomics must be lock-free");
_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0), "32-bit atomics must be lock-free");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "64-bit atomics must be lock-free");
_Static_assert(sizeof(void *) == sizeof(uint64_t), "pointers are stored in 64-bit words");

/// Failure order of a compare-exchange derived from its success order: never a release, never stronger than
/// the success order (C11 7.17.7.4).
CRT_INLINE int crt_failure_order(int order) {
    switch (order) {
    case __ATOMIC_RELEASE: return __ATOMIC_RELAXED;
    case __ATOMIC_ACQ_REL: return __ATOMIC_ACQUIRE;
    default: return order;
    }
}

#define CRT_DEFINE_ATOMICS(suffix, type)                                                                    \
    CRT_INLINE type crt_load_##suffix(const type *address, int order) {                                    \
        return __atomic_load_n(address, order);                                                            \
    }                                                                                                       \
    CRT_INLINE void crt_store_##suffix(type *address, type value, int order) {                             \
        __atomic_store_n(address, value, order);                                                           \
    }                                                                                                       \
    CRT_INLINE type crt_exchange_##suffix(type *address, type value, int order) {                          \
        return __atomic_exchange_n(address, value, order);                                                 \
    }                                                                                                       \
    CRT_INLINE bool crt_compare_exchange_##suffix(type *address, type *expected, type desired, int order) { \
        return __atomic_compare_exchange_n(address, expected, desired, false, order, crt_failure_order(order)); \
    }                                                                                                       \
    CRT_INLINE type crt_fetch_add_##suffix(type *address, type value, int order) {                         \
        return __atomic_fetch_add(address, value, order);                                                  \
    }                                                                                                       \
    CRT_INLINE type crt_fetch_sub_##suffix(type *address, type value, int order) {                         \
        return __atomic_fetch_sub(address, value, order);                                                  \
    }

CRT_DEFINE_ATOMICS(u8, uint8_t)
CRT_DEFINE_ATOMICS(u32, uint32_t)
CRT_DEFINE_ATOMICS(u64, uint64_t)

#undef CRT_DEFINE_ATOMICS

#endif
