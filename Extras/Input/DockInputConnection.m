/*
 * DockWM
 *
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
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

#import "DockInputConnection.h"
#import <AppKit/NSApplication.h>
#import <GNUstepBase/GNUstep.h>

#include <errno.h>
#include <stdint.h>
#include <string.h>

#include <WindowServer/WSClient.h>

#define CONN ((ws_connection_t *)_conn)

/* Seconds between attempts to reach WindowServer. */
#define DockInputRetryInterval 3.0

static NSArray *
DockInputWatchedModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

static NSString *
DockInputString(const char *chars, size_t size)
{
  NSString *s = AUTORELEASE([[NSString alloc]
			      initWithBytes:chars
				     length:strnlen(chars, size)
				   encoding:NSUTF8StringEncoding]);
  return s != nil ? s : @"";
}

@interface DockInputConnection (Private)
- (BOOL) connect;
- (void) disconnect;
- (void) retry: (NSTimer *)timer;
- (void) startRetrying;
- (void) processEvents;
- (void) processEventsLater;
- (void) handleEvent: (const ws_event_t *)event;
- (void) checkLost: (int)error;
- (void) notifyDelegate;
@end

static void
DockInputHandleEvent(ws_connection_t *conn, const ws_event_t *event, void *ctx)
{
  (void)conn;
  [(DockInputConnection *)ctx handleEvent:event];
}

struct DockInputLayoutsContext
{
  NSMutableArray *list;
  int active;
};

static void
DockInputCollectLayout(const ws_event_keyboard_layout_t *layout, void *ctx)
{
  struct DockInputLayoutsContext *c = ctx;

  [c->list addObject:
     [NSDictionary dictionaryWithObjectsAndKeys:
	DockInputString(layout->layout, sizeof(layout->layout)), @"Layout",
	DockInputString(layout->variant, sizeof(layout->variant)), @"Variant",
	DockInputString(layout->name, sizeof(layout->name)), @"Name",
	nil]];
  if (layout->flags & WS_KEYBOARD_LAYOUT_ACTIVE)
    {
      c->active = (int)layout->index;
    }
}

@implementation DockInputConnection

- (id) initWithName: (NSString *)name
	   delegate: (id <DockInputConnectionDelegate>)delegate
{
  if ((self = [super init]) == nil)
    {
      return nil;
    }
  ASSIGN(_name, name);
  /* The delegate hears about this first connection only when it comes
   * later, through the retries. */
  if (![self connect])
    {
      [self startRetrying];
    }
  _delegate = delegate;
  return self;
}

- (void) dealloc
{
  [self invalidate];
  RELEASE(_name);
  [super dealloc];
}

- (void) invalidate
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [_retryTimer invalidate];
  DESTROY(_retryTimer);
  [self disconnect];
  _delegate = nil;
}

- (BOOL) isConnected
{
  return _conn != NULL;
}

- (NSArray *) layoutsWithActiveIndex: (int *)activeIndex
{
  struct DockInputLayoutsContext c;

  c.list = [NSMutableArray array];
  c.active = -1;
  if (_conn != NULL
      && ws_list_keyboard_layouts(CONN, DockInputCollectLayout, &c) < 0)
    {
      int e = errno;

      NSLog(@"%@: can't list the keyboard layouts: %s", _name, strerror(e));
      [self checkLost:e];
      [c.list removeAllObjects];
      c.active = -1;
    }
  if (_conn != NULL)
    {
      [self processEventsLater];
    }
  if (activeIndex != NULL)
    {
      *activeIndex = c.active;
    }
  return c.list;
}

- (int) setActiveLayout: (unsigned)index
{
  if (_conn == NULL)
    {
      return ENOTCONN;
    }
  if (ws_set_keyboard_layout(CONN, index) < 0)
    {
      int e = errno;

      NSLog(@"%@: WindowServer refused layout %u: %s", _name, index,
	    strerror(e));
      [self checkLost:e];
      return e;
    }
  [self processEventsLater];
  return 0;
}

@end

@implementation DockInputConnection (Private)

- (BOOL) connect
{
  ws_connection_t *conn = ws_connect([_name UTF8String], WS_CONNECT_CONTROL);
  NSRunLoop *loop = [NSRunLoop currentRunLoop];
  NSArray *modes = DockInputWatchedModes();
  NSUInteger i;

  if (conn == NULL)
    {
      return NO;
    }
  _conn = conn;
  for (i = 0; i < [modes count]; i++)
    {
      [loop addEvent:(void *)(intptr_t)ws_connection_fd(conn)
		type:ET_RDESC
	     watcher:(id <RunLoopEvents>)self
	     forMode:[modes objectAtIndex:i]];
    }
  [_delegate connectionDidChange:self];
  return YES;
}

- (void) disconnect
{
  NSRunLoop *loop = [NSRunLoop currentRunLoop];
  NSArray *modes = DockInputWatchedModes();
  NSUInteger i;

  if (_conn == NULL)
    {
      return;
    }
  for (i = 0; i < [modes count]; i++)
    {
      [loop removeEvent:(void *)(intptr_t)ws_connection_fd(CONN)
		   type:ET_RDESC
		forMode:[modes objectAtIndex:i]
		    all:YES];
    }
  ws_disconnect(CONN);
  _conn = NULL;
}

- (void) startRetrying
{
  if (_retryTimer != nil)
    {
      return;
    }
  ASSIGN(_retryTimer,
	 [NSTimer scheduledTimerWithTimeInterval:DockInputRetryInterval
					  target:self
					selector:@selector(retry:)
					userInfo:nil
					 repeats:YES]);
}

- (void) retry: (NSTimer *)timer
{
  if ([self connect])
    {
      [_retryTimer invalidate];
      DESTROY(_retryTimer);
    }
}

/* After a failed request: if it was the connection that failed, start
 * over, and tell the delegate from the run loop. */
- (void) checkLost: (int)error
{
  if (error == EPIPE || error == ECONNRESET || error == ENOTCONN)
    {
      [self disconnect];
      [self startRetrying];
      [self performSelector:@selector(notifyDelegate) withObject:nil
		 afterDelay:0];
    }
}

- (void) notifyDelegate
{
  [_delegate connectionDidChange:self];
}

- (void) receivedEvent: (void *)data
		  type: (RunLoopEventType)type
		 extra: (void *)extra
	       forMode: (NSString *)mode
{
  [self processEvents];
}

/* Events read while waiting for an answer are queued in the library:
 * handle them from the run loop. */
- (void) processEventsLater
{
  if (_conn != NULL && ws_pending(CONN))
    {
      [self performSelector:@selector(processEvents) withObject:nil
		 afterDelay:0];
    }
}

- (void) processEvents
{
  if (_conn == NULL)
    {
      return;
    }
  _changed = NO;
  _layoutChanged = NO;
  if (ws_dispatch(CONN, DockInputHandleEvent, self) < 0)
    {
      NSLog(@"%@: lost the WindowServer connection (%s)", _name,
	    strerror(errno));
      [self disconnect];
      [self startRetrying];
      [_delegate connectionDidChange:self];
      return;
    }
  if (_changed)
    {
      _changed = NO;
      _layoutChanged = NO;
      [_delegate connectionDidChange:self];
    }
  else if (_layoutChanged)
    {
      _layoutChanged = NO;
      [_delegate connectionLayoutDidChange:self];
    }
}

- (void) handleEvent: (const ws_event_t *)event
{
  switch (event->hdr.type)
    {
    case WS_EVENT_SETTINGS_CHANGED:
      _changed = YES;
      break;
    case WS_EVENT_KEYBOARD_LAYOUT:
      if (event->u.keyboard_layout.flags & WS_KEYBOARD_LAYOUT_CHANGED)
	{
	  _layoutChanged = YES;
	}
      break;
    default:
      break;
    }
}

@end
