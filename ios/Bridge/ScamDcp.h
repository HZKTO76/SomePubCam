#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// DcpProfile.parse (Engine/post/color/DcpProfile.hpp) for the import: nil and the reason when the file is no usable DCP,
/// else whether it carries hue tables or tone curves (not applied: «only the matrices»).
@interface SCAMDcp : NSObject
+ (nullable NSNumber *)checkProfile:(NSData *)data error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
