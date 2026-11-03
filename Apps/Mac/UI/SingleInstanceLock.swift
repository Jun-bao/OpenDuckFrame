import Darwin

// A kernel record lock has an authoritative owner PID (F_GETLK). The lock
// file is deliberately never unlinked: all cooperating launches must lock
// the same inode, including after a crash or normal exit.
final class SingleInstanceLock {
    enum Attempt { case acquired, busy, failed(Int32) }
    enum Holder { case process(pid_t), unlocked, failed(Int32) }
    private var fd: Int32

    init?(path: String) {
        let file = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { return nil }
        var opened = stat(), named = stat()
        let descriptorFlags = fcntl(file, F_GETFD)
        let valid = fstat(file, &opened) == 0 && lstat(path, &named) == 0 &&
            (opened.st_mode & S_IFMT) == S_IFREG && (named.st_mode & S_IFMT) == S_IFREG &&
            opened.st_uid == getuid() && named.st_uid == getuid() && opened.st_nlink == 1 &&
            (opened.st_mode & 0o077) == 0 && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
            descriptorFlags >= 0 && (descriptorFlags & FD_CLOEXEC) != 0
        guard valid else { Darwin.close(file); return nil }
        fd = file
    }

    private func range() -> flock {
        var value = flock()
        value.l_type = Int16(F_WRLCK); value.l_whence = Int16(SEEK_SET)
        value.l_start = 0; value.l_len = 1
        return value
    }

    func tryAcquire() -> Attempt {
        var value = range()
        if fcntl(fd, F_SETLK, &value) == 0 { return .acquired }
        let failure = errno
        return failure == EACCES || failure == EAGAIN ? .busy : .failed(failure)
    }

    func holder() -> Holder {
        var value = range()
        guard fcntl(fd, F_GETLK, &value) == 0 else { return .failed(errno) }
        if value.l_type == Int16(F_UNLCK) { return .unlocked }
        return value.l_pid > 0 ? .process(value.l_pid) : .failed(EINVAL)
    }

    func release() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    deinit { release() }
}
