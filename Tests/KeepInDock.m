#import "AppControllerPrivate.h"
#import "DockViewPrivate.h"
#import <objc/runtime.h>

@interface NSUserDefaults (IsolatedTestDatabase)

- (id) initWithContentsOfFile: (NSString *)path;

@end

static NSUserDefaults *testDefaults;

static id isolatedDefaults(id receiver, SEL selector)
{
  return testDefaults;
}

@interface KeepInDockController : AppController

- (NSMutableArray *) items;

@end

@implementation KeepInDockController

- (id) init
{
  self = [super init];
  if (self)
    {
      _items = [[NSMutableArray alloc] init];
    }
  return self;
}

- (NSMutableArray *) items
{
  return _items;
}

- (void) refreshDock
{
}

- (void) savePersistedApplications
{
}

@end

int main(void)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSUserDefaults *defaults;
  Method method;
  IMP original;
  NSString *name = [[NSProcessInfo processInfo] globallyUniqueString];
  NSString *path = [@"/tmp" stringByAppendingPathComponent:name];
  KeepInDockController *controller = [[KeepInDockController alloc] init];
  NSString *domain = [controller defaultsDomainForApplicationPath:path];
  DockView *view;
  DockItem *item;
  id<NSMenuItem> toggle;

  [NSApplication sharedApplication];
  testDefaults = [[NSUserDefaults alloc]
                   initWithContentsOfFile:[path stringByAppendingString:@"-defaults"]];
  defaults = testDefaults;
  [defaults synchronize];
  method = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
  original = method_setImplementation(method, (IMP)isolatedDefaults);
  /* An older Dock's opt-out, which hid the app even while it ran. */
  [defaults setPersistentDomain:[NSDictionary dictionaryWithObjectsAndKeys:
                                  @"preserved", @"Unrelated",
                                  [NSNumber numberWithBool:NO], @"GSDockKeepInDock",
                                  nil] forName:domain];
  [defaults synchronize];
  item = [DockItem applicationItemWithPath:path];
  [item setPinned:NO];
  [item setState:DockItemRunning];
  [[controller items] addObject:item];
  view = [[DockView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
  [view setDelegate:controller];
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Remove from Dock"];
  NSCAssert(toggle != nil && [toggle state] == NSOffState,
            @"Every app's menu has Remove from Dock, unchecked");
  [view performSelector:[toggle action] withObject:toggle];
  NSCAssert([[controller items] count] == 1 && ![item isPinned],
            @"Removing a running app that isn't kept does nothing");
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Keep in Dock"];
  NSCAssert(toggle != nil && [toggle state] == NSOffState,
            @"Every app's menu has Keep in Dock, unchecked");
  [view performSelector:[toggle action] withObject:toggle];
  NSCAssert([[controller items] count] == 1 && [item isPinned],
            @"Keep in Dock keeps the running app");
  NSCAssert([[defaults persistentDomainForName:domain]
              objectForKey:@"GSDockKeepInDock"] == nil,
            @"Keeping it drops the old opt-out");
  NSCAssert([[[defaults persistentDomainForName:domain] objectForKey:@"Unrelated"]
              isEqual:@"preserved"], @"Other application defaults are preserved");
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Keep in Dock"];
  NSCAssert([toggle state] == NSOffState, @"Keep in Dock is never checked");
  [view performSelector:[toggle action] withObject:toggle];
  NSCAssert([[controller items] count] == 1 && [item isPinned],
            @"Keeping a kept app does nothing");
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Remove from Dock"];
  [view performSelector:[toggle action] withObject:toggle];
  NSCAssert([[controller items] count] == 1 && ![item isPinned],
            @"Removing a running app leaves it with the running apps");
  [item setState:DockItemNotRunning];
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Keep in Dock"];
  [view performSelector:[toggle action] withObject:toggle];
  toggle = [[view menuForDockItem:item] itemWithTitle:@"Remove from Dock"];
  [view performSelector:[toggle action] withObject:toggle];
  NSCAssert([[controller items] count] == 0,
            @"Removing an app that isn't running removes its tile");
  [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data]
                                   attributes:nil];
  [(id<DockViewDelegate>)controller dockViewDidReceivePaths:[NSArray arrayWithObject:path] atIndex:0];
  NSCAssert([[controller items] count] == 1 &&
            [[[controller items] objectAtIndex:0] isPinned],
            @"Dropping the app keeps it again");
  [defaults removePersistentDomainForName:domain];
  [defaults synchronize];
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  RELEASE(view);
  RELEASE(controller);
  method_setImplementation(method, original);
  RELEASE(testDefaults);
  [[NSFileManager defaultManager]
    removeItemAtPath:[path stringByAppendingString:@"-defaults"] error:NULL];
  NSLog(@"Keep in Dock tests passed");
  RELEASE(pool);
  return 0;
}

