/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * BTClient: Bluetooth's connection to bluetoothd (org.nextbsd.bluetooth),
 * as a plain C interface, so the app itself needn't see Mach's or
 * CoreFoundation's headers (GNUstep has its own; see the GNUmakefile).
 *
 *   - The calls are bluetoothd's MIG routines (mig/bluetooth.defs), made
 *     the way bluetooth(8) makes them. Each returns a bt_status_t value
 *     (BTStatus*), or BTStatusRPCFailed when bluetoothd can't be reached;
 *     the next call looks it up again, so a restarted bluetoothd is found.
 *   - Live updates: every org.nextbsd.bluetooth.* notification and every
 *     change under State:/Bluetooth in the dynamic store writes a byte to
 *     the wake descriptor given to BTClientOpen. They arrive on dispatch
 *     queues; the app watches the pipe on its run loop.
 *   - What MIG doesn't say: the prompts waiting for an answer
 *     (State:/Bluetooth/Pairing/<addr>), and a paired device's Audio
 *     switch and LE appearance, from the pairing store's metadata
 *     (org.nextbsd.Bluetooth.plist, readable by everyone).
 */

#ifndef _BT_CLIENT_H_
#define _BT_CLIENT_H_

/* bt_status_t (mig/bluetooth_mig_types.h), and the RPC itself failing. */
#define BTStatusSuccess 0
#define BTStatusPoweredOff 6
#define BTStatusNotConnected 9
#define BTStatusNoPrompt 14
#define BTStatusRPCFailed (-1)

/* bt_device_state_t */
#define BTDeviceDisconnected 0
#define BTDeviceConnecting 1
#define BTDeviceConnected 2
#define BTDevicePairing 3

/* bt_pair_state_t and bt_pair_method_t */
#define BTPairNone 0
#define BTPairPending 1
#define BTPairWaiting 2
#define BTPairSucceeded 3
#define BTPairFailed 4

#define BTMethodJustWorks 1
#define BTMethodNumericComparison 2
#define BTMethodPasskeyEntry 3
#define BTMethodPasskeyDisplay 4
#define BTMethodPIN 5

/* bt_adapter_state_t */
#define BTAdapterArrived 0
#define BTAdapterFirmware 1
#define BTAdapterInitializing 2
#define BTAdapterOn 3
#define BTAdapterOff 4
#define BTAdapterError 5

/* bt_audio_route (31085): stereo, or the headset's microphone open. */
#define BTRouteA2DP 1
#define BTRouteHFP 2

typedef struct BTClient BTClient;

typedef struct
{
  int daemonState;		/* bt_daemon_state_t */
  int adapters;
  int paired;
  int power;			/* ControllerPowerState */
  int discoverable;		/* DiscoverableState, the persisted one */
  int autoconnect;
} BTClientStatus;

typedef struct
{
  char node[32];
  char address[32];
  char name[249];
  int state;			/* BTAdapter* */
  int powered;
  int discoverable;		/* right now, timed or not */
  int scanning;
} BTClientAdapter;

typedef struct
{
  char address[32];		/* "AA:BB:CC:DD:EE:FF", "/random" for LE */
  char name[249];
  char profiles[128];		/* "HID,A2DPSink" */
  int classOfDevice;
  int appearance;		/* LE GAP appearance, 0 if none */
  int transports;		/* 1 BR/EDR, 2 LE */
  int paired;
  int state;			/* BTDevice* */
  int autoconnect;
  int audio;			/* PairedDevices/<addr>/Audio, default on */
  int rssi;			/* dBm, 127 unknown */
  int age;			/* seconds since a scan saw it */
} BTClientDevice;

typedef struct
{
  char address[32];
  int role;			/* 1 we play to it, 2 it plays to us */
  int route;			/* BTRoute* */
  int active;
  int volume;			/* 0-127, -1 unknown */
  char node[32];		/* "dsp.bt0" */
  char codec[16];
} BTClientAudio;

typedef struct
{
  int connected;		/* the hands-free channel is up */
  int microphone;		/* its SCO link is up */
  int pending;
  int battery;			/* percent, -1 unknown */
} BTClientHandsFree;

/* Look bluetoothd up and start watching it; wakeFD gets a byte per
   change. Never NULL; BTClientReachable says whether it answered. */
BTClient *BTClientOpen (int wakeFD);
void BTClientClose (BTClient *client);
int BTClientReachable (BTClient *client);

int BTClientGetStatus (BTClient *client, BTClientStatus *status);
/* The first controller, the one the app shows. */
int BTClientGetAdapter (BTClient *client, BTClientAdapter *adapter);
int BTClientSetPower (BTClient *client, int on);
/* seconds > 0: timed and not persisted (bluetooth.defs 31004). */
int BTClientSetDiscoverable (BTClient *client, int on, int seconds);

int BTClientPairedCount (BTClient *client, int *count);
int BTClientPairedEntry (BTClient *client, int index, BTClientDevice *device);
int BTClientScan (BTClient *client, int seconds);
int BTClientScanCount (BTClient *client, int *count, int *scanning);
int BTClientScanEntry (BTClient *client, int index, BTClientDevice *device);

int BTClientPair (BTClient *client, const char *address, const char *pin);
int BTClientPairStatus (BTClient *client, const char *address, int *state,
                        int *method, int *passkey, int *expires, int *result);
int BTClientPairConfirm (BTClient *client, const char *address, int accept,
                         int passkey, const char *pin);
/* The addresses with a prompt waiting, from State:/Bluetooth/Pairing;
   returns how many (at most max). */
int BTClientWaitingPrompts (BTClient *client, char addresses[][32], int max);

int BTClientUnpair (BTClient *client, const char *address);
int BTClientConnect (BTClient *client, const char *address);
int BTClientDisconnect (BTClient *client, const char *address);
int BTClientSetAutoconnect (BTClient *client, const char *address, int on);

int BTClientAudioCount (BTClient *client, int *count);
int BTClientAudioEntry (BTClient *client, int index, BTClientAudio *audio);
int BTClientSetAudio (BTClient *client, const char *address, int on);
int BTClientSetAudioRoute (BTClient *client, const char *address, int route);
int BTClientGetHandsFree (BTClient *client, const char *address,
                          BTClientHandsFree *handsFree);

#endif
