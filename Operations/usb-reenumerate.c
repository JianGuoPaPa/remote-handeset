// Targeted macOS USB recovery. No root, seize, phone reboot or key deletion.
// Build: clang -O2 -Wall -Wextra usb-reenumerate.c -framework IOKit
//        -framework CoreFoundation -o remote-handset-usb-reenumerate
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int string_property(io_registry_entry_t entry, CFStringRef key,
                           char *value, size_t capacity) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!property) return 0;
    int valid = CFGetTypeID(property) == CFStringGetTypeID() &&
        CFStringGetCString((CFStringRef)property, value, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(property);
    return valid ? 1 : -1;
}

static int integer_property_equals(io_registry_entry_t entry, CFStringRef key, int expected) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int actual = -1;
    int valid = property && CFGetTypeID(property) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)property, kCFNumberIntType, &actual);
    if (property) CFRelease(property);
    return valid && actual == expected;
}

static int serial_matches(io_registry_entry_t entry, const char *serial) {
    char actual[256] = {0};
    return string_property(entry, CFSTR("USB Serial Number"), actual, sizeof(actual)) == 1 &&
        strcmp(actual, serial) == 0;
}

static int unowned(io_registry_entry_t entry) {
    char owner[256] = {0};
    int present = string_property(entry, CFSTR("UsbExclusiveOwner"), owner, sizeof(owner));
    // A missing property and the explicit string "none" are distinct but both
    // occur on unclaimed interfaces. Never treat an invalid value as unowned.
    if (present != 0 && (present != 1 || strcasecmp(owner, "none") != 0)) return 0;
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) != KERN_SUCCESS) return 0;
    io_registry_entry_t child;
    int safe = 1;
    while ((child = IOIteratorNext(children))) {
        if (IOObjectConformsTo(child, "IOUserClient")) safe = 0;
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    return safe;
}

int main(int argc, char **argv) {
    if (argc != 3 || !argv[1][0] || strlen(argv[1]) >= 256) {
        fprintf(stderr, "usage: %s SERIAL EXPECTED_ADB_INTERFACE_REGISTRY_ID\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long expected = strtoull(argv[2], &end, 10);
    if (errno || !expected || !end || *end || argv[2][0] == '-') return 2;
    io_iterator_t interfaces = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostInterface"), &interfaces);
    if (kr != KERN_SUCCESS) return 3;
    io_service_t target = IO_OBJECT_NULL, item;
    unsigned matches = 0;
    while ((item = IOIteratorNext(interfaces))) {
        if (serial_matches(item, argv[1]) &&
            integer_property_equals(item, CFSTR("bInterfaceClass"), 255) &&
            integer_property_equals(item, CFSTR("bInterfaceSubClass"), 66) &&
            integer_property_equals(item, CFSTR("bInterfaceProtocol"), 1)) {
            matches++;
            if (!target) { target = item; continue; }
        }
        IOObjectRelease(item);
    }
    IOObjectRelease(interfaces);
    if (matches != 1 || !target) {
        fprintf(stderr, "refusing: exact ADB interface matches=%u\n", matches);
        if (target) IOObjectRelease(target);
        return 4;
    }
    uint64_t current = 0;
    kr = IORegistryEntryGetRegistryEntryID(target, &current);
    if (kr || current != expected || !unowned(target)) {
        fprintf(stderr, "refusing: generation changed or interface owned\n");
        IOObjectRelease(target);
        return 5;
    }
    io_registry_entry_t parent = IO_OBJECT_NULL;
    kr = IORegistryEntryGetParentEntry(target, kIOServicePlane, &parent);
    if (kr || !IOObjectConformsTo(parent, "IOUSBHostDevice") || !serial_matches(parent, argv[1])) {
        fprintf(stderr, "refusing: exact USB parent not found\n");
        IOObjectRelease(target);
        if (parent) IOObjectRelease(parent);
        return 6;
    }
    // Refuse to interrupt an MTP or other interface client on this same phone.
    io_iterator_t siblings = IO_OBJECT_NULL;
    int safe = IORegistryEntryGetChildIterator(parent, kIOServicePlane, &siblings) == KERN_SUCCESS;
    if (safe) {
        while ((item = IOIteratorNext(siblings))) {
            if (IOObjectConformsTo(item, "IOUSBHostInterface") && !unowned(item)) safe = 0;
            IOObjectRelease(item);
        }
        IOObjectRelease(siblings);
    }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kr = safe ? IOCreatePlugInInterfaceForService(parent, kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugin, &score) : kIOReturnExclusiveAccess;
    IOObjectRelease(parent);
    if (kr || !plugin) {
        fprintf(stderr, "device plugin: 0x%x\n", kr);
        IOObjectRelease(target);
        return 7;
    }
    IOUSBDeviceInterface187 **device = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187), (LPVOID *)&device);
    IODestroyPlugInInterface(plugin);
    if (hr || !device) {
        fprintf(stderr, "device interface: 0x%x\n", (unsigned)hr);
        IOObjectRelease(target);
        return 8;
    }
    kr = (*device)->USBDeviceOpen(device); // deliberately not USBDeviceOpenSeize
    if (kr) {
        fprintf(stderr, "device open: 0x%x\n", kr);
        IOObjectRelease(target);
        (*device)->Release(device);
        return 9;
    }
    uint64_t final_id = 0;
    kr = IORegistryEntryGetRegistryEntryID(target, &final_id);
    if (kr == KERN_SUCCESS && final_id == expected && unowned(target)) {
        kr = (*device)->USBDeviceReEnumerate(device, 0);
    } else {
        kr = kIOReturnExclusiveAccess;
    }
    printf("serial=%s interface=0x%llx reenumerate=0x%x\n", argv[1], expected, kr);
    IOObjectRelease(target);
    (*device)->USBDeviceClose(device);
    (*device)->Release(device);
    return kr ? 10 : 0;
}
