// Declarations for Apple's private AccessibilityPlatformTranslation framework.
// Used via objc_lookUpClass / NSSelectorFromString from Swift — these types are
// never linked directly. Derived from class-dump headers; see idb (MIT, Meta).

#ifndef AXP_TRANSLATION_BRIDGE_H
#define AXP_TRANSLATION_BRIDGE_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Forward declarations
@class AXPTranslationObject;
@class AXPTranslatorRequest;
@class AXPTranslatorResponse;
@class AXPMacPlatformElement;

// Block type returned by the delegate — synchronously provides a response.
typedef AXPTranslatorResponse * _Nonnull (^AXPTranslationCallback)(AXPTranslatorRequest * _Nonnull request);

// MARK: - AXPTranslationObject

@interface AXPTranslationObject : NSObject <NSCopying, NSSecureCoding>

@property (nonatomic) int pid;
@property (nonatomic) unsigned long long objectID;
@property (copy, nonatomic, nullable) NSString *bridgeDelegateToken;
@property (copy, nonatomic, nullable) NSData *rawElementData;
@property (nonatomic) BOOL isApplicationElement;

@end

// MARK: - AXPTranslatorRequest

@interface AXPTranslatorRequest : NSObject <NSCopying, NSSecureCoding>

@property (retain, nonatomic, nullable) AXPTranslationObject *translation;
@property (nonatomic) unsigned long long requestType;
@property (nonatomic) unsigned long long attributeType;

@end

// MARK: - AXPTranslatorResponse

@interface AXPTranslatorResponse : NSObject <NSCopying, NSSecureCoding>

+ (nonnull instancetype)emptyResponse;

@property (nonatomic) unsigned long long error;
@property (retain, nonatomic, nullable) id resultData;

@end

// MARK: - AXPMacPlatformElement (NSAccessibilityElement subclass)

@interface AXPMacPlatformElement : NSAccessibilityElement

@property (retain, nonatomic, nonnull) AXPTranslationObject *translation;

- (nullable NSString *)accessibilityRole;
- (nullable NSString *)accessibilityLabel;
- (nullable NSString *)accessibilityTitle;
- (nullable id)accessibilityValue;
- (nullable NSString *)accessibilityIdentifier;
- (nullable NSString *)accessibilityHelp;
- (NSRect)accessibilityFrame;
- (nullable NSArray<AXPMacPlatformElement *> *)accessibilityChildren;
- (nullable id)accessibilityAttributeValue:(nonnull NSString *)attribute;
- (BOOL)accessibilityEnabled;
- (nullable NSString *)accessibilityRoleDescription;
- (nullable NSString *)accessibilitySubrole;
- (BOOL)isAccessibilityHidden;
- (BOOL)isAccessibilityFocused;

@end

// MARK: - AXPTranslationTokenDelegateHelper protocol

@protocol AXPTranslationTokenDelegateHelper <NSObject>

- (nonnull AXPTranslationCallback)accessibilityTranslationDelegateBridgeCallbackWithToken:(nonnull NSString *)token;
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(nonnull NSString *)token;
- (nullable id)accessibilityTranslationRootParentWithToken:(nonnull NSString *)token;

@end

// MARK: - AXPTranslator

@interface AXPTranslator : NSObject

+ (nonnull instancetype)sharedInstance;

@property (nonatomic, weak, nullable) id<AXPTranslationTokenDelegateHelper> bridgeTokenDelegate;
@property (nonatomic) BOOL supportsDelegateTokens;
@property (nonatomic) BOOL accessibilityEnabled;

- (nullable AXPTranslationObject *)frontmostApplicationWithDisplayId:(unsigned int)displayId
                                                  bridgeDelegateToken:(nonnull NSString *)token;
- (nullable AXPTranslationObject *)objectAtPoint:(CGPoint)point
                                        displayId:(unsigned int)displayId
                                bridgeDelegateToken:(nonnull NSString *)token;
- (nullable AXPMacPlatformElement *)macPlatformElementFromTranslation:(nonnull AXPTranslationObject *)translation;

@end

#endif // AXP_TRANSLATION_BRIDGE_H
