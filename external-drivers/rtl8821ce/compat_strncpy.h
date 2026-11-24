/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Linux 7.2 removed strncpy(). This driver still uses it in many places,
 * often relying on its exact semantics (copy at most n bytes, zero-pad the
 * rest, no terminator when the source is n bytes or longer), so keep it
 * working with a private copy of the pre-7.2 lib/string.c implementation
 * instead of rewriting every call site. Force-included from the Makefile.
 */
#ifndef __RTW_COMPAT_STRNCPY_H__
#define __RTW_COMPAT_STRNCPY_H__

#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
#include <linux/types.h>

static inline char *rtw_compat_strncpy(char *dest, const char *src, size_t count)
{
	char *tmp = dest;

	while (count) {
		if ((*tmp = *src) != 0)
			src++;
		tmp++;
		count--;
	}
	return dest;
}
#define strncpy(dest, src, count) rtw_compat_strncpy((dest), (src), (count))
#endif

#endif /* __RTW_COMPAT_STRNCPY_H__ */
