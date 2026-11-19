/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Built without GNUstep's headers: see the GNUmakefile.
 *
 * Copied unchanged (but for the dynamic store's name) from Bluetooth.app
 * (nextbsd/apps-settings Bluetooth/BTClient.c, 49499c3): the Bluetooth
 * Dock extra talks to bluetoothd the same way. Copy it again when the
 * app's grows.
 */

#include "bluetooth_mig_types.h"

#include <mach/mach.h>
#include <servers/bootstrap.h>

#include "bluetoothUser.h"		/* MIG user stubs, made by the build */

#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "BTClient.h"

#define BTServiceName "org.nextbsd.bluetooth"
#define BTStateKey "State:/Bluetooth"
#define BTPairingPattern "State:/Bluetooth/Pairing/.*"
#define BTPrefsPath \
  "/Local/Library/Preferences/SystemConfiguration/org.nextbsd.Bluetooth.plist"

/*
 * NextBSD's <notify.h> needs <os/base.h>, which isn't installed, so the
 * two calls used are declared here, as the Dock extras do
 * (apps-dock Extras/Common/DockExtraNotify.h).
 */
extern uint32_t notify_register_dispatch (const char *name, int *out_token,
                                          dispatch_queue_t queue,
                                          void (^handler) (int token));
extern uint32_t notify_cancel (int token);

/* bluetoothd's notify(3) names (btstate.h). */
static const char *const BTNotifyNames[] = {
  "org.nextbsd.bluetooth.adapter",
  "org.nextbsd.bluetooth.scan",
  "org.nextbsd.bluetooth.pairing",
  "org.nextbsd.bluetooth.device",
  "org.nextbsd.bluetooth.firmware",
  "org.nextbsd.bluetooth.audio",
};
#define BTNotifyCount (sizeof (BTNotifyNames) / sizeof (BTNotifyNames[0]))

struct BTClient
{
  mach_port_t service;
  int wakeFD;
  dispatch_queue_t queue;
  int tokens[BTNotifyCount];
  SCDynamicStoreRef store;
  CFDictionaryRef paired;	/* PairedDevices, read with the paired list */
};

static void
BTWake (int fd)
{
  char byte = 1;

  (void) write (fd, &byte, 1);
}

static void
BTStoreChanged (SCDynamicStoreRef store, CFArrayRef keys, void *info)
{
  (void) store;
  (void) keys;
  BTWake ((int) (intptr_t) info);
}

/* bluetoothd's port, looked up again after it went away. */
static mach_port_t
BTService (BTClient *c)
{
  mach_port_t port = MACH_PORT_NULL;

  if (c->service != MACH_PORT_NULL)
    return c->service;
  if (bootstrap_look_up (bootstrap_port, BTServiceName, &port)
      == KERN_SUCCESS)
    c->service = port;
  return c->service;
}

static void
BTLost (BTClient *c)
{
  if (c->service != MACH_PORT_NULL)
    (void) mach_port_deallocate (mach_task_self (), c->service);
  c->service = MACH_PORT_NULL;
}

/* One RPC: `expr` uses `svc`, and sets `st` unless it has no status. */
#define BTCall(c, expr)                         \
  do                                            \
    {                                           \
      mach_port_t svc = BTService (c);          \
      if (svc == MACH_PORT_NULL)                \
        return BTStatusRPCFailed;               \
      if ((expr) != KERN_SUCCESS)               \
        {                                       \
          BTLost (c);                           \
          return BTStatusRPCFailed;             \
        }                                       \
    }                                           \
  while (0)

static void
BTCopyAddress (BTAddressString out, const char *address)
{
  memset (out, 0, sizeof (BTAddressString));
  if (address != NULL)
    strlcpy (out, address, sizeof (BTAddressString));
}

BTClient *
BTClientOpen (int wakeFD)
{
  BTClient *c = calloc (1, sizeof (*c));
  SCDynamicStoreContext context = { 0, (void *) (intptr_t) wakeFD,
                                    NULL, NULL, NULL };
  CFArrayRef keys, patterns;
  CFStringRef key, pattern;
  size_t i;

  if (c == NULL)
    abort ();
  c->wakeFD = wakeFD;
  c->queue = dispatch_queue_create ("org.nextbsd.Bluetooth.notify", NULL);
  for (i = 0; i < BTNotifyCount; i++)
    {
      c->tokens[i] = -1;
      if (notify_register_dispatch (BTNotifyNames[i], &c->tokens[i], c->queue,
                                    ^(int token) {
                                      (void) token;
                                      BTWake (wakeFD);
                                    }) != 0)
        c->tokens[i] = -1;
    }

  /* State:/Bluetooth and everything under it. Without configd the app
     still works, on the notifications alone. */
  c->store = SCDynamicStoreCreate (NULL, CFSTR ("DockWM Bluetooth"),
                                   BTStoreChanged, &context);
  if (c->store != NULL)
    {
      key = CFSTR (BTStateKey);
      pattern = CFSTR (BTStateKey "/.*");
      keys = CFArrayCreate (NULL, (const void **) &key, 1,
                            &kCFTypeArrayCallBacks);
      patterns = CFArrayCreate (NULL, (const void **) &pattern, 1,
                                &kCFTypeArrayCallBacks);
      if (!SCDynamicStoreSetNotificationKeys (c->store, keys, patterns)
          || !SCDynamicStoreSetDispatchQueue (c->store, c->queue))
        {
          /* Still readable; just not watched. */
        }
      CFRelease (keys);
      CFRelease (patterns);
    }
  (void) BTService (c);
  return c;
}

void
BTClientClose (BTClient *c)
{
  size_t i;

  if (c == NULL)
    return;
  for (i = 0; i < BTNotifyCount; i++)
    if (c->tokens[i] >= 0)
      notify_cancel (c->tokens[i]);
  if (c->store != NULL)
    {
      SCDynamicStoreSetDispatchQueue (c->store, NULL);
      CFRelease (c->store);
    }
  /* Wait out a handler already running, so wakeFD can be closed. */
  dispatch_sync (c->queue, ^{
  });
  dispatch_release (c->queue);
  if (c->paired != NULL)
    CFRelease (c->paired);
  BTLost (c);
  free (c);
}

int
BTClientReachable (BTClient *c)
{
  return BTService (c) != MACH_PORT_NULL;
}

/* ---- the controller ---- */

int
BTClientGetStatus (BTClient *c, BTClientStatus *s)
{
  bt_daemon_state_t state;

  memset (s, 0, sizeof (*s));
  BTCall (c, bt_status (svc, &state, &s->adapters, &s->paired, &s->power,
                        &s->discoverable, &s->autoconnect));
  s->daemonState = (int) state;
  return BTStatusSuccess;
}

int
BTClientGetAdapter (BTClient *c, BTClientAdapter *a)
{
  BTTransportName transport;
  bt_adapter_state_t state;
  bt_status_t st;
  int vendor, product, connectable, features;

  memset (a, 0, sizeof (*a));
  BTCall (c, bt_adapter_info (svc, 0, a->node, transport, &vendor, &product,
                              &state, a->address, a->name, &st));
  if (st != bt_status_success_e)
    return (int) st;
  a->state = (int) state;
  BTCall (c, bt_adapter_flags (svc, 0, &a->powered, &a->discoverable,
                               &connectable, &a->scanning, &features, &st));
  return (int) st;
}

int
BTClientSetPower (BTClient *c, int on)
{
  BTNodeName node;
  bt_status_t st;

  memset (node, 0, sizeof (node));
  BTCall (c, bt_adapter_power (svc, node, on, &st));
  return (int) st;
}

int
BTClientSetDiscoverable (BTClient *c, int on, int seconds)
{
  BTNodeName node;
  bt_status_t st;

  memset (node, 0, sizeof (node));
  BTCall (c, bt_adapter_discoverable (svc, node, on, seconds, &st));
  return (int) st;
}

/* ---- the pairing store's metadata ---- */

/* "AA:BB:CC:DD:EE:FF/random" -> "aa-bb-cc-dd-ee-ff-random", the
   PairedDevices key (BT_ADDR_FMT_KEY). */
static CFStringRef
BTCopyStoreKey (const char *address)
{
  char key[32];
  size_t i;

  for (i = 0; address[i] != '\0' && i < sizeof (key) - 1; i++)
    key[i] = (address[i] == ':' || address[i] == '/')
      ? '-' : (char) tolower ((unsigned char) address[i]);
  key[i] = '\0';
  return CFStringCreateWithCString (NULL, key, kCFStringEncodingUTF8);
}

/* Read PairedDevices again. A missing file (nothing paired yet) is an
   empty store, as bluetoothd treats it. */
static void
BTReadPairedDevices (BTClient *c)
{
  CFDataRef data = NULL;
  CFPropertyListRef plist = NULL;
  CFTypeRef devices;
  FILE *f;
  char buffer[8192];
  size_t n;
  CFMutableDataRef bytes = CFDataCreateMutable (NULL, 0);

  if (c->paired != NULL)
    CFRelease (c->paired);
  c->paired = NULL;
  if (bytes == NULL)
    return;
  if ((f = fopen (BTPrefsPath, "r")) != NULL)
    {
      while ((n = fread (buffer, 1, sizeof (buffer), f)) > 0)
        CFDataAppendBytes (bytes, (const UInt8 *) buffer, (CFIndex) n);
      fclose (f);
      data = bytes;
      plist = CFPropertyListCreateWithData (NULL, data, kCFPropertyListImmutable,
                                            NULL, NULL);
    }
  CFRelease (bytes);
  if (plist == NULL)
    return;
  if (CFGetTypeID (plist) == CFDictionaryGetTypeID ())
    {
      devices = CFDictionaryGetValue ((CFDictionaryRef) plist,
                                      CFSTR ("PairedDevices"));
      if (devices != NULL && CFGetTypeID (devices) == CFDictionaryGetTypeID ())
        c->paired = CFRetain (devices);
    }
  CFRelease (plist);
}

static int
BTDictInt (CFDictionaryRef d, CFStringRef key, int otherwise)
{
  CFTypeRef v = CFDictionaryGetValue (d, key);
  int result = otherwise;

  if (v != NULL && CFGetTypeID (v) == CFBooleanGetTypeID ())
    result = CFBooleanGetValue ((CFBooleanRef) v) ? 1 : 0;
  else if (v != NULL && CFGetTypeID (v) == CFNumberGetTypeID ())
    CFNumberGetValue ((CFNumberRef) v, kCFNumberIntType, &result);
  return result;
}

static void
BTFillFromStore (BTClient *c, BTClientDevice *d)
{
  CFStringRef key;
  CFTypeRef entry = NULL;

  d->audio = 1;			/* absent means on (btstore.h) */
  if (c->paired == NULL || (key = BTCopyStoreKey (d->address)) == NULL)
    return;
  entry = CFDictionaryGetValue (c->paired, key);
  CFRelease (key);
  if (entry == NULL || CFGetTypeID (entry) != CFDictionaryGetTypeID ())
    return;
  d->audio = BTDictInt ((CFDictionaryRef) entry, CFSTR ("Audio"), 1);
  d->appearance = BTDictInt ((CFDictionaryRef) entry, CFSTR ("Appearance"), 0);
}

/* ---- devices ---- */

int
BTClientPairedCount (BTClient *c, int *count)
{
  bt_status_t st;

  *count = 0;
  BTCall (c, bt_paired_count (svc, count, &st));
  BTReadPairedDevices (c);
  return (int) st;
}

int
BTClientPairedEntry (BTClient *c, int index, BTClientDevice *d)
{
  bt_device_state_t state;
  bt_status_t st;

  memset (d, 0, sizeof (*d));
  BTCall (c, bt_paired_entry (svc, index, d->address, d->name,
                              &d->classOfDevice, &d->transports, d->profiles,
                              &d->autoconnect, &state, &st));
  d->state = (int) state;
  d->paired = 1;
  d->rssi = 127;
  BTFillFromStore (c, d);
  return (int) st;
}

int
BTClientScan (BTClient *c, int seconds)
{
  BTNodeName node;
  bt_status_t st;

  memset (node, 0, sizeof (node));
  BTCall (c, bt_scan (svc, node, seconds, &st));
  return (int) st;
}

int
BTClientScanCount (BTClient *c, int *count, int *scanning)
{
  BTNodeName node;
  bt_status_t st;

  *count = *scanning = 0;
  memset (node, 0, sizeof (node));
  BTCall (c, bt_scan_count (svc, node, count, scanning, &st));
  return (int) st;
}

int
BTClientScanEntry (BTClient *c, int index, BTClientDevice *d)
{
  BTNodeName node;
  bt_status_t st;

  memset (d, 0, sizeof (*d));
  memset (node, 0, sizeof (node));
  BTCall (c, bt_scan_entry (svc, node, index, d->address, d->name,
                            &d->classOfDevice, &d->rssi, &d->transports,
                            &d->appearance, &d->paired, &d->age, &st));
  return (int) st;
}

#ifdef BT_FAKE_PAIRING
/*
 * A test build (gmake fake_pairing=yes) for trying the pairing panel
 * without a device in pairing mode. With BT_FAKE_PAIRING set to a
 * bt_pair_method_t (1 just works ... 5 PIN), a made-up device,
 * 00:11:22:33:44:55, asks to pair as soon as the window opens, and
 * answers as bluetoothd would: the passkey is 123456, the PIN 0000,
 * any other answer is refused; a passkey shown on the computer is
 * "typed" on the device after 8 seconds. Never installed.
 */
#include <time.h>

#define BTFakeAddress "00:11:22:33:44:55"

static int BTFakeMethod = -1;
static int BTFakeState;
static int BTFakeResult;
static double BTFakeStarted, BTFakeAnswered;

static double
BTFakeNow (void)
{
  struct timespec ts;

  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Whether this call is the fake device's. */
static int
BTFake (const char *address)
{
  if (BTFakeMethod < 0)
    {
      const char *env = getenv ("BT_FAKE_PAIRING");

      BTFakeMethod = env != NULL ? atoi (env) : 0;
      if (BTFakeMethod < 1 || BTFakeMethod > 5)
        BTFakeMethod = 0;
      BTFakeState = BTFakeMethod != 0 ? BTPairWaiting : BTPairNone;
      BTFakeStarted = BTFakeNow ();
    }
  return BTFakeMethod != 0
    && (address == NULL || strcasecmp (address, BTFakeAddress) == 0);
}

static int
BTFakeStatus (int *state, int *method, int *passkey, int *expires,
              int *result)
{
  double now = BTFakeNow ();

  if (BTFakeState == BTPairPending && now - BTFakeAnswered >= 1.5)
    BTFakeState = BTFakeResult == 0 ? BTPairSucceeded : BTPairFailed;
  if (BTFakeState == BTPairWaiting && BTFakeMethod == BTMethodPasskeyDisplay
      && now - BTFakeStarted >= 8)
    {
      BTFakeState = BTPairPending;
      BTFakeAnswered = now;
    }
  if (BTFakeState == BTPairWaiting && now - BTFakeStarted >= 60)
    {
      BTFakeState = BTPairFailed;
      BTFakeResult = 12;	/* timed out */
    }
  *state = BTFakeState;
  *method = BTFakeMethod;
  *passkey = 123456;
  *expires = (int) (60 - (now - BTFakeStarted));
  *result = BTFakeResult;
  return BTStatusSuccess;
}

static int
BTFakeConfirm (int accept, int passkey, const char *pin)
{
  if (BTFakeState != BTPairWaiting)
    return BTStatusNoPrompt;
  if (!accept)
    {
      BTFakeState = BTPairNone;
      return BTStatusSuccess;
    }
  if ((BTFakeMethod == BTMethodPasskeyEntry && passkey != 123456)
      || (BTFakeMethod == BTMethodPIN
          && (pin == NULL || strcmp (pin, "0000") != 0)))
    BTFakeResult = 13;		/* rejected */
  BTFakeState = BTPairPending;
  BTFakeAnswered = BTFakeNow ();
  return BTStatusSuccess;
}
#endif

/* ---- pairing ---- */

int
BTClientPair (BTClient *c, const char *address, const char *pin)
{
  BTAddressString addr;
  BTPinString p;
  bt_status_t st;

#ifdef BT_FAKE_PAIRING
  if (BTFake (address))
    return BTStatusSuccess;
#endif
  BTCopyAddress (addr, address);
  memset (p, 0, sizeof (p));
  if (pin != NULL)
    strlcpy (p, pin, sizeof (p));
  BTCall (c, bt_pair (svc, addr, p, &st));
  memset (p, 0, sizeof (p));
  return (int) st;
}

int
BTClientPairStatus (BTClient *c, const char *address, int *state,
                    int *method, int *passkey, int *expires, int *result)
{
  BTAddressString addr;
  bt_pair_state_t pstate;
  bt_pair_method_t pmethod;
  bt_status_t presult, st;

#ifdef BT_FAKE_PAIRING
  if (BTFake (address))
    return BTFakeStatus (state, method, passkey, expires, result);
#endif
  BTCopyAddress (addr, address);
  BTCall (c, bt_pair_status (svc, addr, &pstate, &pmethod, passkey, expires,
                             &presult, &st));
  *state = (int) pstate;
  *method = (int) pmethod;
  *result = (int) presult;
  return (int) st;
}

int
BTClientPairConfirm (BTClient *c, const char *address, int accept,
                     int passkey, const char *pin)
{
  BTAddressString addr;
  BTPinString p;
  bt_status_t st;

#ifdef BT_FAKE_PAIRING
  if (BTFake (address))
    return BTFakeConfirm (accept, passkey, pin);
#endif
  BTCopyAddress (addr, address);
  memset (p, 0, sizeof (p));
  if (pin != NULL)
    strlcpy (p, pin, sizeof (p));
  BTCall (c, bt_pair_confirm (svc, addr, accept, passkey, p, &st));
  memset (p, 0, sizeof (p));
  return (int) st;
}

int
BTClientWaitingPrompts (BTClient *c, char addresses[][32], int max)
{
  CFArrayRef keys;
  CFIndex i, count;
  int n = 0;

#ifdef BT_FAKE_PAIRING
  if (BTFake (NULL) && BTFakeState == BTPairWaiting && n < max)
    strlcpy (addresses[n++], BTFakeAddress, 32);
#endif
  if (c->store == NULL)
    return n;
  keys = SCDynamicStoreCopyKeyList (c->store, CFSTR (BTPairingPattern));
  if (keys == NULL)
    return n;
  count = CFArrayGetCount (keys);
  for (i = 0; i < count && n < max; i++)
    {
      CFPropertyListRef value = SCDynamicStoreCopyValue (
          c->store, CFArrayGetValueAtIndex (keys, i));
      CFTypeRef address;

      if (value == NULL)
        continue;
      if (CFGetTypeID (value) == CFDictionaryGetTypeID ()
          && (address = CFDictionaryGetValue ((CFDictionaryRef) value,
                                              CFSTR ("Address"))) != NULL
          && CFGetTypeID (address) == CFStringGetTypeID ()
          && CFStringGetCString ((CFStringRef) address, addresses[n], 32,
                                 kCFStringEncodingUTF8))
        n++;
      CFRelease (value);
    }
  CFRelease (keys);
  return n;
}

/* ---- one device ---- */

int
BTClientUnpair (BTClient *c, const char *address)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_unpair (svc, addr, &st));
  return (int) st;
}

int
BTClientConnect (BTClient *c, const char *address)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_connect (svc, addr, &st));
  return (int) st;
}

int
BTClientDisconnect (BTClient *c, const char *address)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_disconnect (svc, addr, &st));
  return (int) st;
}

int
BTClientSetAutoconnect (BTClient *c, const char *address, int on)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_device_autoconnect (svc, addr, on, &st));
  return (int) st;
}

/* ---- audio ---- */

int
BTClientAudioCount (BTClient *c, int *count)
{
  bt_status_t st;

  *count = 0;
  BTCall (c, bt_audio_count (svc, count, &st));
  return (int) st;
}

int
BTClientAudioEntry (BTClient *c, int index, BTClientAudio *a)
{
  bt_status_t st;
  int avrcp, defaultOut;

  memset (a, 0, sizeof (*a));
  BTCall (c, bt_audio_entry (svc, index, a->address, &a->role, &a->route,
                             &a->active, &avrcp, &defaultOut, &a->volume,
                             a->node, a->codec, &st));
  return (int) st;
}

int
BTClientSetAudio (BTClient *c, const char *address, int on)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_audio_set (svc, addr, on, &st));
  return (int) st;
}

int
BTClientSetAudioRoute (BTClient *c, const char *address, int route)
{
  BTAddressString addr;
  bt_status_t st;

  BTCopyAddress (addr, address);
  BTCall (c, bt_audio_route (svc, addr, route, &st));
  return (int) st;
}

int
BTClientGetHandsFree (BTClient *c, const char *address, BTClientHandsFree *h)
{
  BTAddressString addr;
  BTTransportName codec;
  BTNodeName device;
  bt_status_t st;
  int features, speaker, mic;

  memset (h, 0, sizeof (*h));
  h->battery = -1;
  BTCopyAddress (addr, address);
  BTCall (c, bt_hfp_status (svc, addr, &h->connected, &h->microphone,
                            &h->pending, codec, device, &features, &speaker,
                            &mic, &h->battery, &st));
  return (int) st;
}
