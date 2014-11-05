//
//  DDSecurityHelpers.h
//  CometClient
//
//  Created by Sebastian Rehnby on 04/11/14.
//
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

/**
 *  Returns the first certificate in the trust chain.
 *
 *  @param trust The trust chain.
 *
 *  @return The first certificate in the trust chain if any, otherwise NULL.
 */
static SecCertificateRef DDFirstCertificateFromTrust(SecTrustRef trust) {
  SecCertificateRef certificate = NULL;
  
  if (SecTrustGetCertificateCount(trust) > 0) {
    certificate = SecTrustGetCertificateAtIndex(trust, 0);
  }
  
  return certificate;
}

/**
 *  Returns the public key of a certificate.
 *
 *  @param certificate The certificate to extract the public key from.
 *
 *  @return The public key of the certificate.
 */
static id DDPublicKeyForCertificate(SecCertificateRef certificate) {
  id publicKey = nil;
  
  SecCertificateRef tempCertificates[1];
  tempCertificates[0] = certificate;
  CFArrayRef certificates = CFArrayCreate(NULL, (const void **)tempCertificates, 1, NULL);
  
  SecPolicyRef policy = SecPolicyCreateBasicX509();
  SecTrustRef trust = NULL;
  OSStatus status = SecTrustCreateWithCertificates(certificates, policy, &trust);
  
  if (status == errSecSuccess) {
    status = SecTrustEvaluate(trust, NULL);
    
    if (status == errSecSuccess) {
      publicKey = (id)SecTrustCopyPublicKey(trust);
    }
  }
  
  if (policy) {
    CFRelease(policy);
  }
  
  if (certificates) {
    CFRelease(certificates);
  }
  
  if (trust) {
    CFRelease(trust);
  }
  
  return [publicKey autorelease];
}

#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
static NSData * DDDataForKey(SecKeyRef key) {
  NSData *data = nil;
  
  CFDataRef dataRef = NULL;
  OSStatus status = SecItemExport(key, kSecFormatUnknown, kSecItemPemArmour, NULL, &dataRef);
  if (status == errSecSuccess) {
    data = (NSData *)dataRef;
  } else {
    if (dataRef) {
      CFRelease(dataRef);
    }
  }
  
  return [data autorelease];
}
#endif

static BOOL DDKeyIsEqualToKey(SecKeyRef key1, SecKeyRef key2) {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
  return [(id)key1 isEqual:(id)key2];
#else
  return [DDDataForKey(key1) isEqual:DDDataForKey(key2)];
#endif
}
