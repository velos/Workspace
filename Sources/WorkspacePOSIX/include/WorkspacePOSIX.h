#ifndef WORKSPACE_POSIX_H
#define WORKSPACE_POSIX_H
#include <stdint.h>
int workspace_filesystem_type(int fd, uint64_t *type);
int workspace_directory_flags(int fd, uint32_t *flags);
int workspace_xfs_case_insensitive(int fd, int *insensitive);
#endif
