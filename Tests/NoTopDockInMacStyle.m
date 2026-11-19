/*
 * In the Mac menu style the Dock is never at the top (as on macOS); a
 * saved top is used as the bottom and stays saved, so the NeXT and
 * in-window styles put the Dock back at the top. Every menu style,
 * window mode (each with its own NBModeSettings position) and saved
 * position, and the changes between them, as the Dock sees them on
 * WindowServer. Runs without a display: the Dock's window isn't made.
 */
#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import <objc/runtime.h>
#import "DockPreferences.h"
#import "AppControllerPrivate.h"
#import "WSDockManager.h"
#import "SettingsControllerPrivate.h"

@interface NSUserDefaults (IsolatedTestDatabase)
- (id) initWithContentsOfFile: (NSString *)path;
- (void) setSearchList: (NSArray *)list;
@end

static NSUserDefaults *testDefaults;
static int failures;

static id
isolatedDefaults(id receiver, SEL selector)
{
  return testDefaults;
}

static BOOL
yes(id receiver, SEL selector)
{
  return YES;
}

/* Nothing reaches the running session's Dock or apps. */
static NSUInteger posted;
static void
notPosted(id receiver, SEL selector, NSString *name, id object,
	  NSDictionary *info, BOOL immediately)
{
  posted++;
}

#define CHECK(cond, ...) do { if (!(cond)) { failures++; \
  NSLog(@"FAIL: %@", [NSString stringWithFormat:__VA_ARGS__]); } } while (0)

/* The Dock, with the menu style as the test says and no window. */
@interface StyleDock : AppController
{
@public
  NSString *style;
  NSUInteger applied;
}
@end

@implementation StyleDock

- (id) init
{
  if ((self = [super init]) != nil)
    {
      _preferences = [[DockPreferences alloc] init];
      _items = [[NSMutableArray alloc] init];
      style = @"nextstep";
    }
  return self;
}

- (BOOL) dockIsMacMenuStyle
{
  return [style isEqual:@"macmenubar"];
}

- (void) applyDockPlacement
{
  applied++;
}

- (DockPlacement) placement
{
  return _dockPlacement;
}

- (void) setPlacement: (DockPlacement)placement
{
  _dockPlacement = placement;
}

@end

/* The Placement pop-up without a backend (NSPopUpButton needs fonts,
 * so a display): what SettingsController asks of it. */
@class FakeItem;
@interface FakeItem : NSObject
- (id) initWithPopUp: (id)p index: (NSInteger)i;
@end

@interface FakePopUp : NSObject
{
@public
  NSMutableArray *titles;
  NSMutableArray *tags;
  NSString *toolTip;
}
@end

@implementation FakePopUp
- (id) init
{
  self = [super init];
  titles = [NSMutableArray new];
  tags = [NSMutableArray new];
  return self;
}
- (NSInteger) numberOfItems { return [titles count]; }
- (NSInteger) indexOfItemWithTag: (NSInteger)tag
{
  NSUInteger i = [tags indexOfObject:[NSNumber numberWithInteger:tag]];
  return i == NSNotFound ? -1 : (NSInteger)i;
}
- (void) insertItemWithTitle: (NSString *)title atIndex: (NSInteger)index
{
  [titles insertObject:title atIndex:index];
  [tags insertObject:[NSNumber numberWithInteger:0] atIndex:index];
}
- (void) removeItemAtIndex: (NSInteger)index
{
  [titles removeObjectAtIndex:index];
  [tags removeObjectAtIndex:index];
}
- (id) itemAtIndex: (NSInteger)index
{
  /* -setTag: on the item sets the tag here. */
  return [[[FakeItem alloc] initWithPopUp:self index:index] autorelease];
}
- (void) setToolTip: (NSString *)tip { ASSIGN(toolTip, tip); }
@end

@implementation FakeItem
{
  FakePopUp *popUp;
  NSInteger index;
}
- (id) initWithPopUp: (id)p index: (NSInteger)i
{
  self = [super init];
  popUp = p;
  index = i;
  return self;
}
- (void) setTag: (NSInteger)tag
{
  [popUp->tags replaceObjectAtIndex:index
			 withObject:[NSNumber numberWithInteger:tag]];
}
@end

static NSArray *
positions(void)
{
  return [NSArray arrayWithObjects:@"left", @"bottom", @"right", @"top", nil];
}

static NSString *
edgeName(DockPlacement placement)
{
  switch ([DockPreferences edgeForPlacement:placement])
    {
    case DockEdgeLeft: return @"left";
    case DockEdgeTop: return @"top";
    case DockEdgeBottom: return @"bottom";
    default: return @"right";
    }
}

/* NSGlobalDomain: the window mode, and a position for each mode. */
static void
saveSettings(NSString *mode, NSString *stacking, NSString *tiling)
{
  NSDictionary *modes = [NSDictionary dictionaryWithObjectsAndKeys:
    [NSDictionary dictionaryWithObject:stacking forKey:@"NBDockPosition"],
    @"stacking",
    [NSDictionary dictionaryWithObject:tiling forKey:@"NBDockPosition"],
    @"tiling", nil];

  [testDefaults setPersistentDomain:
    [NSDictionary dictionaryWithObjectsAndKeys:
      mode, @"NBWindowMode", modes, @"NBModeSettings", nil]
			    forName:NSGlobalDomain];
}

static NSString *
savedPosition(NSString *mode)
{
  return [[[[testDefaults persistentDomainForName:NSGlobalDomain]
	     objectForKey:@"NBModeSettings"] objectForKey:mode]
	   objectForKey:@"NBDockPosition"];
}

static NSString *
expected(NSString *position, NSString *style)
{
  if ([position isEqual:@"top"] && [style isEqual:@"macmenubar"])
    return @"bottom";
  return position;
}

int
main(void)
{
  CREATE_AUTORELEASE_POOL(pool);
  NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [[NSProcessInfo processInfo] globallyUniqueString]];
  NSString *path = [root stringByAppendingPathComponent:@"defaults"];
  NSArray *styles = [NSArray arrayWithObjects:
    @"nextstep", @"inwindow", @"macmenubar", nil];
  NSArray *modes = [NSArray arrayWithObjects:@"stacking", @"tiling", nil];
  NSUInteger checks = 0;
  NSEnumerator *se, *me, *pe, *qe, *te;
  NSString *s, *m, *p, *q, *t;
  StyleDock *dock;

  [[NSFileManager defaultManager] createDirectoryAtPath:root
			    withIntermediateDirectories:YES
					     attributes:nil
						  error:NULL];
  testDefaults = [[NSUserDefaults alloc] initWithContentsOfFile:path];
  [testDefaults setSearchList:
    [NSArray arrayWithObjects:NSGlobalDomain, NSRegistrationDomain, nil]];
  method_setImplementation(class_getClassMethod([NSUserDefaults class],
				@selector(standardUserDefaults)),
			   (IMP)isolatedDefaults);
  method_setImplementation(class_getClassMethod([WSDockManager class],
				@selector(isWindowServerSession)),
			   (IMP)yes);
  method_setImplementation(class_getInstanceMethod(
			     [NSDistributedNotificationCenter class],
			     @selector(postNotificationName:object:userInfo:deliverImmediately:)),
			   (IMP)notPosted);
  dock = [[StyleDock alloc] init];

  /* Launch: every style, mode and pair of saved positions. */
  se = [styles objectEnumerator];
  while ((s = [se nextObject]) != nil)
    {
      dock->style = s;
      CHECK([dock dockCanBeAtTop] == ![s isEqual:@"macmenubar"],
	    @"%@: can be at the top", s);
      me = [modes objectEnumerator];
      while ((m = [me nextObject]) != nil)
	{
	  pe = [positions() objectEnumerator];
	  while ((p = [pe nextObject]) != nil)
	    {
	      qe = [positions() objectEnumerator];
	      while ((q = [qe nextObject]) != nil)
		{
		  NSString *mine = [m isEqual:@"stacking"] ? p : q;

		  saveSettings(m, p, q);
		  CHECK([edgeName([dock windowServerDockPlacement])
			  isEqual:expected(mine, s)],
			@"launch %@ %@ stacking=%@ tiling=%@: %@", s, m, p, q,
			edgeName([dock windowServerDockPlacement]));
		  checks++;
		}
	    }
	}
    }

  /* Live: from each style and mode to each other one (the Dock hears
   * DesktopSettingsChanged and asks -updateDockExtrasPlace), with
   * the saved positions left as they were. */
  se = [styles objectEnumerator];
  while ((s = [se nextObject]) != nil)
    {
      me = [modes objectEnumerator];
      while ((m = [me nextObject]) != nil)
	{
	  te = [styles objectEnumerator];
	  while ((t = [te nextObject]) != nil)
	    {
	      NSEnumerator *ne = [modes objectEnumerator];
	      NSString *n;

	      while ((n = [ne nextObject]) != nil)
		{
		  pe = [positions() objectEnumerator];
		  while ((p = [pe nextObject]) != nil)
		    {
		      NSString *q = @"top";
		      NSString *now;

		      if ([p isEqual:@"top"])
			q = @"left";
		      dock->style = s;
		      saveSettings(m, p, q);
		      [dock setPlacement:[dock windowServerDockPlacement]];
		      dock->applied = 0;
		      /* The change. */
		      dock->style = t;
		      saveSettings(n, p, q);
		      [dock updateDockExtrasPlace];
		      now = expected([n isEqual:@"stacking"] ? p : q, t);
		      CHECK([edgeName([dock placement]) isEqual:now],
			    @"%@/%@ -> %@/%@ (stacking=%@ tiling=%@): %@ not %@",
			    s, m, t, n, p, q, edgeName([dock placement]), now);
		      CHECK([savedPosition(@"stacking") isEqual:p]
			    && [savedPosition(@"tiling") isEqual:q],
			    @"%@/%@ -> %@/%@: saved positions changed", s, m, t, n);
		      /* And back. */
		      dock->style = s;
		      saveSettings(m, p, q);
		      [dock updateDockExtrasPlace];
		      now = expected([m isEqual:@"stacking"] ? p : q, s);
		      CHECK([edgeName([dock placement]) isEqual:now],
			    @"back %@/%@ <- %@/%@ (stacking=%@ tiling=%@): %@ not %@",
			    s, m, t, n, p, q, edgeName([dock placement]), now);
		      checks += 3;
		    }
		}
	    }
	}
    }

  /* Workspace's notification for NBDockPosition carries a position: a
   * top one is the bottom in the Mac style. */
  se = [styles objectEnumerator];
  while ((s = [se nextObject]) != nil)
    {
      pe = [positions() objectEnumerator];
      while ((p = [pe nextObject]) != nil)
	{
	  dock->style = s;
	  saveSettings(@"stacking", @"right", @"right");
	  [dock setPlacement:DockPlacementRightTop];
	  [dock desktopSettingsDidChange:
	    [NSNotification notificationWithName:@"org.nextbsd.DesktopSettingsChanged"
					  object:nil
					userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
						   @"NBDockPosition", @"key", p, @"value", nil]]];
	  CHECK([edgeName([dock placement]) isEqual:expected(p, s)],
		@"%@: notified %@, at %@", s, p, edgeName([dock placement]));
	  checks++;
	}
    }

  /* A choice in the Dock's own Settings is saved for the mode as it is,
   * and used as the effective one. */
  me = [modes objectEnumerator];
  while ((m = [me nextObject]) != nil)
    {
      pe = [positions() objectEnumerator];
      while ((p = [pe nextObject]) != nil)
	{
	  DockPlacement chosen;

	  [DockPreferences placement:&chosen forDockPosition:p];
	  dock->style = @"nextstep";
	  saveSettings(m, @"right", @"right");
	  [dock settingsController:nil didChangeDockPlacement:chosen];
	  CHECK([savedPosition(m) isEqual:p], @"Settings %@ in %@: saved %@",
		p, m, savedPosition(m));
	  CHECK([savedPosition([m isEqual:@"stacking"] ? @"tiling" : @"stacking")
		  isEqual:@"right"], @"Settings %@ in %@: other mode kept", p, m);
	  CHECK([edgeName([dock placement]) isEqual:p], @"Settings %@: at %@",
		p, edgeName([dock placement]));
	  checks += 3;
	}
    }

  /* The Dock's Settings: Top only where the Dock can be at the top,
   * back in its place between Right and Bottom, and a tooltip saying
   * why it's gone. */
  {
    SettingsController *settings = [[SettingsController alloc]
				     initWithDelegate:(id)dock];
    FakePopUp *popUp = [[FakePopUp alloc] init];
    NSArray *order = [NSArray arrayWithObjects:@"Left", @"Right", @"Top",
				@"Bottom", nil];
    NSArray *sequence = [NSArray arrayWithObjects:@"nextstep", @"macmenubar",
				   @"macmenubar", @"inwindow", @"macmenubar",
				   @"nextstep", @"nextstep", nil];
    NSArray *macOrder = [NSArray arrayWithObjects:@"Left", @"Right",
				   @"Bottom", nil];
    NSUInteger i;

    for (i = 0; i < 4; i++)
      {
	[popUp insertItemWithTitle:[order objectAtIndex:i] atIndex:i];
	[[popUp itemAtIndex:i] setTag:
	  (NSInteger)[DockPreferences placementForEdge:(DockEdge)i]];
      }
    object_setIvar(settings, class_getInstanceVariable([SettingsController class],
							"_placementPopup"),
		   popUp);
    for (i = 0; i < [sequence count]; i++)
      {
	BOOL mac;

	dock->style = [sequence objectAtIndex:i];
	mac = [dock->style isEqual:@"macmenubar"];
	[settings updatePlacementChoices];
	if (mac)
	  {
	    CHECK([popUp->titles isEqual:macOrder]
		  && [popUp indexOfItemWithTag:DockPlacementTopCenter] < 0
		  && popUp->toolTip != nil,
		  @"Settings in %@: %@ %@", dock->style, popUp->titles,
		  popUp->toolTip);
	  }
	else
	  {
	    CHECK([popUp->titles isEqual:order]
		  && [popUp indexOfItemWithTag:DockPlacementTopCenter] == 2
		  && [popUp indexOfItemWithTag:DockPlacementBottomCenter] == 3
		  && [popUp indexOfItemWithTag:DockPlacementLeftTop] == 0
		  && [popUp indexOfItemWithTag:DockPlacementRightTop] == 1
		  && popUp->toolTip == nil,
		  @"Settings in %@: %@ %@ %@", dock->style, popUp->titles,
		  popUp->tags, popUp->toolTip);
	  }
	checks++;
      }
  }

  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
  if (failures)
    {
      NSLog(@"No-top Dock tests: %d of %lu checks failed", failures,
	    (unsigned long)checks);
      return 1;
    }
  NSLog(@"No-top Dock tests passed (%lu checks)", (unsigned long)checks);
  RELEASE(pool);
  return 0;
}
