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

#import "DockExtrasController.h"
#import <GNUstepBase/GNUstep.h>

#define DockExtrasOrderKey @"DockExtrasOrder"
#define DockExtrasHiddenKey @"DockExtrasHidden"
#define DockExtrasTestDataKey @"DockExtrasTestData"

@interface DockExtrasController (Private)
- (NSMutableDictionary *) recordForExtra: (id)extra;
- (void) sortRecords;
- (void) saveOrder;
- (BOOL) loadRecord: (NSMutableDictionary *)record;
- (void) unloadRecord: (NSMutableDictionary *)record;
- (void) updateShownExtras;
@end

@implementation DockExtrasController

/* Where extras are found, the user's first: an extra in ~/Library
 * replaces the system's copy with the same identifier. */
+ (NSArray *) searchPaths
{
  NSMutableArray *paths = [NSMutableArray array];
  NSArray *libraries;
  NSString *path;
  NSUInteger i;

  [paths addObject:[NSHomeDirectory()
		     stringByAppendingPathComponent:@"Library/DockExtras"]];
  [paths addObject:@"/Local/Library/DockExtras"];
  [paths addObject:@"/System/Library/DockExtras"];
  /* GNUstep's own Library folders, where they are elsewhere (another
   * filesystem layout). */
  libraries = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
						  NSAllDomainsMask, YES);
  for (i = 0; i < [libraries count]; i++)
    {
      path = [[libraries objectAtIndex:i]
	       stringByAppendingPathComponent:@"DockExtras"];
      if (![paths containsObject:path])
	{
	  [paths addObject:path];
	}
    }
  return paths;
}

- (id) initWithDelegate: (id <DockExtrasControllerDelegate>)delegate
{
  self = [super init];
  if (self)
    {
      _delegate = delegate;
      _records = [NSMutableArray new];
      _shownExtras = [NSArray new];
    }
  return self;
}

- (void) dealloc
{
  [self unloadExtras];
  DESTROY(_records);
  DESTROY(_shownExtras);
  DEALLOC;
}

- (void) loadExtras
{
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray *paths = [DockExtrasController searchPaths];
  NSArray *hidden = [[NSUserDefaults standardUserDefaults]
		      arrayForKey:DockExtrasHiddenKey];
  NSMutableSet *identifiers = [NSMutableSet set];
  NSUInteger i, j;

  for (i = 0; i < [paths count]; i++)
    {
      NSString *folder = [paths objectAtIndex:i];
      NSArray *names = [[manager directoryContentsAtPath:folder]
			 sortedArrayUsingSelector:@selector(compare:)];

      for (j = 0; j < [names count]; j++)
	{
	  NSString *name = [names objectAtIndex:j];
	  NSString *path;
	  NSBundle *bundle;
	  NSDictionary *info;
	  NSString *identifier;
	  NSString *title;
	  id position;
	  NSMutableDictionary *record;

	  if (![[name pathExtension] isEqualToString:@"dockextra"])
	    {
	      continue;
	    }
	  path = [folder stringByAppendingPathComponent:name];
	  bundle = [NSBundle bundleWithPath:path];
	  info = [bundle infoDictionary];
	  identifier = [info objectForKey:@"CFBundleIdentifier"];
	  if (![identifier length])
	    {
	      NSLog(@"Dock extra %@ has no CFBundleIdentifier; skipped.", path);
	      continue;
	    }
	  if ([identifiers containsObject:identifier])
	    {
	      continue;
	    }
	  [identifiers addObject:identifier];
	  title = [info objectForKey:@"CFBundleName"];
	  if (![title length])
	    {
	      title = [name stringByDeletingPathExtension];
	    }
	  position = [info objectForKey:@"DockExtraDefaultPosition"];
	  record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
					  identifier, @"identifier",
					title, @"name",
					path, @"path",
					[NSNumber numberWithInteger:
						    position ? [position integerValue]
						  : 1000], @"position",
					nil];
	  [_records addObject:record];
	}
    }
  [self sortRecords];
  for (i = 0; i < [_records count]; i++)
    {
      NSMutableDictionary *record = [_records objectAtIndex:i];

      if (![hidden containsObject:[record objectForKey:@"identifier"]])
	{
	  [self loadRecord:record];
	}
    }
  [self updateShownExtras];
}

- (void) unloadExtras
{
  NSUInteger i;

  for (i = 0; i < [_records count]; i++)
    {
      [self unloadRecord:[_records objectAtIndex:i]];
    }
  ASSIGN(_shownExtras, [NSArray array]);
}

- (NSArray *) shownExtras
{
  return _shownExtras;
}

- (void) setOrderOfShownExtras: (NSArray *)extras
{
  NSMutableArray *slots = [NSMutableArray array];
  NSUInteger i;

  /* The shown extras' records take the places the shown extras had. */
  for (i = 0; i < [_records count]; i++)
    {
      id instance = [[_records objectAtIndex:i] objectForKey:@"instance"];

      if (instance && [_shownExtras indexOfObjectIdenticalTo:instance] != NSNotFound)
	{
	  [slots addObject:[NSNumber numberWithUnsignedInteger:i]];
	}
    }
  if ([slots count] != [extras count])
    {
      return;
    }
  {
    NSMutableArray *moved = [NSMutableArray array];

    for (i = 0; i < [extras count]; i++)
      {
	NSMutableDictionary *record = [self recordForExtra:[extras objectAtIndex:i]];

	if (!record)
	  {
	    return;
	  }
	[moved addObject:record];
      }
    for (i = 0; i < [slots count]; i++)
      {
	[_records replaceObjectAtIndex:[[slots objectAtIndex:i] unsignedIntegerValue]
			    withObject:[moved objectAtIndex:i]];
      }
  }
  [self saveOrder];
  [self updateShownExtras];
}

- (NSArray *) extrasDescriptions
{
  NSArray *hidden = [[NSUserDefaults standardUserDefaults]
		      arrayForKey:DockExtrasHiddenKey];
  NSMutableArray *result = [NSMutableArray array];
  NSUInteger i;

  for (i = 0; i < [_records count]; i++)
    {
      NSDictionary *record = [_records objectAtIndex:i];
      NSString *identifier = [record objectForKey:@"identifier"];
      id instance = [record objectForKey:@"instance"];

      [result addObject:
		[NSDictionary dictionaryWithObjectsAndKeys:
				identifier, @"identifier",
			      [record objectForKey:@"name"], @"name",
			      [NSNumber numberWithBool:
					  [hidden containsObject:identifier]],
			      @"hidden",
			      [NSNumber numberWithBool:
					  instance && [instance isAvailable]],
			      @"available",
			      nil]];
    }
  return result;
}

- (void) setHidden: (BOOL)hide forExtraWithIdentifier: (NSString *)identifier
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableArray *hidden = [NSMutableArray arrayWithArray:
					     [defaults arrayForKey:DockExtrasHiddenKey]];
  NSUInteger i;

  if (hide == [hidden containsObject:identifier])
    {
      return;
    }
  if (hide)
    {
      [hidden addObject:identifier];
    }
  else
    {
      [hidden removeObject:identifier];
    }
  [defaults setObject:hidden forKey:DockExtrasHiddenKey];
  [defaults synchronize];
  for (i = 0; i < [_records count]; i++)
    {
      NSMutableDictionary *record = [_records objectAtIndex:i];

      if ([[record objectForKey:@"identifier"] isEqualToString:identifier])
	{
	  if (hide)
	    {
	      [self unloadRecord:record];
	    }
	  else
	    {
	      [self loadRecord:record];
	    }
	}
    }
  [self updateShownExtras];
}

/* DockExtraHost */

- (void) dockExtraNeedsDisplay: (id)extra
{
  if ([_shownExtras indexOfObjectIdenticalTo:extra] != NSNotFound)
    {
      [_delegate dockExtrasController:self extraNeedsDisplay:extra];
    }
}

- (void) dockExtraAvailabilityDidChange: (id)extra
{
  [self updateShownExtras];
}

- (NSRect) screenFrameForDockExtra: (id)extra
{
  if ([_shownExtras indexOfObjectIdenticalTo:extra] == NSNotFound)
    {
      return NSZeroRect;
    }
  return [_delegate dockExtrasController:self screenFrameForExtra:extra];
}

- (NSRect) dockExtra: (id)extra panelFrameForSize: (NSSize)size
{
  return [_delegate dockExtrasController:self panelFrameForExtra:extra
				    size:size];
}

- (CGFloat) dockExtraCellSize
{
  return [_delegate dockExtrasControllerCellSize:self];
}

- (BOOL) dockExtrasUseTestData
{
  id value = [[NSUserDefaults standardUserDefaults]
	       objectForKey:DockExtrasTestDataKey];

  if ([value isKindOfClass:[NSDictionary class]])
    {
      return YES;
    }
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

- (NSDictionary *) dockExtrasTestData
{
  id value = [[NSUserDefaults standardUserDefaults]
	       objectForKey:DockExtrasTestDataKey];

  return [value isKindOfClass:[NSDictionary class]]
    ? value : [NSDictionary dictionary];
}

@end

@implementation DockExtrasController (Private)

- (NSMutableDictionary *) recordForExtra: (id)extra
{
  NSUInteger i;

  for (i = 0; i < [_records count]; i++)
    {
      if ([[_records objectAtIndex:i] objectForKey:@"instance"] == extra)
	{
	  return [_records objectAtIndex:i];
	}
    }
  return nil;
}

/* The saved order first; an extra that isn't in it yet (newly
 * installed) goes in by its default position. */
- (void) sortRecords
{
  NSArray *saved = [[NSUserDefaults standardUserDefaults]
		     arrayForKey:DockExtrasOrderKey];
  NSMutableArray *sorted = [NSMutableArray array];
  NSMutableArray *rest = [NSMutableArray array];
  NSUInteger i, j;

  for (i = 0; i < [saved count]; i++)
    {
      for (j = 0; j < [_records count]; j++)
	{
	  NSMutableDictionary *record = [_records objectAtIndex:j];

	  if ([[record objectForKey:@"identifier"]
		isEqual:[saved objectAtIndex:i]])
	    {
	      [sorted addObject:record];
	      break;
	    }
	}
    }
  for (j = 0; j < [_records count]; j++)
    {
      if ([sorted indexOfObjectIdenticalTo:[_records objectAtIndex:j]] == NSNotFound)
	{
	  [rest addObject:[_records objectAtIndex:j]];
	}
    }
  [rest sortUsingDescriptors:
	  [NSArray arrayWithObject:
		     AUTORELEASE([[NSSortDescriptor alloc]
				   initWithKey:@"position" ascending:YES])]];
  for (i = 0; i < [rest count]; i++)
    {
      NSMutableDictionary *record = [rest objectAtIndex:i];
      NSInteger position = [[record objectForKey:@"position"] integerValue];

      for (j = 0; j < [sorted count]; j++)
	{
	  if ([[[sorted objectAtIndex:j] objectForKey:@"position"] integerValue]
	      > position)
	    {
	      break;
	    }
	}
      [sorted insertObject:record atIndex:j];
    }
  [_records setArray:sorted];
}

- (void) saveOrder
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [defaults setObject:[_records valueForKey:@"identifier"]
	       forKey:DockExtrasOrderKey];
  [defaults synchronize];
}

- (BOOL) loadRecord: (NSMutableDictionary *)record
{
  NSString *path = [record objectForKey:@"path"];
  NSBundle *bundle;
  Class principal;
  id extra = nil;

  if ([record objectForKey:@"instance"])
    {
      return YES;
    }
  bundle = [NSBundle bundleWithPath:path];
  NS_DURING
    {
      principal = [bundle principalClass];
      if (!principal)
	{
	  NSLog(@"Dock extra %@ has no principal class; skipped.", path);
	}
      else if (![principal instancesRespondToSelector:@selector(initWithDockHost:)]
	       || ![principal instancesRespondToSelector:@selector(drawInRect:)]
	       || ![principal instancesRespondToSelector:@selector(menuForEvent:)])
	{
	  NSLog(@"Dock extra %@ doesn't conform to DockExtra; skipped.", path);
	}
      else
	{
	  extra = [[principal alloc] initWithDockHost:self];
	}
    }
  NS_HANDLER
    {
      NSLog(@"Dock extra %@ failed to load: %@", path, localException);
      extra = nil;
    }
  NS_ENDHANDLER
  if (!extra)
    {
      return NO;
    }
  [record setObject:extra forKey:@"instance"];
  RELEASE(extra);
  return YES;
}

- (void) unloadRecord: (NSMutableDictionary *)record
{
  id extra = [record objectForKey:@"instance"];

  if (!extra)
    {
      return;
    }
  if ([extra respondsToSelector:@selector(dockExtraWillUnload)])
    {
      NS_DURING
	[extra dockExtraWillUnload];
      NS_HANDLER
	NSLog(@"Dock extra %@ failed to unload: %@",
	      [record objectForKey:@"identifier"], localException);
      NS_ENDHANDLER
    }
  [record removeObjectForKey:@"instance"];
}

- (void) updateShownExtras
{
  NSMutableArray *shown = [NSMutableArray array];
  NSUInteger i;

  for (i = 0; i < [_records count]; i++)
    {
      id extra = [[_records objectAtIndex:i] objectForKey:@"instance"];

      if (extra && [extra isAvailable])
	{
	  [shown addObject:extra];
	}
    }
  if (![shown isEqualToArray:_shownExtras])
    {
      ASSIGNCOPY(_shownExtras, shown);
      [_delegate dockExtrasControllerDidChangeExtras:self];
    }
}

@end
