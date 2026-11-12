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
 * The Wi-Fi Dock extra: signal bars for the network wland has joined, or
 * empty bars when it isn't connected; the network's name in the tooltip.
 *
 * State comes from wland's State:/Network/Interface/<if>/AirPort entries
 * in SystemConfiguration, watched with SCDynamicStore notifications (see
 * DockWiFiSource), so nothing is polled. The menu lists the networks of
 * the last scan and joins one; scans and joins go through wlan(8), which
 * wlan(8) documents as the supported way for the desktop to drive wland.
 * Secured networks ask for the passphrase in a panel. With no radio
 * (no AirPort entry, and nothing in "wlan list") there is no tile.
 *
 * For testing, the Dock's DockExtrasTestData shows a made-up connection
 * where there is no radio: WiFiSSID ("NextBSD"), WiFiRSSI (-58) and
 * WiFiConnected (YES) in the dictionary set it.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "DockExtraNotify.h"
#import "DockWiFiSource.h"

#define DockWiFiTool @"/usr/sbin/wlan"
#define DockWiFiMaxInterfaces 4
#define DockWiFiRescanAge 20.0

@interface DockWiFiExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  void *_store;
  int _pipe[2];
  NSFileHandle *_handle;
  DockWiFiState _state;
  BOOL _haveState;
  BOOL _testData;
  /* Interfaces "wlan list" reported, for a radio with no AirPort entry
   * yet. */
  NSArray *_listedInterfaces;
  NSArray *_networks;
  NSDate *_scanDate;
  NSTask *_scanTask;
  NSPanel *_passwordPanel;
  NSSecureTextField *_passwordField;
  NSTextField *_passwordLabel;
  NSString *_joiningSSID;
}
- (void) readState;
- (void) runWlan: (NSArray *)arguments
	  notify: (SEL)selector;
@end

static NSArray *
DockWiFiRunLoopModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

/* Bars for a signal in dBm: wlan(8)'s steps. */
static NSInteger
DockWiFiBars(int rssi)
{
  if (rssi >= -60)
    {
      return 3;
    }
  if (rssi >= -70)
    {
      return 2;
    }
  return 1;
}

/* A small signal glyph for a network in the menu. */
static NSImage *
DockWiFiSignalImage(NSInteger bars)
{
  NSImage *image = AUTORELEASE([[NSImage alloc]
				 initWithSize:NSMakeSize(18.0, 14.0)]);
  NSPoint center = NSMakePoint(9.0, 2.0);
  NSInteger i;

  [image lockFocus];
  for (i = 0; i < 3; i++)
    {
      NSBezierPath *arc = [NSBezierPath bezierPath];

      [arc appendBezierPathWithArcWithCenter:center
				      radius:4.0 + 3.5 * i
				  startAngle:45.0
				    endAngle:135.0];
      [arc setLineWidth:1.8];
      [arc setLineCapStyle:NSRoundLineCapStyle];
      [[NSColor colorWithCalibratedWhite:1.0 alpha:i < bars ? 0.95 : 0.3] set];
      [arc stroke];
    }
  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.95] set];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7.8, 0.8, 2.4, 2.4)] fill];
  [image unlockFocus];
  return image;
}

/* "wlan scan" output: a header, then fixed columns, SSID padded to 32
 * bytes, BSSID to 18, a 4-character bar, RSSI, channel, security. */
static NSArray *
DockWiFiParseScan(NSData *data)
{
  NSMutableArray *networks = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  const char *bytes = [data bytes];
  NSUInteger length = [data length];
  NSUInteger start = 0;
  NSUInteger i;

  for (i = 0; i <= length; i++)
    {
      char line[256];
      NSUInteger n;
      int rssi, channel;
      char security[64];
      NSString *ssid;

      if (i < length && bytes[i] != '\n')
	{
	  continue;
	}
      n = MIN(i - start, sizeof(line) - 1);
      memcpy(line, bytes + start, n);
      line[n] = '\0';
      start = i + 1;
      if (n < 58 || strncmp(line, "SSID ", 5) == 0)
	{
	  continue;
	}
      if (sscanf(line + 57, "%d %d %63[^\n]", &rssi, &channel, security) != 3)
	{
	  continue;
	}
      line[32] = '\0';
      ssid = [[NSString stringWithUTF8String:line]
	       stringByTrimmingCharactersInSet:
		 [NSCharacterSet whitespaceCharacterSet]];
      if (![ssid length] || [seen containsObject:ssid])
	{
	  /* Hidden networks, and other access points of a network
	   * already listed (the scan is strongest first). */
	  continue;
	}
      [seen addObject:ssid];
      [networks addObject:
		  [NSDictionary dictionaryWithObjectsAndKeys:
				  ssid, @"ssid",
				[NSNumber numberWithInt:rssi], @"rssi",
				[NSString stringWithUTF8String:security],
				@"security", nil]];
    }
  [networks sortUsingDescriptors:
	      [NSArray arrayWithObject:
			 AUTORELEASE([[NSSortDescriptor alloc]
				       initWithKey:@"rssi" ascending:NO])]];
  return networks;
}

@implementation DockWiFiExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      _host = host;
      _listedInterfaces = [NSArray new];
      _networks = [NSArray new];
      DockExtraNotifyPipe(_pipe);
      _store = DockWiFiOpen(_pipe[1]);
      if (_pipe[0] >= 0)
	{
	  _handle = [[NSFileHandle alloc] initWithFileDescriptor:_pipe[0]
						  closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(stateChanged:)
		   name:NSFileHandleDataAvailableNotification
		 object:_handle];
	  [_handle waitForDataInBackgroundAndNotifyForModes:
		     DockWiFiRunLoopModes()];
	}
      [self readState];
      /* A radio wland manages but hasn't published yet still gets a
       * tile; ask once. */
      if ([[NSFileManager defaultManager] isExecutableFileAtPath:DockWiFiTool])
	{
	  [self runWlan:[NSArray arrayWithObject:@"list"]
		 notify:@selector(listFinished:)];
	}
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  DockWiFiClose(_store);
  _store = NULL;
  [_handle closeFile];
  DESTROY(_handle);
  if (_pipe[1] >= 0)
    {
      close(_pipe[1]);
    }
  _pipe[0] = _pipe[1] = -1;
  [_passwordPanel close];
  DESTROY(_passwordPanel);
  DESTROY(_passwordField);
  DESTROY(_passwordLabel);
  DESTROY(_joiningSSID);
  DESTROY(_scanTask);
  DESTROY(_scanDate);
  DESTROY(_networks);
  DESTROY(_listedInterfaces);
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DEALLOC;
}

- (BOOL) isAvailable
{
  return _haveState || [_listedInterfaces count] > 0;
}

- (NSString *) interfaceName
{
  if (_haveState && _state.interface[0])
    {
      return [NSString stringWithUTF8String:_state.interface];
    }
  return [_listedInterfaces count] ? [_listedInterfaces objectAtIndex:0] : nil;
}

- (BOOL) connected
{
  return _haveState && _state.authenticated && _state.ssid[0];
}

- (void) readState
{
  DockWiFiState states[DockWiFiMaxInterfaces];
  DockWiFiState state;
  BOOL wasAvailable = [self isAvailable];
  BOOL have;
  int count = DockWiFiRead(_store, states, DockWiFiMaxInterfaces);
  int i;

  memset(&state, 0, sizeof(state));
  have = count > 0;
  /* Several radios: show the connected one. */
  for (i = 0; i < count; i++)
    {
      if (i == 0 || (states[i].authenticated && !state.authenticated))
	{
	  state = states[i];
	}
    }
  _testData = NO;
  if (!have && [_listedInterfaces count] == 0 && [_host dockExtrasUseTestData])
    {
      NSDictionary *test = [_host dockExtrasTestData];
      id value;

      value = [test objectForKey:@"WiFiConnected"];
      state.authenticated = value ? [value boolValue] : YES;
      value = [test objectForKey:@"WiFiSSID"];
      strlcpy(state.ssid, value ? [value UTF8String] : "NextBSD",
	      sizeof(state.ssid));
      if (!state.authenticated)
	{
	  state.ssid[0] = '\0';
	}
      value = [test objectForKey:@"WiFiRSSI"];
      state.rssi = value ? [value intValue] : -58;
      state.channel = 36;
      strlcpy(state.interface, "wlan0", sizeof(state.interface));
      strlcpy(state.security, "WPA2", sizeof(state.security));
      have = YES;
      _testData = YES;
      if (![_networks count])
	{
	  ASSIGN(_networks,
		 ([NSArray arrayWithObjects:
			     [NSDictionary dictionaryWithObjectsAndKeys:
					     [NSString stringWithUTF8String:state.ssid],
					   @"ssid",
					   [NSNumber numberWithInt:state.rssi],
					   @"rssi", @"WPA2", @"security", nil],
			   [NSDictionary dictionaryWithObjectsAndKeys:
					   @"Cafe", @"ssid",
					 [NSNumber numberWithInt:-67], @"rssi",
					 @"open", @"security", nil],
			   [NSDictionary dictionaryWithObjectsAndKeys:
					   @"Office", @"ssid",
					 [NSNumber numberWithInt:-74], @"rssi",
					 @"802.1X", @"security", nil],
			   nil]));
	}
    }
  if (have == _haveState && memcmp(&state, &_state, sizeof(state)) == 0)
    {
      return;
    }
  _state = state;
  _haveState = have;
  if ([self isAvailable] != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  [_host dockExtraNeedsDisplay:self];
}

- (void) stateChanged: (NSNotification *)notification
{
  DockExtraNotifyDrain(_pipe[0]);
  [self readState];
  [self performSelector:@selector(watch) withObject:nil afterDelay:0.0];
}

- (void) watch
{
  [_handle waitForDataInBackgroundAndNotifyForModes:DockWiFiRunLoopModes()];
}

/* wlan(8), asynchronously: selector gets a dictionary with status
 * (NSNumber), output and error (NSData). */
- (void) runWlan: (NSArray *)arguments notify: (SEL)selector
{
  NSTask *task = AUTORELEASE([NSTask new]);
  NSPipe *output = [NSPipe pipe];
  NSPipe *error = [NSPipe pipe];

  [task setLaunchPath:DockWiFiTool];
  [task setArguments:arguments];
  [task setStandardOutput:output];
  [task setStandardError:error];
  [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
  NS_DURING
    [task launch];
  NS_HANDLER
    NSLog(@"Wi-Fi extra: can't run %@: %@", DockWiFiTool, localException);
    return;
  NS_ENDHANDLER
  /* wlan's output is small; read it in the background as it comes. */
  [self performSelector:@selector(collectTask:)
	     withObject:[NSDictionary dictionaryWithObjectsAndKeys:
					task, @"task",
				      output, @"output", error, @"error",
				      NSStringFromSelector(selector), @"selector",
				      [NSMutableData data], @"outputData",
				      [NSMutableData data], @"errorData",
				      nil]
	     afterDelay:0.2];
}

- (void) collectTask: (NSDictionary *)job
{
  NSTask *task = [job objectForKey:@"task"];
  NSFileHandle *output = [[job objectForKey:@"output"] fileHandleForReading];
  NSFileHandle *error = [[job objectForKey:@"error"] fileHandleForReading];

  if ([task isRunning])
    {
      /* A scan takes seconds (wlan waits up to 15); look again soon. */
      [self performSelector:@selector(collectTask:) withObject:job
		 afterDelay:0.5];
      return;
    }
  [[job objectForKey:@"outputData"] appendData:[output readDataToEndOfFile]];
  [[job objectForKey:@"errorData"] appendData:[error readDataToEndOfFile]];
  [self performSelector:NSSelectorFromString([job objectForKey:@"selector"])
	     withObject:[NSDictionary dictionaryWithObjectsAndKeys:
					[NSNumber numberWithInt:
						    [task terminationStatus]],
				      @"status",
				      [job objectForKey:@"outputData"], @"output",
				      [job objectForKey:@"errorData"], @"error",
				      nil]];
}

- (void) listFinished: (NSDictionary *)result
{
  NSString *text = AUTORELEASE([[NSString alloc]
				 initWithData:[result objectForKey:@"output"]
				     encoding:NSUTF8StringEncoding]);
  NSMutableArray *names = [NSMutableArray array];
  NSArray *lines = [text componentsSeparatedByString:@"\n"];
  BOOL wasAvailable = [self isAvailable];
  NSUInteger i;

  if ([[result objectForKey:@"status"] intValue] == 0)
    {
      for (i = 0; i < [lines count]; i++)
	{
	  NSString *line = [[lines objectAtIndex:i]
			     stringByTrimmingCharactersInSet:
			       [NSCharacterSet whitespaceCharacterSet]];

	  if ([line length] && [line rangeOfString:@" "].location == NSNotFound)
	    {
	      [names addObject:line];
	    }
	}
    }
  ASSIGN(_listedInterfaces, names);
  if ([self isAvailable] != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
      [_host dockExtraNeedsDisplay:self];
    }
  if ([self isAvailable] && !_testData)
    {
      [self scan];
    }
}

- (void) scan
{
  NSString *interface = [self interfaceName];

  if (_scanTask || !interface || _testData)
    {
      return;
    }
  ASSIGN(_scanTask, (id)[NSNull null]);
  [self runWlan:[NSArray arrayWithObjects:@"scan", interface, nil]
	 notify:@selector(scanFinished:)];
}

- (void) scanFinished: (NSDictionary *)result
{
  DESTROY(_scanTask);
  ASSIGN(_scanDate, [NSDate date]);
  if ([[result objectForKey:@"status"] intValue] == 0)
    {
      ASSIGN(_networks, DockWiFiParseScan([result objectForKey:@"output"]));
    }
  else
    {
      NSLog(@"Wi-Fi extra: wlan scan failed: %@",
	    AUTORELEASE([[NSString alloc]
			  initWithData:[result objectForKey:@"error"]
			      encoding:NSUTF8StringEncoding]));
    }
}

- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat s = NSWidth(plate);
  NSPoint center = NSMakePoint(NSMidX(plate), NSMinY(plate) + s * 0.24);
  NSInteger bars = [self connected] ? DockWiFiBars(_state.rssi) : 0;
  NSInteger i;

  DockExtraDrawPlate(rect);
  for (i = 0; i < 3; i++)
    {
      NSBezierPath *arc = [NSBezierPath bezierPath];
      CGFloat radius = s * (0.20 + 0.15 * i);

      [arc appendBezierPathWithArcWithCenter:center
				      radius:radius
				  startAngle:45.0
				    endAngle:135.0];
      [arc setLineWidth:MAX(2.0, s * 0.075)];
      [arc setLineCapStyle:NSRoundLineCapStyle];
      [DockExtraForegroundColor(i >= bars) set];
      [arc stroke];
    }
  [DockExtraForegroundColor(![self connected]) set];
  [[NSBezierPath bezierPathWithOvalInRect:
		   NSMakeRect(center.x - s * 0.06, center.y - s * 0.06,
			      s * 0.12, s * 0.12)] fill];
  if (_haveState && !_state.authenticated && _state.ssid[0])
    {
      /* Joining: associated, the handshake not done yet. */
      NSString *dots = @"…";
      NSDictionary *attributes =
	[NSDictionary dictionaryWithObjectsAndKeys:
			[NSFont boldSystemFontOfSize:floor(s * 0.25)],
		      NSFontAttributeName, DockExtraForegroundColor(NO),
		      NSForegroundColorAttributeName, nil];

      [dots drawAtPoint:NSMakePoint(NSMaxX(plate) - s * 0.30,
				    NSMinY(plate) + s * 0.02)
	 withAttributes:attributes];
    }
}

- (NSString *) toolTip
{
  NSString *test = _testData ? @" [test data]" : @"";

  if ([self connected])
    {
      return [NSString stringWithFormat:@"Wi-Fi: %s (%d dBm, channel %d, %s)%@",
		       _state.ssid, _state.rssi, _state.channel,
		       _state.security, test];
    }
  if (_haveState && _state.ssid[0])
    {
      return [NSString stringWithFormat:@"Wi-Fi: joining %s%@",
		       _state.ssid, test];
    }
  return [NSString stringWithFormat:@"Wi-Fi: not connected%@", test];
}

/* Menu and joining */

- (void) addInfo: (NSString *)title toMenu: (NSMenu *)menu
{
  [(NSMenuItem *)[menu addItemWithTitle:title action:NULL keyEquivalent:@""]
		 setEnabled:NO];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Wi-Fi"]);
  NSString *current = [self connected] || (_haveState && _state.ssid[0])
    ? [NSString stringWithUTF8String:_state.ssid] : nil;
  NSMenuItem *item;
  NSUInteger i;

  [menu setAutoenablesItems:NO];
  if ([self connected])
    {
      [self addInfo:[NSString stringWithFormat:@"Wi-Fi: %@", current]
	     toMenu:menu];
    }
  else
    {
      [self addInfo:current ? [NSString stringWithFormat:@"Wi-Fi: joining %@",
					current]
		    : @"Wi-Fi: not connected"
	     toMenu:menu];
    }
  if (current)
    {
      item = (NSMenuItem *)[menu addItemWithTitle:
				   [NSString stringWithFormat:@"Disconnect from %@",
					     current]
					   action:@selector(disconnect:)
				    keyEquivalent:@""];
      [item setTarget:self];
    }
  [menu addItem:[NSMenuItem separatorItem]];
  if (![_networks count])
    {
      [self addInfo:_scanTask ? @"Looking for networks…"
		    : @"No networks found" toMenu:menu];
    }
  for (i = 0; i < [_networks count]; i++)
    {
      NSDictionary *network = [_networks objectAtIndex:i];
      NSString *ssid = [network objectForKey:@"ssid"];
      NSString *security = [network objectForKey:@"security"];
      BOOL enterprise = [security isEqual:@"802.1X"];
      BOOL secured = ![security isEqual:@"open"];
      NSInteger bars = DockWiFiBars([[network objectForKey:@"rssi"] intValue]);

      item = (NSMenuItem *)[menu addItemWithTitle:
				   [NSString stringWithFormat:@"%@%@", ssid,
					     enterprise ? @"  (802.1X: use wlan(8))"
					     : (secured ? @"  (secured)" : @"")]
					   action:@selector(join:)
				    keyEquivalent:@""];
      [item setTarget:self];
      [item setRepresentedObject:network];
      [item setImage:DockWiFiSignalImage(bars)];
      [item setEnabled:!enterprise];
      [item setState:[ssid isEqual:current] ? NSOnState : NSOffState];
    }
  [menu addItem:[NSMenuItem separatorItem]];
  item = (NSMenuItem *)[menu addItemWithTitle:@"Scan Again"
				       action:@selector(scanAgain:)
				keyEquivalent:@""];
  [item setTarget:self];
  [item setEnabled:!_scanTask && !_testData];
  /* Next time, the list is fresh. */
  if (!_scanDate || -[_scanDate timeIntervalSinceNow] > DockWiFiRescanAge)
    {
      [self scan];
    }
  return menu;
}

- (void) scanAgain: (id)sender
{
  [self scan];
}

- (void) commandFinished: (NSDictionary *)result
{
  if ([[result objectForKey:@"status"] intValue] != 0)
    {
      NSString *message = AUTORELEASE([[NSString alloc]
					initWithData:[result objectForKey:@"error"]
					    encoding:NSUTF8StringEncoding]);

      NSRunAlertPanel(@"Wi-Fi", @"%@", @"OK", nil, nil,
		      [message length] ? message : @"wlan(8) failed.");
    }
  [self readState];
}

- (void) disconnect: (id)sender
{
  if (_testData || ![self interfaceName])
    {
      return;
    }
  [self runWlan:[NSArray arrayWithObjects:@"disconnect", [self interfaceName],
			 nil]
	 notify:@selector(commandFinished:)];
}

- (void) connectTo: (NSString *)ssid passphrase: (NSString *)passphrase
{
  if (_testData || ![self interfaceName])
    {
      return;
    }
  /* wlan connect <ssid> [passphrase] [interface]; an empty passphrase
   * joins an open network. */
  [self runWlan:[NSArray arrayWithObjects:@"connect", ssid,
			 passphrase ? passphrase : @"", [self interfaceName],
			 nil]
	 notify:@selector(commandFinished:)];
}

- (void) makePasswordPanel
{
  NSView *content;
  NSButton *button;

  _passwordPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 120)
					      styleMask:NSTitledWindowMask
						backing:NSBackingStoreBuffered
						  defer:NO];
  [_passwordPanel setTitle:@"Join Wi-Fi Network"];
  [_passwordPanel setReleasedWhenClosed:NO];
  [_passwordPanel setFloatingPanel:YES];
  content = [_passwordPanel contentView];

  _passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 82, 288, 22)];
  [_passwordLabel setEditable:NO];
  [_passwordLabel setSelectable:NO];
  [_passwordLabel setBezeled:NO];
  [_passwordLabel setDrawsBackground:NO];
  [content addSubview:_passwordLabel];

  _passwordField = [[NSSecureTextField alloc]
		     initWithFrame:NSMakeRect(16, 52, 288, 24)];
  [_passwordField setTarget:self];
  [_passwordField setAction:@selector(joinWithPassword:)];
  [content addSubview:_passwordField];

  button = AUTORELEASE([[NSButton alloc] initWithFrame:NSMakeRect(224, 12, 80, 28)]);
  [button setTitle:@"Join"];
  [button setBezelStyle:NSRoundedBezelStyle];
  [button setKeyEquivalent:@"\r"];
  [button setTarget:self];
  [button setAction:@selector(joinWithPassword:)];
  [content addSubview:button];

  button = AUTORELEASE([[NSButton alloc] initWithFrame:NSMakeRect(136, 12, 80, 28)]);
  [button setTitle:@"Cancel"];
  [button setBezelStyle:NSRoundedBezelStyle];
  [button setKeyEquivalent:@"\e"];
  [button setTarget:self];
  [button setAction:@selector(cancelPassword:)];
  [content addSubview:button];
}

- (void) join: (id)sender
{
  NSDictionary *network = [sender representedObject];
  NSString *ssid = [network objectForKey:@"ssid"];

  if ([[network objectForKey:@"security"] isEqual:@"open"])
    {
      [self connectTo:ssid passphrase:nil];
      return;
    }
  if (!_passwordPanel)
    {
      [self makePasswordPanel];
    }
  ASSIGN(_joiningSSID, ssid);
  [_passwordLabel setStringValue:
		    [NSString stringWithFormat:@"The passphrase for “%@”:",
			      ssid]];
  [_passwordField setStringValue:@""];
  [_passwordPanel setFrame:[_host dockExtra:self
			    panelFrameForSize:[_passwordPanel frame].size]
		   display:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [_passwordPanel makeKeyAndOrderFront:self];
  [_passwordPanel makeFirstResponder:_passwordField];
}

- (void) joinWithPassword: (id)sender
{
  NSString *passphrase = [_passwordField stringValue];

  if ([passphrase length] < 8 || [passphrase length] > 63)
    {
      NSBeep();
      return;
    }
  [_passwordPanel orderOut:self];
  [self connectTo:_joiningSSID passphrase:passphrase];
  [_passwordField setStringValue:@""];
  DESTROY(_joiningSSID);
}

- (void) cancelPassword: (id)sender
{
  [_passwordPanel orderOut:self];
  [_passwordField setStringValue:@""];
  DESTROY(_joiningSSID);
}

@end
