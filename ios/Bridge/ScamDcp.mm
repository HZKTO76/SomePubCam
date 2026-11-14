#import "ScamDcp.h"

#include "post/color/DcpProfile.hpp"

@implementation SCAMDcp

+ (NSNumber *)checkProfile:(NSData *)data error:(NSError **)error {
    try {
        const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
        const scam_post::DcpProfile p = scam_post::DcpProfile::parse(std::vector<uint8_t>(bytes, bytes + data.length));
        return @(p.hasLookTables);
    } catch (const std::exception& e) {
        if (error) *error = [NSError errorWithDomain:@"SCAMDcp" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()] ?: @""}];
        return nil;
    }
}

@end
