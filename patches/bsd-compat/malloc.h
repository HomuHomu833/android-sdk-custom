#pragma once
#if defined(__OpenBSD__)
/* OpenBSD has no <malloc.h>; relevant declarations are in <stdlib.h>. */
#include <stdlib.h>
#else
/* FreeBSD/NetBSD have a real <malloc.h> in the sysroot; forward to it. */
#include_next <malloc.h>
#endif
