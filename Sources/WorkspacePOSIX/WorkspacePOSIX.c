#include "WorkspacePOSIX.h"
#include <sys/vfs.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <string.h>

// Swift Glibc omits statfs and the architecture-dependent ioctl request macros.
int workspace_filesystem_type(int fd, uint64_t *type) {
    struct statfs info;
    if (fstatfs(fd, &info) < 0) return -1;
    *type = (uint64_t)info.f_type;
    return 0;
}

int workspace_directory_flags(int fd, uint32_t *flags) {
    int value = 0;
    if (ioctl(fd, FS_IOC_GETFLAGS, &value) < 0) return -1;
    *flags = (uint32_t)value;
    return 0;
}

int workspace_xfs_case_insensitive(int fd, int *insensitive) {
    // XFS_IOC_FSGEOMETRY's stable v5 ABI: 256 bytes, uint32_t flags at offset 92.
    // Use the system ioctl encoding without requiring the optional libxfs headers.
    // https://github.com/torvalds/linux/blob/master/fs/xfs/libxfs/xfs_fs.h
    struct { uint64_t words[32]; } geometry = {0};
    if (ioctl(fd, _IOR('X', 126, geometry), &geometry) < 0) return -1;
    uint32_t flags;
    memcpy(&flags, (const unsigned char *)&geometry + 92, sizeof(flags));
    *insensitive = (flags & (1U << 12)) != 0; // XFS_FSOP_GEOM_FLAGS_DIRV2CI
    return 0;
}
