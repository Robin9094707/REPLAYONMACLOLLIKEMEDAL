#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual monitor that macOS treats like a real display (used to turn the iPhone
/// into a second screen). Backed by CoreGraphics' CGVirtualDisplay, loaded at runtime –
/// if the system does not provide it, the initializer returns nil.
@interface SXVirtualDisplay : NSObject

/// width/height in points; with hiDPI the backing store is twice as large.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                                hiDPI:(BOOL)hiDPI;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

+ (BOOL)isSupported;

@end

NS_ASSUME_NONNULL_END
