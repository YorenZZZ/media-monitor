#import <Cocoa/Cocoa.h>

static NSBezierPath *rounded(NSRect rect, CGFloat radius) { return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius]; }

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 2) return 1;
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1024, 1024)];
        [image lockFocus];
        [[NSColor clearColor] set]; NSRectFill(NSMakeRect(0, 0, 1024, 1024));
        [[NSColor colorWithRed:0.06 green:0.14 blue:0.19 alpha:1] set]; [rounded(NSMakeRect(96, 96, 832, 832), 190) fill];
        [[NSColor colorWithRed:0.12 green:0.75 blue:0.70 alpha:1] set]; [rounded(NSMakeRect(172, 172, 680, 680), 150) fill];
        [[NSColor colorWithRed:0.95 green:0.43 blue:0.35 alpha:1] set];
        CGFloat bars[] = {172, 292, 416, 350, 520};
        CGFloat heights[] = {160, 290, 410, 250, 350};
        for (int i = 0; i < 5; i++) [rounded(NSMakeRect(262 + i * 102, 512 - heights[i] / 2, 56, heights[i]), 28) fill];
        [image unlockFocus];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
    }
    return 0;
}
