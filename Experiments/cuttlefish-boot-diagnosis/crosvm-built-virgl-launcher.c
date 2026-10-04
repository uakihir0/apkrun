#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef APKRUN_EXPECTED_CROSVM_SHA256
#error "Build the launcher with build-crosvm-built-virgl-launcher.sh"
#endif

#ifndef APKRUN_EXPECTED_GFXSTREAM_SHA256
#error "Build the launcher with build-crosvm-built-virgl-launcher.sh"
#endif

extern char **environ;

static int verify_ancestor_directories(int directory_fd) {
  int current_fd = fcntl(directory_fd, F_DUPFD_CLOEXEC, 3);
  if (current_fd < 0) {
    fprintf(stderr, "Could not inspect diagnostic directory ancestors: %s\n",
            strerror(errno));
    return -1;
  }

  for (;;) {
    struct stat current_status;
    if (fstat(current_fd, &current_status) != 0 ||
        !S_ISDIR(current_status.st_mode)) {
      fprintf(stderr, "Could not inspect a diagnostic directory ancestor: %s\n",
              strerror(errno));
      close(current_fd);
      return -1;
    }
    const bool writable_by_untrusted_owner =
        current_status.st_uid != geteuid() && current_status.st_uid != 0 &&
        (current_status.st_mode & S_IWUSR) != 0;
    const bool writable_by_group_or_other =
        (current_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 &&
        !((current_status.st_mode & S_ISVTX) != 0 &&
          current_status.st_uid == 0);
    if (writable_by_untrusted_owner || writable_by_group_or_other) {
      fprintf(stderr, "A diagnostic directory ancestor is writable by other "
                      "users\n");
      close(current_fd);
      return -1;
    }

    const int parent_fd =
        openat(current_fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent_fd < 0) {
      fprintf(stderr, "Could not open a diagnostic directory ancestor: %s\n",
              strerror(errno));
      close(current_fd);
      return -1;
    }
    struct stat parent_status;
    if (fstat(parent_fd, &parent_status) != 0) {
      fprintf(stderr, "Could not inspect a diagnostic directory ancestor: %s\n",
              strerror(errno));
      close(parent_fd);
      close(current_fd);
      return -1;
    }
    if (current_status.st_dev == parent_status.st_dev &&
        current_status.st_ino == parent_status.st_ino) {
      close(parent_fd);
      close(current_fd);
      return 0;
    }
    close(current_fd);
    current_fd = parent_fd;
  }
}

static bool is_loader_variable(const char *entry) {
  return strncmp(entry, "LD_", 3) == 0 ||
         strncmp(entry, "GLIBC_TUNABLES=", 15) == 0;
}

static int clear_loader_environment(void) {
  char **names = NULL;
  size_t count = 0;
  size_t capacity = 0;

  for (char **entry = environ; entry != NULL && *entry != NULL; ++entry) {
    if (!is_loader_variable(*entry)) {
      continue;
    }

    const char *equals = strchr(*entry, '=');
    if (equals == NULL) {
      continue;
    }
    const size_t length = (size_t)(equals - *entry);

    if (count == capacity) {
      const size_t next_capacity = capacity == 0 ? 8 : capacity * 2;
      char **next_names = realloc(names, next_capacity * sizeof(*names));
      if (next_names == NULL) {
        goto allocation_failure;
      }
      names = next_names;
      capacity = next_capacity;
    }

    names[count] = malloc(length + 1);
    if (names[count] == NULL) {
      goto allocation_failure;
    }
    memcpy(names[count], *entry, length);
    names[count][length] = '\0';
    ++count;
  }

  for (size_t index = 0; index < count; ++index) {
    if (unsetenv(names[index]) != 0) {
      fprintf(stderr, "Could not clear loader variable %s: %s\n",
              names[index], strerror(errno));
      for (size_t remaining = index; remaining < count; ++remaining) {
        free(names[remaining]);
      }
      free(names);
      return -1;
    }
    free(names[index]);
  }
  free(names);
  return 0;

allocation_failure:
  for (size_t index = 0; index < count; ++index) {
    free(names[index]);
  }
  free(names);
  fprintf(stderr, "Could not allocate memory to clear loader variables\n");
  return -1;
}

static int adjacent_path(const char *directory, const char *name, char *path,
                         size_t path_size) {
  const int length = snprintf(path, path_size, "%s/%s", directory, name);
  if (length < 0 || (size_t)length >= path_size) {
    fprintf(stderr, "Diagnostic path is too long: %s/%s\n", directory, name);
    return -1;
  }
  return 0;
}

static int open_adjacent_file(int directory_fd, const char *name,
                              mode_t required_permissions) {
  const int descriptor =
      openat(directory_fd, name,
             O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (descriptor < 0) {
    fprintf(stderr, "Could not open adjacent diagnostic file %s: %s\n", name,
            strerror(errno));
    return -1;
  }

  struct stat file_status;
  if (fstat(descriptor, &file_status) != 0 ||
      !S_ISREG(file_status.st_mode) || file_status.st_uid != geteuid() ||
      (file_status.st_mode & required_permissions) != required_permissions ||
      (file_status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    fprintf(stderr, "Adjacent diagnostic file is not a safe regular file: %s\n",
            name);
    close(descriptor);
    return -1;
  }
  return descriptor;
}

static int verify_sha256(int file_fd, const char *label,
                         const char *expected_sha256) {
  const int verified_file_fd = fcntl(file_fd, F_DUPFD_CLOEXEC, 3);
  if (verified_file_fd < 0) {
    fprintf(stderr, "Could not reserve a file descriptor for the %s hash: %s\n",
            label, strerror(errno));
    return -1;
  }

  int output_pipe[2];
  if (pipe(output_pipe) != 0) {
    fprintf(stderr, "Could not create a hash-check pipe: %s\n",
            strerror(errno));
    close(verified_file_fd);
    return -1;
  }

  const pid_t child = fork();
  if (child < 0) {
    fprintf(stderr, "Could not start a hash check: %s\n", strerror(errno));
    close(output_pipe[0]);
    close(output_pipe[1]);
    close(verified_file_fd);
    return -1;
  }
  if (child == 0) {
    close(output_pipe[0]);
    if (dup2(output_pipe[1], STDOUT_FILENO) < 0) {
      _exit(127);
    }
    close(output_pipe[1]);

    const int descriptor_flags = fcntl(verified_file_fd, F_GETFD);
    if (descriptor_flags < 0 ||
        fcntl(verified_file_fd, F_SETFD, descriptor_flags & ~FD_CLOEXEC) < 0) {
      _exit(127);
    }
    char descriptor_path[64];
    const int descriptor_path_length =
        snprintf(descriptor_path, sizeof(descriptor_path), "/proc/self/fd/%d",
                 verified_file_fd);
    if (descriptor_path_length < 0 ||
        (size_t)descriptor_path_length >= sizeof(descriptor_path)) {
      _exit(127);
    }
    char *const arguments[] = {"/usr/bin/sha256sum", "--", descriptor_path,
                               NULL};
    char *const environment[] = {"LC_ALL=C", "PATH=/usr/bin:/bin", NULL};
    execve(arguments[0], arguments, environment);
    _exit(127);
  }

  close(output_pipe[1]);
  char output[256];
  size_t output_length = 0;
  while (output_length < sizeof(output) - 1) {
    const ssize_t amount =
        read(output_pipe[0], output + output_length,
             sizeof(output) - 1 - output_length);
    if (amount < 0 && errno == EINTR) {
      continue;
    }
    if (amount < 0) {
      fprintf(stderr, "Could not read the %s hash result: %s\n", label,
              strerror(errno));
      close(output_pipe[0]);
      waitpid(child, NULL, 0);
      close(verified_file_fd);
      return -1;
    }
    if (amount == 0) {
      break;
    }
    output_length += (size_t)amount;
  }
  close(output_pipe[0]);
  output[output_length] = '\0';

  int child_status = 0;
  while (waitpid(child, &child_status, 0) < 0) {
    if (errno != EINTR) {
      fprintf(stderr, "Could not collect the %s hash result: %s\n", label,
              strerror(errno));
      close(verified_file_fd);
      return -1;
    }
  }
  close(verified_file_fd);
  if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0 ||
      output_length < 65 || output[64] != ' ' ||
      strncmp(output, expected_sha256, 64) != 0) {
    fprintf(stderr, "The %s SHA-256 does not match the launcher build\n",
            label);
    return -1;
  }
  fprintf(stderr, "Verified staged %s SHA-256: %.64s\n", label, output);
  return 0;
}

int main(int argc, char **argv) {
  (void)argc;

  char executable[PATH_MAX];
  const ssize_t executable_length =
      readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (executable_length < 0 ||
      (size_t)executable_length >= sizeof(executable) - 1) {
    fprintf(stderr, "Could not resolve the diagnostic launcher path: %s\n",
            strerror(errno));
    return 127;
  }
  executable[executable_length] = '\0';

  char *directory_end = strrchr(executable, '/');
  if (directory_end == NULL) {
    fprintf(stderr, "Diagnostic launcher path is not absolute\n");
    return 127;
  }
  if (directory_end == executable) {
    directory_end[1] = '\0';
  } else {
    *directory_end = '\0';
  }

  const int directory_fd =
      open(executable, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (directory_fd < 0) {
    fprintf(stderr, "Could not open the diagnostic directory: %s\n",
            strerror(errno));
    return 127;
  }
  struct stat directory_status;
  if (fstat(directory_fd, &directory_status) != 0 ||
      !S_ISDIR(directory_status.st_mode) ||
      directory_status.st_uid != geteuid() ||
      (directory_status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    fprintf(stderr, "The diagnostic directory must be user-owned and not "
                    "group- or world-writable\n");
    close(directory_fd);
    return 127;
  }
  if (verify_ancestor_directories(directory_fd) != 0) {
    close(directory_fd);
    return 127;
  }

  /*
   * The dynamic linker resolves gfxstream by pathname after exec. The
   * directory-ancestor checks exclude other users as writers; same-UID
   * processes are trusted, as this diagnostic launcher is not a security
   * boundary.
   */
  if (clear_loader_environment() != 0) {
    close(directory_fd);
    return 127;
  }

  char crosvm[PATH_MAX];
  char gfxstream[PATH_MAX];
  if (adjacent_path(executable, "crosvm", crosvm, sizeof(crosvm)) != 0 ||
      adjacent_path(executable, "libgfxstream_backend.so", gfxstream,
                    sizeof(gfxstream)) != 0) {
    close(directory_fd);
    return 127;
  }

  const int crosvm_fd =
      open_adjacent_file(directory_fd, "crosvm", S_IRUSR | S_IXUSR);
  const int gfxstream_fd =
      open_adjacent_file(directory_fd, "libgfxstream_backend.so", S_IRUSR);
  if (crosvm_fd < 0 || gfxstream_fd < 0) {
    if (crosvm_fd >= 0) {
      close(crosvm_fd);
    }
    if (gfxstream_fd >= 0) {
      close(gfxstream_fd);
    }
    close(directory_fd);
    return 127;
  }
  if (verify_sha256(crosvm_fd, "crosvm input",
                    APKRUN_EXPECTED_CROSVM_SHA256) != 0 ||
      verify_sha256(gfxstream_fd, "libgfxstream_backend.so input",
                    APKRUN_EXPECTED_GFXSTREAM_SHA256) != 0) {
    close(crosvm_fd);
    close(gfxstream_fd);
    close(directory_fd);
    return 127;
  }
  close(gfxstream_fd);

  const char *libgcc_s = "/lib/aarch64-linux-gnu/libgcc_s.so.1";
  if (access(libgcc_s, R_OK) != 0) {
    fprintf(stderr, "The ARM64 libgcc_s library is missing: %s\n", libgcc_s);
    close(crosvm_fd);
    close(directory_fd);
    return 127;
  }

  if (setenv("LD_LIBRARY_PATH", executable, 1) != 0 ||
      setenv("LD_PRELOAD", libgcc_s, 1) != 0) {
    fprintf(stderr, "Could not set diagnostic crosvm loader environment: %s\n",
            strerror(errno));
    close(crosvm_fd);
    close(directory_fd);
    return 127;
  }

  fprintf(stderr, "APKRun diagnostic Virgl crosvm launcher invoked\n");
  argv[0] = crosvm;
  fexecve(crosvm_fd, argv, environ);
  fprintf(stderr, "Could not execute diagnostic crosvm: %s\n",
          strerror(errno));
  close(crosvm_fd);
  close(directory_fd);
  return 127;
}
