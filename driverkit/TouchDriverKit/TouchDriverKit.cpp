//
//  TouchDriverKit.cpp — implementation skeleton for the DriverKit HID dext.
//
//  STATUS: scaffold. The report-parsing in handleReport() is a TODO stub —
//  it must be filled in against the SiS panel's actual multi-touch report
//  layout (capture it once the dext is bound; the descriptor from
//  `touchdriver --inspect` shows: per-contact Tip(0x0D/0x42), ContactID
//  (0x0D/0x51), X(0x01/0x30), Y(0x01/0x31), plus ContactCount(0x0D/0x54)).
//

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOService.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <HIDDriverKit/IOHIDDeviceKeys.h>
#include <HIDDriverKit/IOHIDInterface.h>

#include "TouchDriverKit.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "TouchDriverKit: " fmt, ##__VA_ARGS__)

// Device Mode feature report: usage page 0x0D (Digitizer), usage 0x52.
// Value 3 = "multi-input device" mode (what Windows requests).
static const uint8_t kDeviceModeReportID = 0; // TODO: confirm real report ID
static const uint8_t kDeviceModeMultiInput = 3;

struct TouchDriverKit_IVars
{
    IOHIDInterface *interface = nullptr;
};

bool TouchDriverKit::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(TouchDriverKit_IVars, 1);
    return ivars != nullptr;
}

void TouchDriverKit::free()
{
    IOSafeDeleteNULL(ivars, TouchDriverKit_IVars, 1);
    super::free();
}

kern_return_t
IMPL(TouchDriverKit, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        LOG("super::Start failed: 0x%x", ret);
        return ret;
    }

    LOG("Start: claimed SiS HID Touch Controller.");

    // Flip the panel into multi-touch mode. If the firmware honors it over
    // DriverKit (unlike user space), subsequent input reports become
    // per-contact digitizer reports we can parse in handleReport().
    ret = enableMultitouchMode();
    if (ret != kIOReturnSuccess) {
        LOG("enableMultitouchMode failed: 0x%x (continuing; may still work)", ret);
    }

    // RegisterService so the system attaches and starts delivering reports.
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        LOG("RegisterService failed: 0x%x", ret);
    }
    return ret;
}

kern_return_t
IMPL(TouchDriverKit, Stop)
{
    LOG("Stop.");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t TouchDriverKit::enableMultitouchMode()
{
    // TODO: build the feature report buffer for usage 0x0D/0x52 = 3 and send it
    // via setReport(). The exact report ID and length come from the device's
    // feature-report descriptor. Pseudocode:
    //
    //   uint8_t buf[] = { kDeviceModeReportID, kDeviceModeMultiInput };
    //   IOMemoryDescriptor *md = ...wrap(buf)...;
    //   return setReport(md, kIOHIDReportTypeFeature, kDeviceModeReportID, 0, 0);
    //
    LOG("enableMultitouchMode: TODO (report ID=%u value=%u)",
        kDeviceModeReportID, kDeviceModeMultiInput);
    return kIOReturnUnsupported;
}

void TouchDriverKit::handleReport(uint64_t timestamp,
                                  uint8_t *report,
                                  uint32_t reportLength,
                                  IOHIDReportType type,
                                  uint32_t reportID)
{
    // TODO: parse multi-touch contacts out of `report` and dispatch them.
    //
    // Expected per-contact fields (from `touchdriver --inspect`):
    //   Tip Switch   page 0x0D usage 0x42  (finger down)
    //   Contact ID   page 0x0D usage 0x51
    //   X            page 0x01 usage 0x30  (logical 0..4095)
    //   Y            page 0x01 usage 0x31  (logical 0..4095)
    //   ContactCount page 0x0D usage 0x54  (fingers this frame)
    //
    // Once parsed, dispatch a digitizer event per contact so macOS routes it
    // as multi-touch (e.g. via dispatchDigitizerStylusEvent / the HID event
    // service's event-dispatch helpers).
    //
    // For now, hand the report to the default implementation so basic pointer
    // behavior keeps working while parsing is built out.
    super::handleReport(timestamp, report, reportLength, type, reportID);
}
