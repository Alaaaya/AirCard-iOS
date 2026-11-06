#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "ProfileTrustBridge.h"
#import "AppleProfileAnchors.h"

static BOOL ExactCommonName(SecCertificateRef cert, NSString *expected) {
    CFStringRef name = NULL;
    if (SecCertificateCopyCommonName(cert, &name) != errSecSuccess || !name) return NO;
    BOOL equal = [(__bridge NSString *)name isEqualToString:expected];
    CFRelease(name);
    return equal;
}

int32_t mirsa_verify_profile_signer_chain(const uint8_t *signer_der, size_t signer_len,
                                        const uint8_t *chain_packet, size_t packet_len) {
    @autoreleasepool {
        if (!signer_der || signer_len == 0 || signer_len > 65536 ||
            packet_len > 262144 || (packet_len && !chain_packet)) return 0;
        NSData *signerData = [NSData dataWithBytes:signer_der length:signer_len];
        SecCertificateRef signer = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)signerData);
        if (!signer) return 0;
        // This production-only role baseline is corroborated by Apple's published SecPolicy.c.
        // No generic Apple code-signing certificate, Mac policy or TEST role is accepted.
        if (!ExactCommonName(signer, @"Apple iPhone OS Provisioning Profile Signing")) {
            CFRelease(signer); return 0;
        }
        NSMutableArray *certificates = [NSMutableArray arrayWithObject:(__bridge id)signer];
        CFRelease(signer);
        size_t offset = 0, count = 0;
        while (offset < packet_len) {
            if (++count > 16 || packet_len - offset < 4) return 0;
            uint32_t length = ((uint32_t)chain_packet[offset] << 24) |
                              ((uint32_t)chain_packet[offset+1] << 16) |
                              ((uint32_t)chain_packet[offset+2] << 8) | chain_packet[offset+3];
            offset += 4;
            if (!length || length > 65536 || length > packet_len - offset) return 0;
            NSData *data = [NSData dataWithBytes:chain_packet + offset length:length];
            SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
            if (!cert) return 0;
            if (![data isEqualToData:signerData]) [certificates addObject:(__bridge id)cert];
            CFRelease(cert);
            offset += length;
        }
        NSMutableArray *anchors = [NSMutableArray array];
        const unsigned char *bytes[] = {AppleRoot, AppleRootG2, AppleRootG3};
        const size_t lengths[] = {sizeof(AppleRoot), sizeof(AppleRootG2), sizeof(AppleRootG3)};
        for (NSUInteger i = 0; i < 3; i++) {
            SecCertificateRef anchor = SecCertificateCreateWithData(NULL,
                (__bridge CFDataRef)[NSData dataWithBytes:bytes[i] length:lengths[i]]);
            if (!anchor) return 0;
            [anchors addObject:(__bridge id)anchor]; CFRelease(anchor);
        }
        SecPolicyRef policy = SecPolicyCreateBasicX509();
        SecTrustRef trust = NULL;
        OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust);
        CFRelease(policy);
        if (status != errSecSuccess || !trust) return 0;
        BOOL valid = NO;
        if (SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors) == errSecSuccess &&
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess &&
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess &&
            SecTrustSetVerifyDate(trust, (__bridge CFDateRef)[NSDate date]) == errSecSuccess &&
            SecTrustEvaluateWithError(trust, NULL) && SecTrustGetCertificateCount(trust) == 3) {
            SecCertificateRef evaluatedLeaf = SecTrustGetCertificateAtIndex(trust, 0);
            SecCertificateRef intermediate = SecTrustGetCertificateAtIndex(trust, 1);
            SecCertificateRef root = SecTrustGetCertificateAtIndex(trust, 2);
            CFDataRef evaluatedDER = evaluatedLeaf ? SecCertificateCopyData(evaluatedLeaf) : NULL;
            valid = evaluatedDER && [(__bridge NSData *)evaluatedDER isEqualToData:signerData] &&
                    intermediate && ExactCommonName(intermediate, @"Apple iPhone Certification Authority") &&
                    root && [anchors containsObject:(__bridge id)root];
            if (evaluatedDER) CFRelease(evaluatedDER);
        }
        CFRelease(trust);
        return valid ? 1 : 0;
    }
}
