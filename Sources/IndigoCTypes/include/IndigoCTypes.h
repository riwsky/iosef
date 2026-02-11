// Packed struct definitions matching Apple's private SimulatorKit IndigoHID format.
// Derived from class-dumping Simulator.app; field names from idb (MIT, Meta Platforms).

#ifndef INDIGO_C_TYPES_H
#define INDIGO_C_TYPES_H

#include <stdint.h>

#pragma pack(push, 4)

// Mirrors mach_msg_header_t layout
typedef struct {
    uint32_t msgh_bits;         // 0x0
    uint32_t msgh_size;         // 0x4
    uint32_t msgh_remote_port;  // 0x8
    uint32_t msgh_local_port;   // 0xc
    uint32_t msgh_voucher_port; // 0x10
    int32_t  msgh_id;           // 0x14
} IndigoMachHeader;  // 24 bytes

// Digitizer (touch) event. xRatio/yRatio are 0.0–1.0 from top-left.
typedef struct {
    uint32_t field1;   // 0x00
    uint32_t field2;   // 0x04
    uint32_t field3;   // 0x08
    double   xRatio;   // 0x0c
    double   yRatio;   // 0x14
    double   field6;   // 0x1c
    double   field7;   // 0x24
    double   field8;   // 0x2c
    uint32_t field9;   // 0x34  (touch down/up indicator)
    uint32_t field10;  // 0x38  (touch down/up indicator)
    uint32_t field11;  // 0x3c
    uint32_t field12;  // 0x40
    uint32_t field13;  // 0x44
    double   field14;  // 0x48
    double   field15;  // 0x50
    double   field16;  // 0x58
    double   field17;  // 0x60
    double   field18;  // 0x68
} IndigoTouch;  // 112 bytes (0x70)

// Hardware button event
typedef struct {
    uint32_t eventSource; // 0x00
    uint32_t eventType;   // 0x04
    uint32_t eventTarget; // 0x08
    uint32_t keyCode;     // 0x0c
    uint32_t field5;      // 0x10
} IndigoButton;  // 20 bytes (0x14)

// Game controller quad (equivalent to NSEdgeInsets, packed)
typedef struct {
    double field1;
    double field2;
    double field3;
    double field4;
} IndigoQuad;  // 32 bytes

// Game controller event (largest union member at 128 bytes)
typedef struct {
    IndigoQuad dpad;
    IndigoQuad face;
    IndigoQuad shoulder;
    IndigoQuad joystick;
} IndigoGameController;  // 128 bytes (0x80)

// Union of all event types. Sized by largest member (IndigoGameController = 128 bytes).
typedef union {
    IndigoTouch touch;
    IndigoButton button;
    IndigoGameController gameController;
    uint8_t _padding[128]; // ensure union is at least 128 bytes
} IndigoEvent;

// Payload embedded inside an IndigoMessage
typedef struct {
    uint32_t field1;        // +0x00
    uint64_t timestamp;     // +0x04  (mach_absolute_time)
    uint32_t field3;        // +0x0c
    IndigoEvent event;      // +0x10
} IndigoPayload;  // 144 bytes (0x90)

// The complete Indigo message
typedef struct {
    IndigoMachHeader header;  // 0x00 (24 bytes)
    uint32_t innerSize;       // 0x18
    uint8_t  eventType;       // 0x1c
    // 3 bytes implicit padding to reach 0x20
    IndigoPayload payload;    // 0x20
} IndigoMessage;  // 176 bytes (0xb0)

#pragma pack(pop)

// Event type constants
#define kIndigoEventTypeButton  1
#define kIndigoEventTypeTouch   2

// Direction constants (derived from NSEventTypeKeyDown/Up minus 10)
#define kIndigoDirectionDown    1
#define kIndigoDirectionUp      2

// Button source codes
#define kButtonSourceApplePay    0x1f4
#define kButtonSourceHomeButton  0x0
#define kButtonSourceLock        0x1
#define kButtonSourceKeyboard    0x2710
#define kButtonSourceSideButton  0xbb8
#define kButtonSourceSiri        0x400002

// Button target codes
#define kButtonTargetHardware    0x33
#define kButtonTargetKeyboard    0x64

// Touch message total size (IndigoMessage + extra IndigoPayload for duplicated payload)
#define kIndigoTouchMessageSize  (sizeof(IndigoMessage) + sizeof(IndigoPayload))

#endif // INDIGO_C_TYPES_H
