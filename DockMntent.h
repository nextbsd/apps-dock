/* setmntent/getmntent for systems without <mntent.h>, built on getmntinfo. */
#ifndef DOCK_MNTENT_H
#define DOCK_MNTENT_H

#ifdef __linux__
#include <mntent.h>
#else
#include <stdio.h>
#include <string.h>
#include <sys/param.h>
#include <sys/ucred.h>
#include <sys/mount.h>

#ifndef _PATH_MOUNTED
#define _PATH_MOUNTED "/etc/mtab"
#endif

struct mntent
{
  char *mnt_fsname;
  char *mnt_dir;
  char *mnt_type;
  char *mnt_opts;
};

static struct statfs *dock_mounts;
static int dock_mount_count;
static int dock_mount_index;

static inline FILE *
setmntent(const char *filename, const char *type)
{
  (void)filename;
  (void)type;
  dock_mount_count = getmntinfo(&dock_mounts, MNT_NOWAIT);
  dock_mount_index = 0;
  return dock_mount_count > 0 ? (FILE *)dock_mounts : NULL;
}

static inline struct mntent *
getmntent(FILE *stream)
{
  static struct mntent entry;
  struct statfs *fs;

  (void)stream;
  if (dock_mount_index >= dock_mount_count)
    {
      return NULL;
    }
  fs = &dock_mounts[dock_mount_index++];
  entry.mnt_fsname = fs->f_mntfromname;
  entry.mnt_dir = fs->f_mntonname;
  /* Callers look for type "proc" to find the Linux-style process tree. */
  entry.mnt_type = strcmp(fs->f_fstypename, "linprocfs") == 0
    ? "proc" : fs->f_fstypename;
  entry.mnt_opts = "";
  return &entry;
}

static inline int
endmntent(FILE *stream)
{
  (void)stream;
  return 1;
}
#endif

#endif
