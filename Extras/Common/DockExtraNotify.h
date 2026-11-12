/*
 * DockWM
 *
 * Copyright (C) 2026 Gregory Casamento <greg.casamento@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * notify(3), for the Dock extras.
 *
 * Notifications are delivered on a private dispatch queue, which writes
 * a byte to a pipe; the extra watches the pipe's other end with
 * NSFileHandle, so they arrive on the Dock's run loop and nothing is
 * polled. (notify_register_file_descriptor would be simpler, but it
 * fails on NextBSD today.)
 *
 * NextBSD's <notify.h> needs <os/base.h>, which isn't installed, and the
 * extras are built against GNUstep's headers, so the few calls they make
 * are declared here. They link with -lnotify and -lsystem_dispatch from
 * /usr/lib/system (GNUstep's Foundation already uses that libdispatch).
 */

#ifndef _DOCKEXTRA_NOTIFY_H_
#define _DOCKEXTRA_NOTIFY_H_

#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dispatch/dispatch.h>

#define DockExtraNotifyStatusOK 0

typedef dispatch_queue_t DockExtraQueue;

extern uint32_t notify_register_dispatch(const char *name, int *out_token,
					 DockExtraQueue queue,
					 void (^handler)(int token));
extern uint32_t notify_cancel(int token);

/* The queue every notification of this extra arrives on. */
static inline DockExtraQueue
DockExtraNotifyQueue(void)
{
  static DockExtraQueue queue = NULL;

  if (queue == NULL)
    {
      queue = dispatch_queue_create("org.nextbsd.dockextra.notify", NULL);
    }
  return queue;
}

/* A pipe for notifications: fds[0] to watch, fds[1] to wake it. */
static inline int
DockExtraNotifyPipe(int fds[2])
{
  if (pipe(fds) != 0)
    {
      fds[0] = fds[1] = -1;
      return -1;
    }
  (void)fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
  (void)fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
  (void)fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  (void)fcntl(fds[1], F_SETFD, FD_CLOEXEC);
  return 0;
}

/* Register name: each post writes a byte to wakeFD. Returns the token,
 * or -1. */
static inline int
DockExtraNotifyRegister(const char *name, int wakeFD)
{
  int token = -1;

  if (wakeFD < 0 ||
      notify_register_dispatch(name, &token, DockExtraNotifyQueue(),
			       ^(int t) {
				 char byte = 1;

				 (void)write(wakeFD, &byte, 1);
			       }) != DockExtraNotifyStatusOK)
    {
      return -1;
    }
  return token;
}

/* Cancel a registration, and wait out a handler already running, so the
 * pipe can be closed after. */
static inline void
DockExtraNotifyCancel(int token)
{
  if (token >= 0)
    {
      notify_cancel(token);
      dispatch_sync(DockExtraNotifyQueue(), ^{});
    }
}

/* Empty the pipe after it became readable. */
static inline void
DockExtraNotifyDrain(int fd)
{
  char buffer[256];

  while (read(fd, buffer, sizeof(buffer)) > 0)
    {
    }
}

#endif
