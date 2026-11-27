/*
 * Dock
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

#import "DockStartMenu.h"
#import <GNUstepBase/GNUstep.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>

#define StartWidth 640.0
#define StartHeight 592.0
#define StartPad 28.0
#define StartColumns 6
#define StartCellHeight 86.0
#define StartRowHeight 40.0
#define StartBarHeight 62.0

/* loginwindow's control socket (apps-loginwindow, LWAppDelegate.m). */
#define StartControlSocket "/var/run/loginwindow/control"

static NSString *const StartPinnedKey = @"StartPinnedApplications";

static BOOL
StartIsLight(void)
{
  NSDictionary *global = [[NSUserDefaults standardUserDefaults]
			   persistentDomainForName:NSGlobalDomain];
  return [[global objectForKey:@"NBAppearance"] isEqual:@"light"];
}

static NSColor *
StartColor(unsigned dark, unsigned light)
{
  unsigned v = StartIsLight() ? light : dark;
  return [NSColor colorWithCalibratedRed:((v >> 16) & 255) / 255.0
				   green:((v >> 8) & 255) / 255.0
				    blue:(v & 255) / 255.0
				   alpha:1.0];
}

/* The settings apps, which search calls settings. */
static NSSet *
StartSettingsNames(void)
{
  static NSSet *names;
  if (names == nil)
    names = [[NSSet alloc] initWithObjects:@"Bluetooth", @"Date & Time",
	@"Displays", @"Energy", @"Keyboard", @"Language & Region", @"Mouse",
	@"Network", @"Printers", @"Sound", @"Trackpad", @"Users & Login",
	@"Webcam", nil];
  return names;
}

/* Asks loginwindow for "logout", "restart" or "shutdown"; YES if it said ok. */
static BOOL
StartAskLoginWindow(const char *what)
{
  struct sockaddr_un sun;
  char answer[16] = "";
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  BOOL ok = NO;

  if (s < 0)
    return NO;
  memset(&sun, 0, sizeof(sun));
  sun.sun_family = AF_UNIX;
  strlcpy(sun.sun_path, StartControlSocket, sizeof(sun.sun_path));
  if (connect(s, (struct sockaddr *)&sun, sizeof(sun)) == 0)
    {
      char line[32];
      snprintf(line, sizeof(line), "%s\n", what);
      if (write(s, line, strlen(line)) > 0
	  && read(s, answer, sizeof(answer) - 1) > 0)
	ok = strncmp(answer, "ok", 2) == 0;
    }
  close(s);
  return ok;
}

@interface DockStartView : NSView
{
  DockStartMenu *_owner;
  NSMutableArray *_items;	/* {kind, path, title, rect} */
  NSInteger _hover;
  CGFloat _scroll;
}
- (id) initWithFrame: (NSRect)frame menu: (DockStartMenu *)menu;
- (void) reload;
@end

@interface DockStartMenu (Private)
- (NSArray *) applications;
- (NSArray *) pinnedApplications;
- (NSArray *) recentFiles;
- (NSString *) query;
- (BOOL) showsAllApps;
- (void) setShowsAllApps: (BOOL)flag;
- (void) openItem: (NSDictionary *)item;
- (void) showPowerMenu: (NSRect)rect inView: (NSView *)view;
@end

@implementation DockStartMenu

- (id) initWithTarget: (id)target fileViewerAction: (SEL)action
{
  NSRect frame = NSMakeRect(0, 0, StartWidth, StartHeight);

  self = [super initWithContentRect:frame
			  styleMask:NSBorderlessWindowMask
			    backing:NSBackingStoreBuffered
			      defer:YES];
  if (self == nil)
    return nil;
  _target = target;
  _openFileViewer = action;
  /* Above the taskbar, but not a menu's level: those never become key
     (libs-back), and the search field needs the keys. */
  [self setLevel:NSModalPanelWindowLevel];
  [self setOpaque:NO];
  [self setBackgroundColor:[NSColor clearColor]];
  [self setHasShadow:YES];
  [self setReleasedWhenClosed:NO];
  [self setHidesOnDeactivate:NO];
  [self setAcceptsMouseMovedEvents:YES];
  [self setExcludedFromWindowsMenu:YES];

  _content = [[DockStartView alloc] initWithFrame:frame menu:self];
  [self setContentView:_content];
  RELEASE(_content);

  _search = [[NSTextField alloc]
	      initWithFrame:NSMakeRect(StartPad + 34, 27,
				       StartWidth - 2 * StartPad - 48, 26)];
  [_search setBordered:NO];
  [_search setBezeled:NO];
  [_search setDrawsBackground:YES];
  [_search setFocusRingType:NSFocusRingTypeNone];
  [_search setFont:[NSFont systemFontOfSize:14]];
  [[_search cell] setPlaceholderString:@"Search apps, files and settings"];
  [_search setDelegate:(id)self];
  [_search setTarget:self];
  [_search setAction:@selector(searchReturn:)];
  [_content addSubview:_search];
  RELEASE(_search);

  [[NSNotificationCenter defaultCenter]
      addObserver:self
	 selector:@selector(windowDidResignKey:)
	     name:NSWindowDidResignKeyNotification
	   object:self];
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  DEALLOC;
}

- (BOOL) canBecomeKeyWindow
{
  return YES;
}

- (BOOL) canBecomeMainWindow
{
  return NO;
}

/* Above the taskbar, centred: the screen's visible frame leaves the Dock
   out. */
- (void) toggle
{
  NSRect visible, frame;

  if ([self isVisible])
    {
      [self close];
      return;
    }
  visible = [[NSScreen mainScreen] visibleFrame];
  frame = NSMakeRect(floor(NSMidX(visible) - StartWidth / 2),
		     NSMinY(visible) + 12, StartWidth, StartHeight);
  [self setFrame:frame display:NO];
  [_search setStringValue:@""];
  [_search setTextColor:StartColor(0xeef0f4, 0x1d1f24)];
  [_search setBackgroundColor:StartColor(0x15171c, 0xffffff)];
  _allApps = NO;
  [(DockStartView *)_content reload];
  [NSApp activateIgnoringOtherApps:YES];
  [self makeKeyAndOrderFront:nil];
  [self makeFirstResponder:_search];
}

- (void) close
{
  [self orderOut:nil];
}

- (void) windowDidResignKey: (NSNotification *)note
{
  if ([self isVisible])
    [self close];
}

- (void) cancelOperation: (id)sender
{
  [self close];
}

/* GNUstep's field editor sends Escape as complete:. */
- (BOOL) control: (NSControl *)control textView: (NSTextView *)view
  doCommandBySelector: (SEL)command
{
  if (sel_isEqual(command, @selector(cancelOperation:))
      || sel_isEqual(command, @selector(complete:)))
    {
      [self close];
      return YES;
    }
  return NO;
}

- (void) controlTextDidChange: (NSNotification *)note
{
  [(DockStartView *)_content reload];
}

/* Return opens the first result. */
- (void) searchReturn: (id)sender
{
  [(DockStartView *)_content performSelector:@selector(openFirst)];
}

- (NSString *) query
{
  return [[_search stringValue] stringByTrimmingCharactersInSet:
	    [NSCharacterSet whitespaceCharacterSet]];
}

- (BOOL) showsAllApps
{
  return _allApps;
}

- (void) setShowsAllApps: (BOOL)flag
{
  _allApps = flag;
  [(DockStartView *)_content reload];
}

/* Every app, by name: /System/Applications, /Local/Applications and
   ~/Applications, each once (links to an app count as the app). */
- (NSArray *) applications
{
  NSArray *folders = [NSArray arrayWithObjects:@"/System/Applications",
      @"/Local/Applications",
      [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], nil];
  NSMutableDictionary *found = [NSMutableDictionary dictionary];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSUInteger i, j;

  for (i = 0; i < [folders count]; i++)
    {
      NSString *folder = [folders objectAtIndex:i];
      NSArray *names = [fm directoryContentsAtPath:folder];
      for (j = 0; j < [names count]; j++)
	{
	  NSString *name = [names objectAtIndex:j];
	  NSString *path, *real;
	  if (![[name pathExtension] isEqual:@"app"])
	    continue;
	  path = [folder stringByAppendingPathComponent:name];
	  real = [path stringByResolvingSymlinksInPath];
	  if ([found objectForKey:real] == nil)
	    [found setObject:[NSDictionary dictionaryWithObjectsAndKeys:
		@"app", @"kind", real, @"path",
		[name stringByDeletingPathExtension], @"title", nil]
		      forKey:real];
	}
    }
  return [[found allValues] sortedArrayUsingDescriptors:
      [NSArray arrayWithObject:AUTORELEASE([[NSSortDescriptor alloc]
	  initWithKey:@"title" ascending:YES
	     selector:@selector(localizedCaseInsensitiveCompare:)])]];
}

/* The pinned apps: the user's, else NextBSD's own, if installed. File
   Viewer comes first: it opens a File Viewer, as the cube does elsewhere. */
- (NSArray *) pinnedApplications
{
  NSArray *paths = [[NSUserDefaults standardUserDefaults]
		     arrayForKey:StartPinnedKey];
  NSMutableArray *pinned = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSUInteger i;

  if (paths == nil)
    {
      NSArray *names = [NSArray arrayWithObjects:@"Terminal", @"TextEdit",
	  @"Software", @"Update", @"Displays", @"Network", @"Sound",
	  @"Bluetooth", @"Keyboard", @"Mouse", @"Trackpad", @"Energy",
	  @"Date & Time", @"Printers", @"Users & Login", @"Webcam",
	  @"Installer", nil];
      NSMutableArray *defaults = [NSMutableArray array];
      for (i = 0; i < [names count]; i++)
	[defaults addObject:[NSString stringWithFormat:
	    @"/System/Applications/%@.app", [names objectAtIndex:i]]];
      paths = defaults;
    }
  [pinned addObject:[NSDictionary dictionaryWithObjectsAndKeys:
      @"fileviewer", @"kind", @"File Viewer", @"title", nil]];
  for (i = 0; i < [paths count] && [pinned count] < 3 * StartColumns; i++)
    {
      NSString *path = [paths objectAtIndex:i];
      if ([path isKindOfClass:[NSString class]] && [fm fileExistsAtPath:path])
	[pinned addObject:[NSDictionary dictionaryWithObjectsAndKeys:
	    @"app", @"kind", path, @"path",
	    [[path lastPathComponent] stringByDeletingPathExtension], @"title",
	    nil]];
    }
  return pinned;
}

/* Workspace's recent files (org.nextbsd.Workspace RecentFiles), newest
   first, those still there. */
- (NSArray *) recentFiles
{
  NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
			   persistentDomainForName:@"org.nextbsd.Workspace"];
  NSArray *records = [domain objectForKey:@"RecentFiles"];
  NSMutableArray *files = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSUInteger i;

  if (![records isKindOfClass:[NSArray class]])
    return files;
  for (i = 0; i < [records count] && [files count] < 4; i++)
    {
      NSDictionary *record = [records objectAtIndex:i];
      NSString *path;
      NSDate *date;
      if (![record isKindOfClass:[NSDictionary class]])
	continue;
      path = [record objectForKey:@"path"];
      date = [record objectForKey:@"accessed"];
      if (![path isKindOfClass:[NSString class]] || ![fm fileExistsAtPath:path])
	continue;
      [files addObject:[NSDictionary dictionaryWithObjectsAndKeys:
	  @"file", @"kind", path, @"path", [path lastPathComponent], @"title",
	  [date isKindOfClass:[NSDate class]] ? (id)date : (id)[NSNull null],
	  @"date", nil]];
    }
  return files;
}

- (void) openItem: (NSDictionary *)item
{
  NSString *kind = [item objectForKey:@"kind"];
  NSString *path = [item objectForKey:@"path"];

  if ([kind isEqual:@"allapps"])
    {
      [self setShowsAllApps:![self showsAllApps]];
      return;
    }
  if ([kind isEqual:@"power"])
    return;
  [self close];
  if ([kind isEqual:@"fileviewer"])
    [_target performSelector:_openFileViewer];
  else if ([kind isEqual:@"app"])
    [[NSWorkspace sharedWorkspace] launchApplication:path];
  else if (path != nil)
    [[NSWorkspace sharedWorkspace] openFile:path];
}

- (void) showPowerMenu: (NSRect)rect inView: (NSView *)view
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Power"]);
  NSEvent *event;

  [[menu addItemWithTitle:[NSString stringWithFormat:@"Log Out %@…",
				     NSUserName()]
		   action:@selector(logOut:) keyEquivalent:@""] setTarget:self];
  [[menu addItemWithTitle:@"Restart…" action:@selector(restart:)
	    keyEquivalent:@""] setTarget:self];
  [[menu addItemWithTitle:@"Shut Down…" action:@selector(shutDown:)
	    keyEquivalent:@""] setTarget:self];
  event = [NSEvent mouseEventWithType:NSLeftMouseDown
			     location:[view convertPoint:rect.origin toView:nil]
			modifierFlags:0
			    timestamp:0
			 windowNumber:[self windowNumber]
			      context:nil
			  eventNumber:0
			   clickCount:1
			     pressure:1];
  [NSMenu popUpContextMenu:menu withEvent:event forView:view];
}

/* As a Mac asks: are you sure? Then loginwindow does it. */
- (void) power: (const char *)what title: (NSString *)title
       message: (NSString *)message button: (NSString *)button
{
  [self close];
  if (NSRunAlertPanel(title, @"%@", button, @"Cancel", nil, message)
      != NSAlertDefaultReturn)
    return;
  if (!StartAskLoginWindow(what))
    NSRunAlertPanel(title, @"The login window didn’t answer, so nothing was "
		    @"done.", @"OK", nil, nil);
}

- (void) logOut: (id)sender
{
  [self power:"logout"
	title:[NSString stringWithFormat:@"Log out %@?", NSFullUserName()]
      message:@"Your apps will quit, and any unsaved changes will be lost."
       button:@"Log Out"];
}

- (void) restart: (id)sender
{
  [self power:"restart" title:@"Restart now?"
      message:@"Your apps will quit, and any unsaved changes will be lost."
       button:@"Restart"];
}

- (void) shutDown: (id)sender
{
  [self power:"shutdown" title:@"Shut down now?"
      message:@"Your apps will quit, and any unsaved changes will be lost."
       button:@"Shut Down"];
}

@end

@implementation DockStartView

- (id) initWithFrame: (NSRect)frame menu: (DockStartMenu *)menu
{
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _owner = menu;
      _items = [[NSMutableArray alloc] init];
      _hover = -1;
    }
  return self;
}

- (void) dealloc
{
  RELEASE(_items);
  DEALLOC;
}

- (BOOL) isFlipped
{
  return YES;
}

- (BOOL) acceptsFirstMouse: (NSEvent *)event
{
  return YES;
}

- (void) addItem: (NSDictionary *)item rect: (NSRect)rect
{
  NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:item];
  [entry setObject:[NSValue valueWithRect:rect] forKey:@"rect"];
  [_items addObject:entry];
}

/* What the menu shows now, and where: search results, All apps, or the
   pinned apps and recent files. */
- (void) reload
{
  NSString *query = [_owner query];
  CGFloat top = 78, y;
  NSUInteger i;

  [_items removeAllObjects];
  _hover = -1;
  if ([query length] > 0)
    {
      NSMutableArray *results = [NSMutableArray array];
      NSArray *apps = [_owner applications];
      NSArray *folders = [NSArray arrayWithObjects:@"Desktop", @"Documents",
					       @"Downloads", nil];
      NSFileManager *fm = [NSFileManager defaultManager];
      for (i = 0; i < [apps count]; i++)
	if ([[[apps objectAtIndex:i] objectForKey:@"title"]
		rangeOfString:query options:NSCaseInsensitiveSearch].location
	    != NSNotFound)
	  [results addObject:[apps objectAtIndex:i]];
      for (i = 0; i < [folders count] && [results count] < 10; i++)
	{
	  NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:
						 [folders objectAtIndex:i]];
	  NSArray *names = [fm directoryContentsAtPath:folder];
	  NSUInteger j;
	  for (j = 0; j < [names count] && [results count] < 10; j++)
	    {
	      NSString *name = [names objectAtIndex:j];
	      if ([name hasPrefix:@"."]
		  || [name rangeOfString:query
				 options:NSCaseInsensitiveSearch].location
		     == NSNotFound)
		continue;
	      [results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
		  @"file", @"kind",
		  [folder stringByAppendingPathComponent:name], @"path",
		  name, @"title", [folders objectAtIndex:i], @"where", nil]];
	    }
	}
      y = top;
      for (i = 0; i < [results count] && i < 12; i++, y += StartRowHeight)
	[self addItem:[results objectAtIndex:i]
		 rect:NSMakeRect(StartPad - 8, y, StartWidth - 2 * StartPad + 16,
				 StartRowHeight - 4)];
      if ([results count] > 0)
	_hover = 0;
    }
  else if ([_owner showsAllApps])
    {
      NSArray *apps = [_owner applications];
      [self addItem:[NSDictionary dictionaryWithObjectsAndKeys:
	  @"allapps", @"kind", @"Back", @"title", nil]
	       rect:NSMakeRect(StartWidth - StartPad - 86, top, 86, 24)];
      y = top + 34 - _scroll;
      for (i = 0; i < [apps count]; i++, y += StartRowHeight)
	if (y >= top + 30 && y + StartRowHeight <= StartHeight - StartBarHeight)
	  [self addItem:[apps objectAtIndex:i]
		   rect:NSMakeRect(StartPad - 8, y, StartWidth - 2 * StartPad + 16,
				   StartRowHeight - 4)];
    }
  else
    {
      NSArray *pinned = [_owner pinnedApplications];
      NSArray *recent = [_owner recentFiles];
      CGFloat cell = (StartWidth - 2 * 18) / StartColumns;
      [self addItem:[NSDictionary dictionaryWithObjectsAndKeys:
	  @"allapps", @"kind", @"All apps", @"title", nil]
	       rect:NSMakeRect(StartWidth - StartPad - 86, top, 86, 24)];
      for (i = 0; i < [pinned count]; i++)
	[self addItem:[pinned objectAtIndex:i]
		 rect:NSMakeRect(18 + (i % StartColumns) * cell,
				 top + 30 + (i / StartColumns) * StartCellHeight,
				 cell - 2, StartCellHeight - 4)];
      y = top + 30 + 3 * StartCellHeight + 36;
      for (i = 0; i < [recent count]; i++)
	[self addItem:[recent objectAtIndex:i]
		 rect:NSMakeRect(20 + (i % 2) * (StartWidth - 40) / 2,
				 y + (i / 2) * 48, (StartWidth - 40) / 2 - 10, 44)];
    }
  [self addItem:[NSDictionary dictionaryWithObjectsAndKeys:
      @"power", @"kind", @"Power", @"title", nil]
	   rect:NSMakeRect(StartWidth - StartPad - 36,
			   StartHeight - StartBarHeight + 13, 36, 36)];
  [self setNeedsDisplay:YES];
}

- (NSInteger) itemAtPoint: (NSPoint)p
{
  NSUInteger i;
  for (i = 0; i < [_items count]; i++)
    if (NSPointInRect(p, [[[_items objectAtIndex:i] objectForKey:@"rect"]
			    rectValue]))
      return i;
  return -1;
}

- (void) openFirst
{
  if ([_items count] > 0 && _hover >= 0)
    [_owner openItem:[_items objectAtIndex:_hover]];
}

- (void) mouseMoved: (NSEvent *)event
{
  NSInteger i = [self itemAtPoint:[self convertPoint:[event locationInWindow]
					     fromView:nil]];
  if (i != _hover && ([[_owner query] length] == 0 || i >= 0))
    {
      _hover = i;
      [self setNeedsDisplay:YES];
    }
}

- (void) mouseUp: (NSEvent *)event
{
  NSInteger i = [self itemAtPoint:[self convertPoint:[event locationInWindow]
					     fromView:nil]];
  NSDictionary *item;

  if (i < 0)
    return;
  item = [_items objectAtIndex:i];
  if ([[item objectForKey:@"kind"] isEqual:@"power"])
    [_owner showPowerMenu:[[item objectForKey:@"rect"] rectValue] inView:self];
  else
    [_owner openItem:item];
}

- (void) scrollWheel: (NSEvent *)event
{
  if (![_owner showsAllApps])
    return;
  _scroll = MAX(0, _scroll - [event deltaY] * 20);
  _scroll = MIN(_scroll, MAX(0, [[_owner applications] count] * StartRowHeight
			       - (StartHeight - StartBarHeight - 112)));
  [self reload];
}

- (NSDictionary *) textAttributes: (CGFloat)size weight: (BOOL)bold
			     color: (NSColor *)color
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
      bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size],
      NSFontAttributeName, color, NSForegroundColorAttributeName, nil];
}

- (void) drawIconFor: (NSDictionary *)item in: (NSRect)rect
{
  NSImage *icon;
  NSString *kind = [item objectForKey:@"kind"];

  if ([kind isEqual:@"fileviewer"])
    icon = [NSImage imageNamed:@"common_Folder"];
  else
    icon = [[NSWorkspace sharedWorkspace] iconForFile:[item objectForKey:@"path"]];
  [icon drawInRect:rect fromRect:NSZeroRect operation:NSCompositeSourceOver
	  fraction:1.0 respectFlipped:YES hints:nil];
}

- (void) drawRect: (NSRect)dirty
{
  NSColor *text = StartColor(0xeef0f4, 0x1d1f24);
  NSColor *dim = StartColor(0x9aa0ac, 0x5f6470);
  NSColor *hover = [StartColor(0xffffff, 0x000000)
		     colorWithAlphaComponent:StartIsLight() ? 0.05 : 0.07];
  NSColor *accent = StartColor(0x00d4ff, 0x00b4dc);
  NSRect bounds = [self bounds];
  NSString *query = [_owner query];
  NSUInteger i;

  [[NSColor clearColor] set];
  NSRectFill(dirty);
  [[StartColor(0x24262d, 0xf6f7f9) colorWithAlphaComponent:0.97] set];
  [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:12 yRadius:12] fill];
  [[StartColor(0x3a3e48, 0xd3d5db) colorWithAlphaComponent:0.9] set];
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
				    xRadius:12 yRadius:12] stroke];

  /* The search field's box; the text field sits in it. */
  [StartColor(0x15171c, 0xffffff) set];
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(StartPad, 22,
		    StartWidth - 2 * StartPad, 36) xRadius:18 yRadius:18] fill];
  {
    /* A magnifying glass. */
    NSBezierPath *glass = [NSBezierPath bezierPathWithOvalInRect:
				      NSMakeRect(StartPad + 13, 32, 11, 11)];
    [glass moveToPoint:NSMakePoint(StartPad + 22.5, 41.5)];
    [glass lineToPoint:NSMakePoint(StartPad + 27, 46)];
    [glass setLineWidth:1.6];
    [glass setLineCapStyle:NSRoundLineCapStyle];
    [dim set];
    [glass stroke];
  }

  if ([query length] > 0)
    [@"Best matches" drawAtPoint:NSMakePoint(StartPad + 2, 58)
		  withAttributes:[self textAttributes:13 weight:YES color:text]];
  else if ([_owner showsAllApps])
    [@"All apps" drawAtPoint:NSMakePoint(StartPad + 2, 80)
	      withAttributes:[self textAttributes:14 weight:YES color:text]];
  else
    {
      [@"Pinned" drawAtPoint:NSMakePoint(StartPad + 2, 80)
	      withAttributes:[self textAttributes:14 weight:YES color:text]];
      [@"Recent" drawAtPoint:NSMakePoint(StartPad + 2,
					 78 + 30 + 3 * StartCellHeight + 12)
	      withAttributes:[self textAttributes:14 weight:YES color:text]];
    }

  for (i = 0; i < [_items count]; i++)
    {
      NSDictionary *item = [_items objectAtIndex:i];
      NSRect r = [[item objectForKey:@"rect"] rectValue];
      NSString *kind = [item objectForKey:@"kind"];
      NSString *title = [item objectForKey:@"title"];
      BOOL lit = (NSInteger)i == _hover;

      if ([kind isEqual:@"allapps"])
	{
	  [hover set];
	  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6] fill];
	  [[title stringByAppendingString:[_owner showsAllApps] ? @"" : @"  ›"]
	      drawAtPoint:NSMakePoint(NSMinX(r) + 10, NSMinY(r) + 4)
	   withAttributes:[self textAttributes:12 weight:NO color:text]];
	  continue;
	}
      if ([kind isEqual:@"power"])
	{
	  if (lit)
	    {
	      [hover set];
	      [[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8] fill];
	    }
	  {
	    /* The power symbol: a ring open at the top, and a bar. */
	    NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r) + 1);
	    NSBezierPath *ring = [NSBezierPath bezierPath];
	    [ring appendBezierPathWithArcWithCenter:c radius:7
				       startAngle:-60 endAngle:240 clockwise:NO];
	    [ring moveToPoint:NSMakePoint(c.x, c.y - 9)];
	    [ring lineToPoint:NSMakePoint(c.x, c.y - 1)];
	    [ring setLineWidth:1.8];
	    [ring setLineCapStyle:NSRoundLineCapStyle];
	    [text set];
	    [ring stroke];
	  }
	  continue;
	}
      if (lit)
	{
	  [([query length] > 0 ? [accent colorWithAlphaComponent:0.25] : hover) set];
	  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8] fill];
	}
      if ([query length] > 0 || [_owner showsAllApps])
	{
	  NSString *where = [kind isEqual:@"app"]
	    ? ([StartSettingsNames() containsObject:title] ? @"Setting" : @"App")
	    : [item objectForKey:@"where"];
	  [self drawIconFor:item in:NSMakeRect(NSMinX(r) + 8, NSMinY(r) + 6, 24, 24)];
	  [title drawAtPoint:NSMakePoint(NSMinX(r) + 42, NSMinY(r) + 10)
	      withAttributes:[self textAttributes:13 weight:NO color:text]];
	  if (where)
	    [where drawAtPoint:NSMakePoint(NSMaxX(r) - 90, NSMinY(r) + 11)
		withAttributes:[self textAttributes:11 weight:NO color:dim]];
	}
      else if ([kind isEqual:@"file"])
	{
	  NSString *folder = [[[item objectForKey:@"path"]
				stringByDeletingLastPathComponent] lastPathComponent];
	  [self drawIconFor:item in:NSMakeRect(NSMinX(r) + 8, NSMinY(r) + 6, 32, 32)];
	  [title drawAtPoint:NSMakePoint(NSMinX(r) + 50, NSMinY(r) + 6)
	      withAttributes:[self textAttributes:13 weight:NO color:text]];
	  [folder drawAtPoint:NSMakePoint(NSMinX(r) + 50, NSMinY(r) + 24)
	       withAttributes:[self textAttributes:11 weight:NO color:dim]];
	}
      else
	{
	  NSDictionary *attrs = [self textAttributes:12 weight:NO color:text];
	  NSSize size = [title sizeWithAttributes:attrs];
	  [self drawIconFor:item in:NSMakeRect(floor(NSMidX(r) - 20), NSMinY(r) + 10,
					       40, 40)];
	  if (size.width > NSWidth(r) - 4)
	    {
	      while ([title length] > 3 && size.width > NSWidth(r) - 10)
		{
		  title = [title substringToIndex:[title length] - 1];
		  size = [[title stringByAppendingString:@"…"] sizeWithAttributes:attrs];
		}
	      title = [title stringByAppendingString:@"…"];
	    }
	  [title drawAtPoint:NSMakePoint(floor(NSMidX(r) - size.width / 2),
					 NSMinY(r) + 58)
	      withAttributes:attrs];
	}
    }

  /* The user, at the bottom. */
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1)
				    xRadius:11 yRadius:11] addClip];
  [[StartColor(0x000000, 0x000000) colorWithAlphaComponent:
      StartIsLight() ? 0.03 : 0.12] set];
  NSRectFillUsingOperation(NSMakeRect(0, StartHeight - StartBarHeight,
				      StartWidth, StartBarHeight),
			   NSCompositeSourceOver);
  [NSGraphicsContext restoreGraphicsState];
  [StartColor(0x6f80e8, 0x6f80e8) set];
  [[NSBezierPath bezierPathWithOvalInRect:
      NSMakeRect(StartPad, StartHeight - StartBarHeight + 15, 32, 32)] fill];
  [[[NSFullUserName() length] ? NSFullUserName() : NSUserName()
      substringToIndex:1]
      drawAtPoint:NSMakePoint(StartPad + 10, StartHeight - StartBarHeight + 21)
   withAttributes:[self textAttributes:14 weight:YES color:[NSColor whiteColor]]];
  [([NSFullUserName() length] ? NSFullUserName() : NSUserName())
      drawAtPoint:NSMakePoint(StartPad + 44, StartHeight - StartBarHeight + 23)
   withAttributes:[self textAttributes:13 weight:NO color:text]];
}

@end
