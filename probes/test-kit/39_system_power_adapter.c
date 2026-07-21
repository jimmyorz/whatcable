/*
 * 39_system_power_adapter.c - Dump the system power adapter and power-source
 * state via the IOKit power-sources (IOKit.ps) API.
 *
 * This captures the exact signal the stale-PDO charging fix (public #466)
 * gates on: IOPSCopyExternalPowerAdapterDetails() returns a details dictionary
 * (watts / voltage / current / adapter serial / family code) when an external
 * USB-PD adapter is attached, and nil otherwise. Note nil does NOT strictly
 * mean "on battery": Apple documents nil as "no external adapter details OR
 * error", and desktop Macs on AC also report nil. Use the providing-power-
 * source line below to tell AC from battery. No other probe samples the
 * adapter, so a corpus sweep can confirm a winning PD contract while
 * discharging but could not previously verify the adapter side of the fix.
 *
 * Also dumps the power-sources blob (IOPSCopyPowerSourcesInfo +
 * IOPSCopyPowerSourcesList + per-source IOPSGetPowerSourceDescription) and the
 * providing-power-source type, so one capture holds the whole system-power
 * picture (battery percentage, charging flags, AC/battery/UPS).
 *
 * System-wide, one call per run. Always prints something (the adapter status
 * line and power sources) even on battery, so the runner never sees it as
 * empty output.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 39_system_power_adapter 39_system_power_adapter.c
 */

#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { printf("%s(null)\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        buf[0] = '\0';
        if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "<unconvertible>");
        printf("%s\"%s\"\n", pad, buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%s%lld (0x%llx)\n", pad, num, (unsigned long long)num);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s%s\n", pad, CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("%sData[%ld]: ", pad, (long)len);
        for (CFIndex i = 0; i < len && i < 48; i++)
            printf("%02x ", bytes[i]);
        if (len > 48) printf("...");
        printf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(value);
        if (n <= 0) { printf("{}\n"); return; }
        const void **keys = malloc(n * sizeof(void*));
        const void **vals = malloc(n * sizeof(void*));
        if (!keys || !vals) {
            printf("<allocation failure printing %ld entries>\n", (long)n);
            free(keys); free(vals);
            return;
        }
        CFDictionaryGetKeysAndValues(value, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            char kbuf[256];
            kbuf[0] = '\0';
            if (CFGetTypeID(keys[i]) != CFStringGetTypeID())
                snprintf(kbuf, sizeof(kbuf), "<non-string-key>");
            else if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
            printf("%s  %s = ", pad, kbuf);
            printCFType(vals[i], indent + 4);
        }
        free(keys); free(vals);
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        for (CFIndex i = 0; i < count; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else {
        printf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

int main(void) {
    printf("Running as uid=%u\n\n", (unsigned)getuid());

    // 1. External power adapter. nil => on battery; a dictionary => external
    //    power attached. This is the #466 gating signal.
    printf("=== IOPSCopyExternalPowerAdapterDetails ===\n");
    CFDictionaryRef adapter = IOPSCopyExternalPowerAdapterDetails();
    if (adapter) {
        printf("  status: PRESENT (external power attached)\n");
        printCFType(adapter, 2);
        CFRelease(adapter);
    } else {
        printf("  status: nil (no external adapter details reported; on battery, a desktop on AC, or an API error - see providing-power-source below)\n");
    }
    printf("\n");

    // 2. Providing power source type: "AC Power", "Battery Power", "UPS Power".
    printf("=== IOPSGetProvidingPowerSourceType ===\n");
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFStringRef providing = IOPSGetProvidingPowerSourceType(blob);
        if (providing) {
            char buf[128];
            buf[0] = '\0';
            if (!CFStringGetCString(providing, buf, sizeof(buf), kCFStringEncodingUTF8))
                snprintf(buf, sizeof(buf), "<unconvertible>");
            printf("  %s\n", buf);
        } else {
            printf("  (null)\n");
        }
    } else {
        printf("  (no power sources blob)\n");
    }
    printf("\n");

    // 3. Per-source descriptions (battery percentage, charging flags, etc.).
    printf("=== IOPSCopyPowerSourcesList descriptions ===\n");
    if (blob) {
        CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
        if (sources) {
            CFIndex count = CFArrayGetCount(sources);
            printf("  %ld power source(s)\n", (long)count);
            for (CFIndex i = 0; i < count; i++) {
                CFTypeRef src = CFArrayGetValueAtIndex(sources, i);
                CFDictionaryRef desc = IOPSGetPowerSourceDescription(blob, src);
                printf("  [%ld]\n", (long)i);
                printCFType(desc, 4);
            }
            CFRelease(sources);
        } else {
            printf("  (no power sources list)\n");
        }
        CFRelease(blob);
    } else {
        printf("  (no power sources blob)\n");
    }
    printf("\n");

    return 0;
}
