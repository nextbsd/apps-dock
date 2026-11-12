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
 * The sound Dock extra: a speaker showing the volume and mute of the
 * default output, from the kernel's OSS mixer (/dev/mixer, which follows
 * the hw.snd.default_unit sysctl).
 *
 * A click opens a small panel with a volume slider, Mute and the output
 * device; the right-click menu has Mute, volume steps and the outputs.
 * Scrolling over the tile changes the volume.
 *
 * NextBSD has no devd and the mixer posts no change notification, so the
 * extra reads the mixer every 1.5 seconds (two ioctls on an open
 * descriptor) to follow changes from mixer(8) or other apps. With no
 * sound device it has no tile, and looks for one every 10 seconds.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <unistd.h>

#define DockSoundPollInterval 1.5
#define DockSoundSearchInterval 10.0
#define DockSoundStep 5

@interface DockSoundExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  int _mixer;
  int _unit;
  int _device;
  int _volume;
  BOOL _muted;
  NSTimer *_timer;
  NSPanel *_panel;
  NSSlider *_slider;
  NSButton *_muteButton;
  NSPopUpButton *_outputPopup;
}
- (void) update: (NSTimer *)timer;
- (void) setMuted: (BOOL)muted;
- (void) fillOutputPopup;
@end

static int
DockSoundDefaultUnit(void)
{
  int unit = -1;
  size_t length = sizeof(unit);

  if (sysctlbyname("hw.snd.default_unit", &unit, &length, NULL, 0) != 0)
    {
      return -1;
    }
  return unit;
}

/* The playback devices, from /dev/sndstat: dictionaries with unit
 * (NSNumber) and name. */
static NSArray *
DockSoundOutputs(void)
{
  NSMutableArray *outputs = [NSMutableArray array];
  NSMutableData *data = [NSMutableData data];
  NSString *status;
  NSArray *lines;
  NSUInteger i;
  char buffer[1024];
  ssize_t length;
  int fd;

  /* A device: its size is 0, so read it to the end by hand. */
  fd = open("/dev/sndstat", O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    {
      return outputs;
    }
  while ((length = read(fd, buffer, sizeof(buffer))) > 0)
    {
      [data appendBytes:buffer length:(NSUInteger)length];
    }
  close(fd);
  status = AUTORELEASE([[NSString alloc] initWithData:data
					     encoding:NSUTF8StringEncoding]);
  lines = [status componentsSeparatedByString:@"\n"];

  for (i = 0; i < [lines count]; i++)
    {
      NSString *line = [lines objectAtIndex:i];
      NSRange open = [line rangeOfString:@"<"];
      NSRange close = [line rangeOfString:@">"];
      int unit;

      if (![line hasPrefix:@"pcm"] || open.location == NSNotFound ||
	  close.location == NSNotFound || close.location < open.location ||
	  [line rangeOfString:@"play"].location == NSNotFound ||
	  sscanf([line UTF8String], "pcm%d:", &unit) != 1)
	{
	  continue;
	}
      [outputs addObject:
		 [NSDictionary dictionaryWithObjectsAndKeys:
				 [NSNumber numberWithInt:unit], @"unit",
			       [line substringWithRange:
				       NSMakeRange(open.location + 1,
						   close.location - open.location - 1)],
			       @"name", nil]];
    }
  return outputs;
}

@implementation DockSoundExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      _host = host;
      _mixer = -1;
      _unit = -1;
      [self update:nil];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [_timer invalidate];
  DESTROY(_timer);
  [_panel close];
  DESTROY(_panel);
  DESTROY(_slider);
  DESTROY(_muteButton);
  DESTROY(_outputPopup);
  if (_mixer >= 0)
    {
      close(_mixer);
      _mixer = -1;
    }
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DEALLOC;
}

- (void) scheduleUpdate
{
  NSTimeInterval interval = _mixer >= 0 ? DockSoundPollInterval
    : DockSoundSearchInterval;

  if (_timer && [_timer timeInterval] == interval)
    {
      return;
    }
  [_timer invalidate];
  DESTROY(_timer);
  _timer = RETAIN([NSTimer timerWithTimeInterval:interval
					  target:self
					selector:@selector(update:)
					userInfo:nil
					 repeats:YES]);
  [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSDefaultRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:_timer
			       forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSModalPanelRunLoopMode];
}

/* Open /dev/mixer, which is the default unit's mixer, and pick its
 * master control (vol, or pcm where there is none). */
- (BOOL) openMixer
{
  int mask = 0;

  if (_mixer >= 0)
    {
      close(_mixer);
    }
  _mixer = open("/dev/mixer", O_RDWR | O_CLOEXEC);
  if (_mixer < 0)
    {
      return NO;
    }
  if (ioctl(_mixer, SOUND_MIXER_READ_DEVMASK, &mask) != 0 ||
      !(mask & (SOUND_MASK_VOLUME | SOUND_MASK_PCM)))
    {
      close(_mixer);
      _mixer = -1;
      return NO;
    }
  _device = (mask & SOUND_MASK_VOLUME) ? SOUND_MIXER_VOLUME : SOUND_MIXER_PCM;
  _unit = DockSoundDefaultUnit();
  return YES;
}

- (void) updateControls
{
  if (!_panel)
    {
      return;
    }
  [_slider setIntValue:_volume];
  [_muteButton setState:_muted ? NSOnState : NSOffState];
}

- (void) update: (NSTimer *)timer
{
  BOOL wasAvailable = _mixer >= 0;
  int level = 0;
  int mutes = 0;
  int volume;
  BOOL muted;

  if (_mixer >= 0 && DockSoundDefaultUnit() != _unit)
    {
      /* The default output changed: follow it. */
      [self openMixer];
    }
  else if (_mixer < 0)
    {
      [self openMixer];
    }
  if (_mixer >= 0 &&
      ioctl(_mixer, MIXER_READ(_device), &level) != 0)
    {
      /* The device went away. */
      close(_mixer);
      _mixer = -1;
    }
  [self scheduleUpdate];
  if ((_mixer >= 0) != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  if (_mixer < 0)
    {
      return;
    }
  if (ioctl(_mixer, SOUND_MIXER_READ_MUTE, &mutes) != 0)
    {
      mutes = 0;
    }
  volume = ((level & 0x7f) + ((level >> 8) & 0x7f)) / 2;
  muted = (mutes & (1 << _device)) != 0;
  if (volume != _volume || muted != _muted)
    {
      _volume = volume;
      _muted = muted;
      [self updateControls];
      [_host dockExtraNeedsDisplay:self];
    }
}

- (void) setVolume: (int)volume
{
  int level;

  if (_mixer < 0)
    {
      return;
    }
  volume = MAX(0, MIN(100, volume));
  level = volume | (volume << 8);
  if (ioctl(_mixer, MIXER_WRITE(_device), &level) != 0)
    {
      NSLog(@"Sound extra: can't set the volume (%s)", strerror(errno));
      return;
    }
  /* Changing the volume unmutes, as on macOS. */
  if (_muted)
    {
      [self setMuted:NO];
    }
  [self update:nil];
}

- (void) setMuted: (BOOL)muted
{
  int mutes = 0;

  if (_mixer < 0 || ioctl(_mixer, SOUND_MIXER_READ_MUTE, &mutes) != 0)
    {
      return;
    }
  mutes = muted ? (mutes | (1 << _device)) : (mutes & ~(1 << _device));
  if (ioctl(_mixer, SOUND_MIXER_WRITE_MUTE, &mutes) != 0)
    {
      NSLog(@"Sound extra: can't set mute (%s)", strerror(errno));
      return;
    }
  _muted = muted;
  [self updateControls];
  [_host dockExtraNeedsDisplay:self];
}

- (BOOL) isAvailable
{
  return _mixer >= 0;
}

/* A speaker, with up to three waves for the volume, or a cross when
 * muted. */
- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat s = NSWidth(plate);
  CGFloat x = NSMinX(plate) + s * 0.18;
  CGFloat y = NSMidY(plate);
  NSBezierPath *speaker = [NSBezierPath bezierPath];
  NSColor *white = DockExtraForegroundColor(NO);
  NSInteger waves = _muted || _volume == 0 ? 0
    : (_volume < 34 ? 1 : (_volume < 67 ? 2 : 3));
  NSInteger i;

  DockExtraDrawPlate(rect);
  [speaker moveToPoint:NSMakePoint(x, y - s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.12, y - s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.27, y - s * 0.22)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.27, y + s * 0.22)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.12, y + s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x, y + s * 0.09)];
  [speaker closePath];
  [(_muted ? DockExtraForegroundColor(YES) : white) set];
  [speaker fill];
  if (_muted)
    {
      NSBezierPath *cross = [NSBezierPath bezierPath];
      CGFloat cx = x + s * 0.47;
      CGFloat r = s * 0.11;

      [cross moveToPoint:NSMakePoint(cx - r, y - r)];
      [cross lineToPoint:NSMakePoint(cx + r, y + r)];
      [cross moveToPoint:NSMakePoint(cx - r, y + r)];
      [cross lineToPoint:NSMakePoint(cx + r, y - r)];
      [cross setLineWidth:MAX(1.5, s * 0.05)];
      [cross setLineCapStyle:NSRoundLineCapStyle];
      [white set];
      [cross stroke];
    }
  for (i = 0; i < 3; i++)
    {
      NSBezierPath *wave = [NSBezierPath bezierPath];
      CGFloat radius = s * (0.12 + 0.11 * i);

      [wave appendBezierPathWithArcWithCenter:NSMakePoint(x + s * 0.27, y)
				       radius:radius
				   startAngle:-45.0
				     endAngle:45.0];
      [wave setLineWidth:MAX(1.5, s * 0.05)];
      [wave setLineCapStyle:NSRoundLineCapStyle];
      if (i < waves)
	{
	  [white set];
	  [wave stroke];
	}
      else if (!_muted)
	{
	  [DockExtraForegroundColor(YES) set];
	  [wave stroke];
	}
    }
}

- (NSString *) toolTip
{
  if (_mixer < 0)
    {
      return @"No sound device";
    }
  return _muted ? [NSString stringWithFormat:@"Volume: muted (%d%%)", _volume]
    : [NSString stringWithFormat:@"Volume: %d%%", _volume];
}

- (void) scrollWheel: (NSEvent *)event
{
  CGFloat delta = [event deltaY];
  int steps = (int)MIN(4.0, MAX(1.0, rint(fabs(delta))));

  if (delta > 0.0)
    {
      [self setVolume:_volume + DockSoundStep * steps];
    }
  else if (delta < 0.0)
    {
      [self setVolume:_volume - DockSoundStep * steps];
    }
}

- (void) volumeChanged: (id)sender
{
  [self setVolume:[sender intValue]];
}

- (void) muteChanged: (id)sender
{
  [self setMuted:[sender state] == NSOnState];
}

- (void) toggleMute: (id)sender
{
  [self setMuted:!_muted];
}

- (void) chooseVolume: (id)sender
{
  [self setVolume:(int)[sender tag]];
}

/* Choosing the output sets hw.snd.default_unit, which needs root. */
- (void) chooseOutput: (id)sender
{
  int unit = (int)[([sender isKindOfClass:[NSPopUpButton class]]
		    ? [sender selectedItem] : sender) tag];

  if (unit == _unit)
    {
      return;
    }
  if (sysctlbyname("hw.snd.default_unit", NULL, NULL, &unit, sizeof(unit)) != 0)
    {
      NSLog(@"Sound extra: can't choose pcm%d as the output (%s)",
	    unit, strerror(errno));
      NSBeep();
    }
  [self update:nil];
  [self fillOutputPopup];
}

- (void) fillOutputPopup
{
  NSArray *outputs = DockSoundOutputs();
  NSUInteger i;

  [_outputPopup removeAllItems];
  for (i = 0; i < [outputs count]; i++)
    {
      NSDictionary *output = [outputs objectAtIndex:i];

      [_outputPopup addItemWithTitle:[output objectForKey:@"name"]];
      [[_outputPopup lastItem] setTag:[[output objectForKey:@"unit"] intValue]];
      if ([[output objectForKey:@"unit"] intValue] == _unit)
	{
	  [_outputPopup selectItem:[_outputPopup lastItem]];
	}
    }
  /* Only root can set hw.snd.default_unit for now. */
  [_outputPopup setEnabled:[outputs count] > 1 && geteuid() == 0];
}

- (void) makePanel
{
  NSView *content;
  NSTextField *label;

  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 118)
				      styleMask:NSTitledWindowMask
					     | NSClosableWindowMask
					     | NSUtilityWindowMask
					backing:NSBackingStoreBuffered
					  defer:NO];
  [_panel setTitle:@"Sound"];
  [_panel setReleasedWhenClosed:NO];
  [_panel setHidesOnDeactivate:YES];
  [_panel setFloatingPanel:YES];
  content = [_panel contentView];

  label = AUTORELEASE([[NSTextField alloc]
			initWithFrame:NSMakeRect(12, 86, 216, 18)]);
  [label setStringValue:@"Output volume"];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [content addSubview:label];

  _slider = [[NSSlider alloc] initWithFrame:NSMakeRect(12, 62, 216, 22)];
  [_slider setMinValue:0.0];
  [_slider setMaxValue:100.0];
  [_slider setContinuous:YES];
  [_slider setTarget:self];
  [_slider setAction:@selector(volumeChanged:)];
  [content addSubview:_slider];

  _muteButton = [[NSButton alloc] initWithFrame:NSMakeRect(12, 38, 216, 22)];
  [_muteButton setButtonType:NSSwitchButton];
  [_muteButton setTitle:@"Mute"];
  [_muteButton setTarget:self];
  [_muteButton setAction:@selector(muteChanged:)];
  [content addSubview:_muteButton];

  _outputPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(10, 8, 220, 26)
					    pullsDown:NO];
  [_outputPopup setTarget:self];
  [_outputPopup setAction:@selector(chooseOutput:)];
  [_outputPopup setToolTip:@"The output device (hw.snd.default_unit). "
		@"Choosing another one needs administrator rights."];
  [content addSubview:_outputPopup];
}

- (void) showPanel
{
  if ([_panel isVisible])
    {
      [_panel orderOut:self];
      return;
    }
  if (!_panel)
    {
      [self makePanel];
    }
  [self fillOutputPopup];
  [self updateControls];
  [_panel setFrame:[_host dockExtra:self panelFrameForSize:[_panel frame].size]
	   display:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [_panel makeKeyAndOrderFront:self];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu;
  NSMenu *outputs;
  NSMenuItem *item;
  NSArray *devices;
  NSUInteger i;
  int steps[] = { 0, 25, 50, 75, 100 };

  if ([event type] == NSLeftMouseDown)
    {
      [self showPanel];
      return nil;
    }
  menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Sound"]);
  [menu setAutoenablesItems:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:[self toolTip] action:NULL
				 keyEquivalent:@""];
  [item setEnabled:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:@"Mute"
				       action:@selector(toggleMute:)
				keyEquivalent:@""];
  [item setTarget:self];
  [item setState:_muted ? NSOnState : NSOffState];
  [menu addItem:[NSMenuItem separatorItem]];
  for (i = 0; i < sizeof(steps) / sizeof(steps[0]); i++)
    {
      item = (NSMenuItem *)[menu addItemWithTitle:
				   [NSString stringWithFormat:@"Volume %d%%",
					     steps[i]]
					   action:@selector(chooseVolume:)
				    keyEquivalent:@""];
      [item setTarget:self];
      [item setTag:steps[i]];
      [item setState:!_muted && abs(_volume - steps[i]) < 13
	    ? NSOnState : NSOffState];
    }
  devices = DockSoundOutputs();
  if ([devices count])
    {
      [menu addItem:[NSMenuItem separatorItem]];
      outputs = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Output"]);
      [outputs setAutoenablesItems:NO];
      for (i = 0; i < [devices count]; i++)
	{
	  NSDictionary *device = [devices objectAtIndex:i];
	  int unit = [[device objectForKey:@"unit"] intValue];

	  item = (NSMenuItem *)[outputs addItemWithTitle:[device objectForKey:@"name"]
						  action:@selector(chooseOutput:)
					   keyEquivalent:@""];
	  [item setTarget:self];
	  [item setTag:unit];
	  [item setState:unit == _unit ? NSOnState : NSOffState];
	  [item setEnabled:geteuid() == 0 || unit == _unit];
	}
      item = (NSMenuItem *)[menu addItemWithTitle:@"Output" action:NULL
				    keyEquivalent:@""];
      [menu setSubmenu:outputs forItem:item];
    }
  return menu;
}

@end
