/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copied unchanged from Sound.app (nextbsd/apps-settings Sound/SNAudio.c,
 * b3d97c0): the sound extra reads and sets the devices the same way.
 * Copy it again when the app's changes.
 *
 * Built without GNUstep's headers: see the GNUmakefile.
 */

#include "bluetooth_mig_types.h"

#include <mach/mach.h>
#include <servers/bootstrap.h>

#include "bluetoothUser.h"		/* MIG user stubs, made by the build */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <dispatch/dispatch.h>
#include <virtual_oss.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "SNAudio.h"

#define SNServiceName "org.nextbsd.bluetooth"

/* bt_audio_entry's role and route (bluetoothd audio.h). */
#define SNRoleSource 1		/* we play to it */
#define SNRouteHandsFree 2

/*
 * NextBSD's <notify.h> needs <os/base.h>, which isn't installed, so the
 * two calls used are declared here, as the Dock extras do
 * (apps-dock Extras/Common/DockExtraNotify.h).
 */
extern uint32_t notify_register_dispatch (const char *name, int *out_token,
                                          dispatch_queue_t queue,
                                          void (^handler) (int token));
extern uint32_t notify_cancel (int token);

/* What changes a headset's audio (bluetoothd btstate.h). */
static const char *const SNNotifyNames[] = {
  "org.nextbsd.bluetooth.audio",
  "org.nextbsd.bluetooth.device",
};
#define SNNotifyCount (sizeof (SNNotifyNames) / sizeof (SNNotifyNames[0]))

struct SNAudio
{
  mach_port_t service;
  dispatch_queue_t queue;
  int tokens[SNNotifyCount];
};

struct SNAudioMeter
{
  int fd;			/* the kernel device, or the child's pipe */
  int kind;			/* SNAudio* */
  pid_t pid;			/* a virtual_oss's: the child */
  char ctl[64];
};

/* ---- bluetoothd ---- */

/* bluetoothd's port, looked up again after it went away. */
static mach_port_t
SNService (SNAudio *a)
{
  mach_port_t port = MACH_PORT_NULL;

  if (a->service != MACH_PORT_NULL)
    return a->service;
  if (bootstrap_look_up (bootstrap_port, SNServiceName, &port)
      == KERN_SUCCESS)
    a->service = port;
  return a->service;
}

static void
SNLost (SNAudio *a)
{
  if (a->service != MACH_PORT_NULL)
    (void) mach_port_deallocate (mach_task_self (), a->service);
  a->service = MACH_PORT_NULL;
}

/* One RPC: `expr` uses `svc`; on failure, `fail` is returned. */
#define SNCall(a, expr, fail)                   \
  do                                            \
    {                                           \
      mach_port_t svc = SNService (a);          \
      if (svc == MACH_PORT_NULL)                \
        return (fail);                          \
      if ((expr) != KERN_SUCCESS)               \
        {                                       \
          SNLost (a);                           \
          return (fail);                        \
        }                                       \
    }                                           \
  while (0)

SNAudio *
SNAudioOpen (int wakeFD)
{
  SNAudio *a = calloc (1, sizeof (*a));
  size_t i;

  if (a == NULL)
    abort ();
  a->queue = dispatch_queue_create ("org.nextbsd.Sound.notify", NULL);
  for (i = 0; i < SNNotifyCount; i++)
    {
      a->tokens[i] = -1;
      if (wakeFD >= 0
          && notify_register_dispatch (SNNotifyNames[i], &a->tokens[i],
                                       a->queue, ^(int token) {
                                         char byte = 1;

                                         (void) token;
                                         (void) write (wakeFD, &byte, 1);
                                       }) != 0)
        a->tokens[i] = -1;
    }
  (void) SNService (a);
  return a;
}

void
SNAudioClose (SNAudio *a)
{
  size_t i;

  if (a == NULL)
    return;
  for (i = 0; i < SNNotifyCount; i++)
    if (a->tokens[i] >= 0)
      notify_cancel (a->tokens[i]);
  /* Wait out a handler already running, so wakeFD can be closed. */
  dispatch_sync (a->queue, ^{
  });
  dispatch_release (a->queue);
  SNLost (a);
  free (a);
}

/* The headsets bluetoothd plays to, filled in as devices: name, node,
   volume and hands-free state. Returns how many, or -1 when bluetoothd
   isn't answering. */
static int
SNReadHeadsets (SNAudio *a, SNAudioDevice *out, int max)
{
  bt_status_t st;
  int count = 0, i, n = 0;

  SNCall (a, bt_audio_count (svc, &count, &st), -1);
  if (st != bt_status_success_e)
    return 0;
  for (i = 0; i < count && n < max; i++)
    {
      SNAudioDevice *d = &out[n];
      BTAddressString address;
      BTNodeName node, link, hfpDevice;
      BTTransportName codec;
      BTDeviceName name;
      BTProfileList profiles;
      bt_device_state_t state;
      int role, route, active, avrcp, defaultOut, volume;
      int cod, rssi, paired, connected, audio, pending, features;
      int speaker, mic, battery;

      memset (address, 0, sizeof (address));
      memset (node, 0, sizeof (node));
      SNCall (a, bt_audio_entry (svc, i, address, &role, &route, &active,
                                 &avrcp, &defaultOut, &volume, node, codec,
                                 &st), -1);
      /* Only a headset we play to has a device to show. */
      if (st != bt_status_success_e || role != SNRoleSource
          || node[0] == '\0')
        continue;

      memset (d, 0, sizeof (*d));
      d->kind = SNAudioBluetooth;
      d->unit = -1;
      d->play = 1;
      strlcpy (d->ident, node, sizeof (d->ident));
      strlcpy (d->address, address, sizeof (d->address));
      snprintf (d->dsp, sizeof (d->dsp), "/dev/%s", node);
      snprintf (d->ctl, sizeof (d->ctl), "/dev/%s.ctl", node);
      d->defaultOut = defaultOut != 0;
      d->absoluteVolume = avrcp && volume >= 0 && volume <= 127 ? volume : -1;
      d->microphone = route == SNRouteHandsFree;
      d->battery = -1;

      memset (name, 0, sizeof (name));
      SNCall (a, bt_device_status (svc, address, name, &cod, &state, link,
                                   &rssi, profiles, &paired, &st), -1);
      strlcpy (d->name, st == bt_status_success_e && name[0] != '\0'
               ? name : address, sizeof (d->name));
      /* bluetoothd keeps a headset's mixer while the headset is away,
         to play again when it's back; until then the mixer answers
         nothing, and its devices aren't usable. */
      d->linkUp = st == bt_status_success_e && state == 2;
      if (!d->linkUp)
        {
          d->play = 0;
          n++;
          continue;
        }

      SNCall (a, bt_hfp_status (svc, address, &connected, &audio, &pending,
                                codec, hfpDevice, &features, &speaker, &mic,
                                &battery, &st), -1);
      if (st == bt_status_success_e)
        {
          d->handsFree = connected != 0;
          d->battery = battery;
        }
      d->record = d->handsFree;
      d->defaultIn = d->defaultOut && d->microphone;
      n++;
    }
  return n;
}

/* ---- /dev/sndstat ---- */

static int
SNDefaultUnit (void)
{
  int unit = -1;
  size_t length = sizeof (unit);

  if (sysctlbyname ("hw.snd.default_unit", &unit, &length, NULL, 0) != 0)
    return -1;
  return unit;
}

/* /dev/sndstat, whole: a device, so its size is 0 and it's read to the
   end by hand. Returns a malloc'ed string or NULL. */
static char *
SNReadSndstat (void)
{
  char *text = NULL, *bigger;
  size_t length = 0, size = 0;
  ssize_t n;
  int fd = open ("/dev/sndstat", O_RDONLY | O_CLOEXEC);

  if (fd < 0)
    return NULL;
  for (;;)
    {
      if (size - length < 1024)
        {
          size = size ? size * 2 : 4096;
          if ((bigger = realloc (text, size)) == NULL)
            break;
          text = bigger;
        }
      if ((n = read (fd, text + length, size - length - 1)) <= 0)
        break;
      length += (size_t) n;
    }
  close (fd);
  if (text != NULL)
    text[length] = '\0';
  return text;
}

/* What a "(play/rec)" or, with hw.snd.verbose, "(1p:1v/1r:1v)" group
   says a device does. */
static void
SNParseDirections (const char *group, int *play, int *record)
{
  int p = 0, r = 0;

  *play = strstr (group, "play") != NULL;
  *record = strstr (group, "rec") != NULL;
  if (!*play && !*record && sscanf (group, "(%dp:%*dv/%dr", &p, &r) == 2)
    {
      *play = p > 0;
      *record = r > 0;
    }
}

/* One sndstat line, "pcm0: <Realtek ALC257 (Analog)> (play/rec) default"
   or "dsp.bt0: <virtual_oss device> (play/rec)". Returns 0 if it isn't a
   device. */
static int
SNParseLine (const char *line, int userspace, SNAudioDevice *d)
{
  const char *colon = strchr (line, ':');
  const char *open = strchr (line, '<');
  const char *close = strrchr (line, '>');
  const char *group;
  size_t n;

  if (colon == NULL || open == NULL || close == NULL || close < open
      || colon > open || colon == line)
    return 0;
  memset (d, 0, sizeof (*d));
  d->unit = -1;
  d->absoluteVolume = -1;
  d->battery = -1;
  n = (size_t) (colon - line);
  if (n >= sizeof (d->ident))
    return 0;
  memcpy (d->ident, line, n);
  d->ident[n] = '\0';
  n = (size_t) (close - open - 1);
  if (n >= sizeof (d->name))
    n = sizeof (d->name) - 1;
  memcpy (d->name, open + 1, n);
  d->name[n] = '\0';
  group = strchr (close, '(');
  if (group != NULL)
    SNParseDirections (group, &d->play, &d->record);

  if (!userspace)
    {
      if (sscanf (d->ident, "pcm%d", &d->unit) != 1)
        return 0;
      d->kind = SNAudioKernel;
      snprintf (d->dsp, sizeof (d->dsp), "/dev/dsp%d", d->unit);
    }
  else
    {
      d->kind = SNAudioVirtual;
      /* Every virtual_oss says "virtual_oss device": add the node. */
      n = strlen (d->name);
      snprintf (d->name + n, sizeof (d->name) - n, " (%s)", d->ident);
      snprintf (d->dsp, sizeof (d->dsp), "/dev/%s", d->ident);
      snprintf (d->ctl, sizeof (d->ctl), "/dev/%s.ctl", d->ident);
      if (access (d->ctl, R_OK | W_OK) != 0)
        d->ctl[0] = '\0';
    }
  return 1;
}

int
SNAudioCopyDevices (SNAudio *a, SNAudioDevice *devices, int max)
{
  SNAudioDevice headsets[SNAudioMaxDevices];
  SNAudioDevice d;
  char *text = SNReadSndstat (), *line, *next;
  int headsetCount = SNReadHeadsets (a, headsets, SNAudioMaxDevices);
  int unit = SNDefaultUnit ();
  int count = 0, userspace = 0, headsetOwnsDsp = 0, i;

  if (headsetCount < 0)
    headsetCount = 0;
  for (i = 0; i < headsetCount; i++)
    if (headsets[i].defaultOut)
      headsetOwnsDsp = 1;

  for (line = text; line != NULL && *line != '\0'; line = next)
    {
      next = strchr (line, '\n');
      if (next != NULL)
        *next++ = '\0';
      if (strncmp (line, "Installed devices from userspace", 32) == 0)
        {
          userspace = 1;
          continue;
        }
      if (count >= max || !SNParseLine (line, userspace, &d))
        continue;
      if (d.kind == SNAudioKernel)
        {
          /* A headset that took /dev/dsp has it, whatever the unit. */
          d.defaultOut = d.play && !headsetOwnsDsp && d.unit == unit;
          d.defaultIn = d.record && !headsetOwnsDsp && d.unit == unit;
        }
      else
        {
          /* bluetoothd's: shown, below, as the headset it is. The plain
             "dsp" a headset makes is the same device again. */
          for (i = 0; i < headsetCount; i++)
            if (strcmp (headsets[i].ident, d.ident) == 0)
              break;
          if (i < headsetCount
              || (strcmp (d.ident, "dsp") == 0 && headsetOwnsDsp))
            continue;
          d.defaultOut = d.play && strcmp (d.ident, "dsp") == 0;
          d.defaultIn = d.record && strcmp (d.ident, "dsp") == 0;
        }
      devices[count++] = d;
    }
  free (text);

  /* A headset that's away is left out. Its mixer still has /dev/dsp,
     so nothing else is the output until it's back (or bluetoothd stops
     it). */
  for (i = 0; i < headsetCount && count < max; i++)
    if (headsets[i].linkUp)
      devices[count++] = headsets[i];
  return count;
}

int
SNAudioDefaultOutput (const SNAudioDevice *devices, int count)
{
  int i;

  for (i = 0; i < count; i++)
    if (devices[i].play && devices[i].defaultOut)
      return i;
  return -1;
}

int
SNAudioDefaultInput (const SNAudioDevice *devices, int count)
{
  int i;

  for (i = 0; i < count; i++)
    if (devices[i].record && devices[i].defaultIn)
      return i;
  return -1;
}

/* ---- kernel mixers ---- */

/* A kernel device's mixer, and the control for `output` (vol, else pcm)
   or for recording (rec, else the recording source). */
static int
SNOpenMixer (const SNAudioDevice *d, int output, int *channel)
{
  char path[32];
  int fd, mask = 0, sources = 0, i;

  snprintf (path, sizeof (path), "/dev/mixer%d", d->unit);
  if ((fd = open (path, O_RDWR | O_CLOEXEC)) < 0)
    return -1;
  if (ioctl (fd, SOUND_MIXER_READ_DEVMASK, &mask) != 0)
    mask = 0;
  *channel = -1;
  if (output)
    {
      if (mask & SOUND_MASK_VOLUME)
        *channel = SOUND_MIXER_VOLUME;
      else if (mask & SOUND_MASK_PCM)
        *channel = SOUND_MIXER_PCM;
    }
  else if (mask & SOUND_MASK_RECLEV)
    *channel = SOUND_MIXER_RECLEV;
  else if (ioctl (fd, SOUND_MIXER_READ_RECSRC, &sources) == 0)
    {
      for (i = 0; i < SOUND_MIXER_NRDEVICES; i++)
        if ((sources & mask) & (1 << i))
          {
            *channel = i;
            break;
          }
    }
  if (*channel < 0)
    {
      close (fd);
      errno = ENODEV;
      return -1;
    }
  return fd;
}

static int
SNMixerGet (const SNAudioDevice *d, int output, int *volume, int *muted)
{
  int channel, level = 0, mutes = 0;
  int fd = SNOpenMixer (d, output, &channel);

  if (fd < 0)
    return -1;
  if (ioctl (fd, MIXER_READ (channel), &level) != 0)
    {
      close (fd);
      return -1;
    }
  *volume = ((level & 0x7f) + ((level >> 8) & 0x7f)) / 2;
  if (muted != NULL)
    *muted = ioctl (fd, SOUND_MIXER_READ_MUTE, &mutes) == 0
      && (mutes & (1 << channel)) != 0;
  close (fd);
  return 0;
}

static int
SNMixerSet (const SNAudioDevice *d, int output, int volume)
{
  int channel, level;
  int fd = SNOpenMixer (d, output, &channel);
  int result;

  if (fd < 0)
    return -1;
  volume = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
  level = volume | (volume << 8);
  result = ioctl (fd, MIXER_WRITE (channel), &level);
  close (fd);
  return result;
}

static int
SNMixerSetMuted (const SNAudioDevice *d, int muted)
{
  int channel, mutes = 0, result = -1;
  int fd = SNOpenMixer (d, 1, &channel);

  if (fd < 0)
    return -1;
  if (ioctl (fd, SOUND_MIXER_READ_MUTE, &mutes) == 0)
    {
      mutes = muted ? (mutes | (1 << channel)) : (mutes & ~(1 << channel));
      result = ioctl (fd, SOUND_MIXER_WRITE_MUTE, &mutes);
    }
  close (fd);
  return result;
}

/* ---- calls that may not come back ----

   A virtual_oss answers its devices' opens and ioctls from the same
   loop that moves its sound. While it can't (bluetoothd's mixer for a
   headset that went away sits in connect(2) until the headset is back),
   an open or ioctl of any of its devices waits for as long as that
   takes, and can't be interrupted: cuse(3) passes a signal on to the
   server and waits for its answer. A thread stuck that way would keep
   its whole process from exiting.

   So every call to a virtual_oss is made in a child process, and waited
   for SNTimeoutMS at most. The child only makes system calls (no
   malloc, which another thread may have held when it forked) and
   _exit()s. One that doesn't answer in time is left to finish when the
   virtual_oss does; its device is marked stuck, further calls to it
   fail at once (EBUSY), and the mark is cleared once the child is gone.
   Neither the app nor the Dock ever waits on a virtual_oss longer than
   that, and either can always quit. */

#define SNTimeoutMS 400
#define SNMaxStuck 8

static char SNStuck[SNMaxStuck][64];
static pid_t SNStuckPid[SNMaxStuck];

/* Forget the stuck children that have finished. */
static void
SNReapStuck (void)
{
  int i, status;

  for (i = 0; i < SNMaxStuck; i++)
    if (SNStuckPid[i] > 0)
      {
        pid_t done = waitpid (SNStuckPid[i], &status, WNOHANG);

        /* ECHILD: someone else (NSTask's SIGCHLD handler) reaped it. */
        if (done == SNStuckPid[i] || (done < 0 && errno == ECHILD))
          {
            SNStuckPid[i] = 0;
            SNStuck[i][0] = '\0';
          }
      }
}

static int
SNIsStuck (const char *key)
{
  int i, free = 0;

  SNReapStuck ();
  for (i = 0; i < SNMaxStuck; i++)
    {
      if (SNStuckPid[i] > 0 && strcmp (SNStuck[i], key) == 0)
        return 1;
      if (SNStuckPid[i] == 0)
        free++;
    }
  /* With every slot taken by a stuck child, start no more. */
  return free == 0;
}

/* Leave pid to finish by itself; key is stuck until it has. */
static void
SNLeaveStuck (const char *key, pid_t pid)
{
  int i;

  for (i = 0; i < SNMaxStuck; i++)
    if (SNStuckPid[i] == 0)
      {
        SNStuckPid[i] = pid;
        strlcpy (SNStuck[i], key, sizeof (SNStuck[i]));
        return;
      }
}

/* Read exactly n bytes from fd by deadline (a CLOCK_MONOTONIC time in
   ms). Returns 0, or -1 when it ran out of time or the writer went. */
static int
SNReadFully (int fd, void *buffer, size_t n, int64_t deadline)
{
  struct pollfd pfd = { fd, POLLIN, 0 };
  struct timespec now;
  size_t got = 0;
  ssize_t r;
  int64_t left;

  while (got < n)
    {
      clock_gettime (CLOCK_MONOTONIC, &now);
      left = deadline - ((int64_t) now.tv_sec * 1000 + now.tv_nsec / 1000000);
      if (left <= 0 || poll (&pfd, 1, (int) left) <= 0)
        return -1;
      r = read (fd, (char *) buffer + got, n - got);
      if (r <= 0)
        {
          if (r < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
          return -1;
        }
      got += (size_t) r;
    }
  return 0;
}

static int64_t
SNDeadline (int ms)
{
  struct timespec now;

  clock_gettime (CLOCK_MONOTONIC, &now);
  return (int64_t) now.tv_sec * 1000 + now.tv_nsec / 1000000 + ms;
}

/* In a child: keep only `fd` (moved to 3), with stdio on /dev/null, so
   a child left stuck holds none of the parent's descriptors (its
   WindowServer connection, a pipe someone waits on) after the parent
   has gone. Returns the new fd. */
static int
SNChildOnly (int fd)
{
  int null;

  if (fd != 3 && dup2 (fd, 3) < 0)
    _exit (1);
  closefrom (4);
  if ((null = open ("/dev/null", O_RDWR)) >= 0)
    {
      dup2 (null, 0);
      dup2 (null, 1);
      dup2 (null, 2);
      if (null > 3)
        close (null);
    }
  return 3;
}

/* work(arg) in a child process, SNTimeoutMS at most; arg (size bytes)
   comes back changed when it answered in time. */
static int
SNTimed (const char *key, int (*work) (void *), void *arg, size_t size)
{
  int fds[2], result = -1, error = 0, status;
  pid_t pid;

  if (SNIsStuck (key))
    {
      errno = EBUSY;
      return -1;
    }
  if (pipe2 (fds, O_CLOEXEC) != 0)
    return -1;
  pid = fork ();
  if (pid < 0)
    {
      error = errno;
      close (fds[0]);
      close (fds[1]);
      errno = error;
      return -1;
    }
  if (pid == 0)
    {
      int out = SNChildOnly (fds[1]);

      result = work (arg);
      error = errno;
      (void) write (out, &result, sizeof (result));
      (void) write (out, &error, sizeof (error));
      (void) write (out, arg, size);
      _exit (0);
    }
  close (fds[1]);
  if (SNReadFully (fds[0], &result, sizeof (result),
                   SNDeadline (SNTimeoutMS)) != 0
      || SNReadFully (fds[0], &error, sizeof (error), SNDeadline (50)) != 0
      || SNReadFully (fds[0], arg, size, SNDeadline (50)) != 0)
    {
      close (fds[0]);
      if (waitpid (pid, &status, WNOHANG) == 0)
        SNLeaveStuck (key, pid);
      errno = ETIMEDOUT;
      return -1;
    }
  close (fds[0]);
  /* It _exit()s right after writing. */
  while (waitpid (pid, &status, 0) < 0 && errno == EINTR)
    ;
  errno = error;
  return result;
}

/* ---- virtual_oss ---- */

struct SNChannelsCall
{
  char ctl[64];
  void (*change) (struct virtual_oss_io_info *, int);
  int arg;
  struct virtual_oss_io_info first;
};

static int
SNEachChannelWork (void *p)
{
  struct SNChannelsCall *c = p;
  struct virtual_oss_io_info info;
  int fd, number, channel, seen = 0;

  if ((fd = open (c->ctl, O_RDWR | O_CLOEXEC)) < 0)
    return -1;
  for (number = 0; number < 64; number++)
    {
      for (channel = 0; channel < 64; channel++)
        {
          memset (&info, 0, sizeof (info));
          info.number = number;
          info.channel = channel;
          if (ioctl (fd, VIRTUAL_OSS_GET_DEV_INFO, &info) != 0)
            break;
          if (c->change == NULL)
            {
              c->first = info;
              close (fd);
              return 0;
            }
          c->change (&info, c->arg);
          if (ioctl (fd, VIRTUAL_OSS_SET_DEV_INFO, &info) != 0)
            {
              close (fd);
              return -1;
            }
          seen++;
        }
      if (channel == 0)
        break;			/* no such device: the last was the end */
    }
  close (fd);
  if (seen == 0)
    {
      errno = ENODEV;
      return -1;
    }
  return 0;
}

/* Every channel of every device of a virtual_oss (a headset's has
   dsp.btN and maybe dsp): apply `change` to each, or with change NULL,
   read the first into *first. */
static int
SNEachChannel (const SNAudioDevice *d,
               void (*change) (struct virtual_oss_io_info *, int),
               int arg, struct virtual_oss_io_info *first)
{
  struct SNChannelsCall c;

  if (d->ctl[0] == '\0')
    {
      errno = ENODEV;
      return -1;
    }
  memset (&c, 0, sizeof (c));
  strlcpy (c.ctl, d->ctl, sizeof (c.ctl));
  c.change = change;
  c.arg = arg;
  if (SNTimed (d->ctl, SNEachChannelWork, &c, sizeof (c)) != 0)
    return -1;
  if (first != NULL)
    *first = c.first;
  return 0;
}

static void
SNSetTxMute (struct virtual_oss_io_info *info, int muted)
{
  info->tx_mute = muted;
}

static void
SNSetTxAmp (struct virtual_oss_io_info *info, int shift)
{
  info->tx_amp = shift;
}

static void
SNSetRxAmp (struct virtual_oss_io_info *info, int shift)
{
  info->rx_amp = shift;
}

/* virtual_oss's gain is a power of two (a shift, -31..31): 6 dB steps.
   0-100 spreads eight of them evenly, as a volume slider's dB scale
   does: 100 is 0 dB, each 12.5 below it 6 dB less, down to -42 dB at
   12.5, and 0 is silence. */
#define SNShiftLevels 8
#define SNSilentShift (-31)

static int
SNVolumeForShift (int shift)
{
  if (shift >= 0)
    return 100;
  if (shift <= -SNShiftLevels)
    return 0;
  return (int) lrint (100.0 + shift * 100.0 / SNShiftLevels);
}

/* The shift for `volume`, moving from `current` in the direction asked
   by at least one step, so a 5% scroll still gets somewhere. */
static int
SNShiftForVolume (int volume, int current)
{
  int shift, now = SNVolumeForShift (current);

  if (volume <= 0)
    return SNSilentShift;
  if (volume >= 100)
    return 0;
  shift = (int) lrint ((volume - 100) * SNShiftLevels / 100.0);
  if (volume > now && shift <= current)
    shift = current + 1;
  else if (volume < now && shift >= current)
    shift = current - 1;
  if (shift >= 0)
    return 0;
  return shift <= -SNShiftLevels ? SNSilentShift : shift;
}

/* ---- outputs ---- */

int
SNAudioOutputHasVolume (const SNAudioDevice *d)
{
  return d->play && (d->kind == SNAudioKernel || d->absoluteVolume >= 0
                     || d->ctl[0] != '\0');
}

int
SNAudioOutputVolumeIsCoarse (const SNAudioDevice *d)
{
  return d->kind != SNAudioKernel && d->absoluteVolume < 0;
}

int
SNAudioGetOutputVolume (SNAudio *a, const SNAudioDevice *d, int *volume,
                        int *muted)
{
  struct virtual_oss_io_info info;

  *volume = 0;
  *muted = 0;
  if (d->kind == SNAudioKernel)
    return SNMixerGet (d, 1, volume, muted);
  if (SNEachChannel (d, NULL, 0, &info) != 0)
    return -1;
  *muted = info.tx_mute != 0;
  *volume = d->absoluteVolume >= 0
    ? (int) lrint (d->absoluteVolume * 100.0 / 127.0)
    : SNVolumeForShift (info.tx_amp);
  return 0;
}

int
SNAudioSetOutputVolume (SNAudio *a, SNAudioDevice *d, int volume)
{
  struct virtual_oss_io_info info;
  BTAddressString address;
  bt_status_t st;
  int absolute;

  volume = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
  if (d->kind == SNAudioKernel)
    return SNMixerSet (d, 1, volume);
  if (d->absoluteVolume >= 0)
    {
      /* The headset's own volume, as macOS sets it. */
      absolute = (int) lrint (volume * 127.0 / 100.0);
      if (absolute == d->absoluteVolume)
        return 0;
      memset (address, 0, sizeof (address));
      strlcpy (address, d->address, sizeof (address));
      errno = ENOTCONN;
      SNCall (a, bt_audio_volume (svc, address, absolute, &st), -1);
      if (st == bt_status_success_e)
        {
          d->absoluteVolume = absolute;
          return 0;
        }
      if (st != bt_status_operation_not_supported_e)
        {
          errno = ENOTCONN;
          return -1;
        }
      /* It has no absolute volume after all: virtual_oss's gain. */
      d->absoluteVolume = -1;
    }
  if (SNEachChannel (d, NULL, 0, &info) != 0)
    return -1;
  return SNEachChannel (d, SNSetTxAmp,
                        SNShiftForVolume (volume, info.tx_amp), NULL);
}

int
SNAudioSetOutputMuted (SNAudio *a, const SNAudioDevice *d, int muted)
{
  if (d->kind == SNAudioKernel)
    return SNMixerSetMuted (d, muted);
  return SNEachChannel (d, SNSetTxMute, muted ? 1 : 0, NULL);
}

/* ---- inputs ---- */

int
SNAudioGetInputVolume (SNAudio *a, const SNAudioDevice *d, int *volume)
{
  struct virtual_oss_io_info info;

  *volume = 0;
  if (d->kind == SNAudioKernel)
    return SNMixerGet (d, 0, volume, NULL);
  if (d->kind == SNAudioVirtual && SNEachChannel (d, NULL, 0, &info) == 0)
    {
      *volume = SNVolumeForShift (info.rx_amp);
      return 0;
    }
  errno = ENODEV;
  return -1;
}

int
SNAudioSetInputVolume (SNAudio *a, const SNAudioDevice *d, int volume)
{
  if (d->kind == SNAudioKernel)
    return SNMixerSet (d, 0, volume);
  if (d->kind == SNAudioVirtual)
    {
      struct virtual_oss_io_info info;

      if (SNEachChannel (d, NULL, 0, &info) != 0)
        return -1;
      return SNEachChannel (d, SNSetRxAmp,
                            SNShiftForVolume (volume, info.rx_amp), NULL);
    }
  errno = ENODEV;
  return -1;
}

int
SNAudioSetMicrophone (SNAudio *a, const SNAudioDevice *d, int on)
{
  BTAddressString address;
  bt_status_t st;

  if (d->kind != SNAudioBluetooth)
    {
      errno = ENODEV;
      return -1;
    }
  memset (address, 0, sizeof (address));
  strlcpy (address, d->address, sizeof (address));
  errno = ENOTCONN;
  SNCall (a, bt_audio_route (svc, address, on ? SNRouteHandsFree : 1, &st),
          -1);
  if (st != bt_status_success_e)
    {
      errno = ENOTCONN;
      return -1;
    }
  return 0;
}

/* ---- the input meter ---- */

/* A virtual_oss's meter is a child process (see SNTimed for why) that
   reads the input peak SNMeterHz times a second and writes each level
   down a pipe; the meter takes what has come when it's drawn. */
#define SNMeterHz 20

/* The child: virtual_oss's peak of what it read in, cleared by
   reading. Ends when the meter closes the pipe, or is killed. */
static void
SNMeterChild (const char *ctl, int out)
{
  struct virtual_oss_system_info info;
  struct virtual_oss_master_peak peak;
  long long top, full;
  float level;
  int fd, channel, channels;

  if ((fd = open (ctl, O_RDWR)) < 0)
    _exit (1);
  if (ioctl (fd, VIRTUAL_OSS_GET_SYSTEM_INFO, &info) != 0)
    info.sample_channels = 2;
  channels = info.sample_channels > 0 && info.sample_channels <= 64
    ? (int) info.sample_channels : 2;
  for (;;)
    {
      top = 0;
      full = 0;
      for (channel = 0; channel < channels; channel++)
        {
          memset (&peak, 0, sizeof (peak));
          peak.channel = channel;
          if (ioctl (fd, VIRTUAL_OSS_GET_INPUT_PEAK, &peak) != 0)
            break;
          if (peak.bits > 1 && peak.bits <= 32)
            full = (1LL << (peak.bits - 1)) - 1;
          if (peak.peak_value > top)
            top = peak.peak_value;
        }
      level = full <= 0 ? 0.0f
        : (top >= full ? 1.0f : (float) top / (float) full);
      if (write (out, &level, sizeof (level)) != sizeof (level))
        _exit (0);
      usleep (1000000 / SNMeterHz);
    }
}

SNAudioMeter *
SNAudioMeterOpen (const SNAudioDevice *d)
{
  SNAudioMeter *m;
  int fd, format = AFMT_S16_NE, channels = 2, rate = 48000;
  int fds[2];
  pid_t pid = 0;

  if (!d->record)
    return NULL;
  if (d->kind == SNAudioKernel)
    {
      /* Record from it, as macOS's meter does while it's shown. A
         kernel device answers at once. */
      if ((fd = open (d->dsp, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0)
        return NULL;
      if (ioctl (fd, SNDCTL_DSP_SETFMT, &format) != 0
          || format != AFMT_S16_NE
          || ioctl (fd, SNDCTL_DSP_CHANNELS, &channels) != 0
          || ioctl (fd, SNDCTL_DSP_SPEED, &rate) != 0)
        {
          close (fd);
          return NULL;
        }
    }
  else
    {
      if (d->ctl[0] == '\0' || SNIsStuck (d->ctl)
          || pipe2 (fds, O_CLOEXEC) != 0)
        return NULL;
      if ((pid = fork ()) < 0)
        {
          close (fds[0]);
          close (fds[1]);
          return NULL;
        }
      if (pid == 0)
        {
          SNMeterChild (d->ctl, SNChildOnly (fds[1]));
          _exit (0);
        }
      close (fds[1]);
      fd = fds[0];
      (void) fcntl (fd, F_SETFL, fcntl (fd, F_GETFL) | O_NONBLOCK);
    }
  if ((m = calloc (1, sizeof (*m))) == NULL)
    {
      close (fd);
      if (pid > 0)
        kill (pid, SIGKILL);
      return NULL;
    }
  m->fd = fd;
  m->kind = d->kind;
  m->pid = pid;
  strlcpy (m->ctl, d->ctl, sizeof (m->ctl));
  return m;
}

float
SNAudioMeterLevel (SNAudioMeter *m)
{
  int16_t samples[4096];
  float levels[64], level = 0.0f;
  long long top = 0;
  ssize_t n, i;

  if (m == NULL)
    return 0.0f;
  if (m->kind != SNAudioKernel)
    {
      /* The loudest of what the child sent since the last look. */
      while ((n = read (m->fd, levels, sizeof (levels))) > 0)
        for (i = 0; i < n / (ssize_t) sizeof (levels[0]); i++)
          if (levels[i] > level)
            level = levels[i];
      return level;
    }
  /* Everything recorded since the last read. */
  while ((n = read (m->fd, samples, sizeof (samples))) > 0)
    for (i = 0; i < n / (ssize_t) sizeof (samples[0]); i++)
      {
        long long v = samples[i] < 0 ? -(long long) samples[i] : samples[i];
        if (v > top)
          top = v;
      }
  return top >= INT16_MAX ? 1.0f : (float) top / (float) INT16_MAX;
}

void
SNAudioMeterClose (SNAudioMeter *m)
{
  int status;

  if (m == NULL)
    return;
  close (m->fd);
  if (m->pid > 0)
    {
      /* A child stuck in the virtual_oss dies when it answers. */
      kill (m->pid, SIGKILL);
      if (waitpid (m->pid, &status, WNOHANG) == 0)
        SNLeaveStuck (m->ctl, m->pid);
    }
  free (m);
}
