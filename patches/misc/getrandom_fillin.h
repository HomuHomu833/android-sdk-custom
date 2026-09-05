/* Copyright (c) 2020, Google Inc.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
 * OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. */

#ifndef OPENSSL_HEADER_CRYPTO_RAND_GETRANDOM_FILLIN_H
#define OPENSSL_HEADER_CRYPTO_RAND_GETRANDOM_FILLIN_H

#include <openssl/base.h>


#if defined(OPENSSL_LINUX)

#include <sys/syscall.h>

// Trust <sys/syscall.h> instead of upstream's EXPECTED_NR_getrandom table: that
// table only backstops headers lacking the number, and it drifts on the less
// common ABIs (x32, hexagon, mips o32/n32/n64) and trips its own #error. Without
// __NR_getrandom, USE_NR_getrandom stays undefined and BoringSSL uses
// /dev/urandom.
#if defined(__NR_getrandom)
#define USE_NR_getrandom
#endif

#if !defined(GRND_NONBLOCK)
#define GRND_NONBLOCK 1
#endif
#if !defined(GRND_RANDOM)
#define GRND_RANDOM 2
#endif

#endif  // OPENSSL_LINUX


#endif  // OPENSSL_HEADER_CRYPTO_RAND_GETRANDOM_FILLIN_H
