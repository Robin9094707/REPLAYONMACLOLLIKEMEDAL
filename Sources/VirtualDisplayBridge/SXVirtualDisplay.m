#import "SXVirtualDisplay.h"

// Selectors of the (private) CoreGraphics virtual display classes. Everything is looked up
// with NSClassFromString so the app still launches if Apple ever removes them.
@protocol SXVDModeInit <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol SXVDDisplay <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

@implementation SXVirtualDisplay {
    id _display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name width:(unsigned int)width height:(unsigned int)height hiDPI:(BOOL)hiDPI {
    if (![SXVirtualDisplay isSupported]) { return nil; }
    self = [super init];
    if (!self) { return nil; }

    unsigned int scale = hiDPI ? 2 : 1;
    id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    @try {
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        [descriptor setValue:name forKey:@"name"];
        [descriptor setValue:@(width * scale) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height * scale) forKey:@"maxPixelsHigh"];
        // ~ iPhone pixel density, gives macOS a sensible physical size.
        double mmWide = width * 25.4 / 160.0, mmHigh = height * 25.4 / 160.0;
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(mmWide, mmHigh)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(0x5358) forKey:@"vendorID"];   // "SX"
        [descriptor setValue:@(0x0001) forKey:@"productID"];
        [descriptor setValue:@(arc4random_uniform(100000) + 1) forKey:@"serialNum"];
    } @catch (NSException *exception) {
        return nil;
    }

    id<SXVDDisplay> display = [(id<SXVDDisplay>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) { return nil; }

    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    id<SXVDModeInit> mode = [(id<SXVDModeInit>)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                             initWithWidth:width height:height refreshRate:60];
    @try {
        [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"];
        [settings setValue:@[mode] forKey:@"modes"];
    } @catch (NSException *exception) {
        return nil;
    }
    if (![display applySettings:settings]) { return nil; }

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    NSNumber *value = [_display valueForKey:@"displayID"];
    return (CGDirectDisplayID)value.unsignedIntValue;
}

@end
