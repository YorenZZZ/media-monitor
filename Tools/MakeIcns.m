#import <Foundation/Foundation.h>

static void appendBE32(NSMutableData *data, uint32_t value) {
    uint32_t be = CFSwapInt32HostToBig(value);
    [data appendBytes:&be length:sizeof(be)];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 3) return 1;
        NSData *png = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (!png) return 2;
        NSMutableData *icns = [NSMutableData data];
        [icns appendBytes:"icns" length:4]; appendBE32(icns, (uint32_t)(16 + png.length));
        [icns appendBytes:"ic10" length:4]; appendBE32(icns, (uint32_t)(8 + png.length)); [icns appendData:png];
        return [icns writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES] ? 0 : 3;
    }
}
