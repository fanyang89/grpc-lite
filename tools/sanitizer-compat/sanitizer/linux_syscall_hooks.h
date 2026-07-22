// Zig's TSan runtime exports these hooks but does not ship Clang's public header.
#ifndef GRPC_LITE_SANITIZER_LINUX_SYSCALL_HOOKS_H
#define GRPC_LITE_SANITIZER_LINUX_SYSCALL_HOOKS_H

#ifdef __cplusplus
extern "C" {
#endif

void __sanitizer_syscall_pre_impl_close(long fd);
void __sanitizer_syscall_post_impl_close(long res, long fd);

#ifdef __cplusplus
}
#endif

#define __sanitizer_syscall_pre_close(fd) \
  __sanitizer_syscall_pre_impl_close((long)(fd))
#define __sanitizer_syscall_post_close(res, fd) \
  __sanitizer_syscall_post_impl_close((long)(res), (long)(fd))

#endif
