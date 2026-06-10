//
//  SOSPicker.m
//  SyncOnSet
//
//  Created by Christopher Sullivan on 10/25/13.
//
//

#import "SOSPicker.h"

#import <ImageIO/ImageIO.h>

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

#if __has_include(<MobileCoreServices/MobileCoreServices.h>)
#import <MobileCoreServices/MobileCoreServices.h>
#endif

#import "GMImagePickerController.h"
#import "GMFetchItem.h"

#define CDV_PHOTO_PREFIX @"cdv_photo_"
#define CDV_THUMB_PREFIX @"cdv_thumb_"
#define CDV_TEMP_FILE_MAX_AGE (90 * 24 * 60 * 60)

typedef enum : NSUInteger {
    FILE_URI = 0,
    BASE64_STRING = 1
} SOSPickerOutputType;

@interface SOSPicker () <GMImagePickerControllerDelegate>
@end

@implementation SOSPicker

@synthesize callbackId;

static CFStringRef SOSPickerJPEGImageType(void)
{
    if (@available(iOS 14.0, *)) {
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
        return (__bridge CFStringRef)UTTypeJPEG.identifier;
#endif
    }

#if __has_include(<MobileCoreServices/MobileCoreServices.h>)
    return kUTTypeJPEG;
#else
    return CFSTR("public.jpeg");
#endif
}

static BOOL SOSPickerHasPrefix(NSString *fileName)
{
    return [fileName hasPrefix:CDV_PHOTO_PREFIX] || [fileName hasPrefix:CDV_THUMB_PREFIX];
}

static BOOL SOSPickerPhotoAccessGranted(PHAuthorizationStatus status)
{
    if (status == PHAuthorizationStatusAuthorized) {
        return YES;
    }

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        if (status == PHAuthorizationStatusLimited) {
            return YES;
        }
    }
#endif

    return NO;
}

static NSString * const SOSPickerErrorPermissionDeniedFirstTime = @"PERMISSION_DENIED_FIRST_TIME";
static NSString * const SOSPickerErrorPermissionDeniedNeedSettings = @"PERMISSION_DENIED_NEED_SETTINGS";
static NSString * const SOSPickerErrorPermissionRestricted = @"PERMISSION_RESTRICTED";
static NSString * const SOSPickerErrorPermissionStateUnresolved = @"PERMISSION_STATE_UNRESOLVED";
static NSString * const SOSPickerErrorOpenSettingsFailed = @"OPEN_SETTINGS_FAILED";

static CDVPluginResult *SOSPickerPermissionErrorResult(NSString *code, NSString *message)
{
    NSDictionary *payload = @{ @"code": code, @"message": message };
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:payload];
}

- (CGFloat)jpegCompressionQuality
{
    CGFloat quality = self.quality / 100.0f;
    return MAX(0.0f, MIN(1.0f, quality));
}

- (void)cleanupExpiredTemporaryFiles
{
    NSString *temporaryDirectory = [NSTemporaryDirectory() stringByStandardizingPath];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:temporaryDirectory error:nil];
    if (contents == nil) {
        return;
    }

    NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-CDV_TEMP_FILE_MAX_AGE];
    for (NSString *fileName in contents) {
        if (!SOSPickerHasPrefix(fileName)) {
            continue;
        }

        NSString *filePath = [temporaryDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
        NSDate *modifiedDate = [attributes fileModificationDate];
        if (modifiedDate == nil || [modifiedDate compare:expirationDate] == NSOrderedDescending) {
            continue;
        }

        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    }
}

- (id)formattedResultWithPrimaryValue:(NSString *)primaryValue thumbValue:(NSString *)thumbValue
{
    if (!self.includeThumb) {
        return primaryValue;
    }

    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:primaryValue forKey:@"uri"];
    if (thumbValue != nil) {
        [entry setObject:thumbValue forKey:@"thumb"];
    }

    return entry;
}

- (NSString *)thumbValueForItem:(GMFetchItem *)item targetSize:(CGSize)targetSize jpegQuality:(CGFloat)jpegQuality
{
    if (item.image_thumb == nil) {
        return nil;
    }

    if (self.outputType == BASE64_STRING) {
        NSData *data = [NSData dataWithContentsOfFile:item.image_thumb];
        return data ? [data base64EncodedStringWithOptions:0] : nil;
    }

    return [[NSURL fileURLWithPath:item.image_thumb] absoluteString];
}

- (BOOL)readPixelWidth:(size_t *)pixelWidth pixelHeight:(size_t *)pixelHeight fromImageSource:(CGImageSourceRef)source
{
    if (pixelWidth == NULL || pixelHeight == NULL || source == NULL) {
        return NO;
    }

    *pixelWidth = 0;
    *pixelHeight = 0;

    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (properties == NULL) {
        return NO;
    }

    CFNumberRef widthRef = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    CFNumberRef heightRef = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);

    if (widthRef != NULL) {
        CFNumberGetValue(widthRef, kCFNumberSInt64Type, pixelWidth);
    }

    if (heightRef != NULL) {
        CFNumberGetValue(heightRef, kCFNumberSInt64Type, pixelHeight);
    }

    CFRelease(properties);
    return (*pixelWidth > 0 && *pixelHeight > 0);
}

- (NSInteger)maxPixelSizeForPixelWidth:(size_t)pixelWidth pixelHeight:(size_t)pixelHeight targetSize:(CGSize)targetSize
{
    if (pixelWidth == 0 || pixelHeight == 0) {
        return 0;
    }

    CGFloat width = (CGFloat)pixelWidth;
    CGFloat height = (CGFloat)pixelHeight;
    CGFloat targetWidth = targetSize.width;
    CGFloat targetHeight = targetSize.height;

    if (targetWidth <= 0.0f && targetHeight <= 0.0f) {
        return 0;
    }

    CGFloat widthFactor = targetWidth > 0.0f ? targetWidth / width : 0.0f;
    CGFloat heightFactor = targetHeight > 0.0f ? targetHeight / height : 0.0f;
    CGFloat scaleFactor = 0.0f;

    if (widthFactor == 0.0f) {
        scaleFactor = heightFactor;
    } else if (heightFactor == 0.0f) {
        scaleFactor = widthFactor;
    } else if (widthFactor > heightFactor) {
        scaleFactor = heightFactor;
    } else {
        scaleFactor = widthFactor;
    }

    if (scaleFactor <= 0.0f || scaleFactor >= 1.0f) {
        return 0;
    }

    size_t scaledWidth = (size_t)floor(width * scaleFactor);
    size_t scaledHeight = (size_t)floor(height * scaleFactor);
    return (NSInteger)MAX((size_t)1, MAX(scaledWidth, scaledHeight));
}

- (BOOL)addJPEGFromSource:(CGImageSourceRef)source
            toDestination:(CGImageDestinationRef)destination
               targetSize:(CGSize)targetSize
             jpegQuality:(CGFloat)quality
{
    if (source == NULL || destination == NULL) {
        return NO;
    }

    size_t pixelWidth = 0;
    size_t pixelHeight = 0;
    NSInteger maxPixelSize = 0;

    if ([self readPixelWidth:&pixelWidth pixelHeight:&pixelHeight fromImageSource:source]) {
        maxPixelSize = [self maxPixelSizeForPixelWidth:pixelWidth pixelHeight:pixelHeight targetSize:targetSize];
    }

    NSDictionary *jpegOptions = @{
        (NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)
    };

    if (maxPixelSize == 0) {
        CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef)jpegOptions);
        return CGImageDestinationFinalize(destination);
    }

    NSDictionary *thumbnailOptions = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: (id)kCFBooleanTrue,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: (id)kCFBooleanTrue,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
        (NSString *)kCGImageSourceShouldCache: (id)kCFBooleanFalse
    };

    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
    if (imageRef == NULL) {
        return NO;
    }

    CGImageDestinationAddImage(destination, imageRef, (__bridge CFDictionaryRef)jpegOptions);
    BOOL success = CGImageDestinationFinalize(destination);
    CGImageRelease(imageRef);
    return success;
}

- (NSData *)createJPEGDataFromFile:(NSString *)sourcePath targetSize:(CGSize)targetSize jpegQuality:(CGFloat)quality
{
    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL);
    if (source == NULL) {
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, SOSPickerJPEGImageType(), 1, NULL);
    if (destination == NULL) {
        CFRelease(source);
        return nil;
    }

    BOOL success = [self addJPEGFromSource:source toDestination:destination targetSize:targetSize jpegQuality:quality];
    CFRelease(destination);
    CFRelease(source);

    if (!success) {
        return nil;
    }

    return data;
}

- (BOOL)createResizedImageFromFile:(NSString *)sourcePath targetPath:(NSString *)targetPath targetSize:(CGSize)targetSize jpegQuality:(CGFloat)quality error:(NSError **)error
{
    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL);
    if (source == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"SOSPicker" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not open source image."}];
        }
        return NO;
    }

    size_t pixelWidth = 0;
    size_t pixelHeight = 0;
    NSInteger maxPixelSize = 0;

    if ([self readPixelWidth:&pixelWidth pixelHeight:&pixelHeight fromImageSource:source]) {
        maxPixelSize = [self maxPixelSizeForPixelWidth:pixelWidth pixelHeight:pixelHeight targetSize:targetSize];
    }

    if (maxPixelSize == 0 && quality >= 0.999f && (targetSize.width > 0.0f || targetSize.height > 0.0f)) {
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:sourcePath toPath:targetPath error:error];
        CFRelease(source);
        return copied;
    }

    NSURL *targetURL = [NSURL fileURLWithPath:targetPath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)targetURL, SOSPickerJPEGImageType(), 1, NULL);
    if (destination == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"SOSPicker" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not create destination image."}];
        }
        CFRelease(source);
        return NO;
    }

    BOOL success = [self addJPEGFromSource:source toDestination:destination targetSize:targetSize jpegQuality:quality];
    if (!success && error != NULL) {
        *error = [NSError errorWithDomain:@"SOSPicker" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Could not write destination image."}];
    }

    CFRelease(destination);
    CFRelease(source);
    return success;
}

- (void) hasReadPermission:(CDVInvokedUrlCommand *)command {
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:SOSPickerPhotoAccessGranted([PHPhotoLibrary authorizationStatus])];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) requestReadPermission:(CDVInvokedUrlCommand *)command {
    // [PHPhotoLibrary requestAuthorization:]
    // this method works only when it is a first time, see
    // https://developer.apple.com/library/ios/documentation/Photos/Reference/PHPhotoLibrary_Class/

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (SOSPickerPhotoAccessGranted(status)) {
        NSLog(@"Access has been granted.");
        
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } else if (status == PHAuthorizationStatusDenied) {
        NSString* message = @"Access has been denied. Change your setting > this app > Photo enable";
        NSLog(@"%@", message);

        CDVPluginResult* pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorPermissionDeniedNeedSettings, message);
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } else if (status == PHAuthorizationStatusNotDetermined) {
        // Access has not been determined. requestAuthorization: is available
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            CDVPluginResult* pluginResult = nil;
            if (SOSPickerPhotoAccessGranted(status)) {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            } else if (status == PHAuthorizationStatusDenied) {
                pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorPermissionDeniedFirstTime, @"Access has been denied.");
            } else if (status == PHAuthorizationStatusRestricted) {
                pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorPermissionRestricted, @"Access has been restricted. Change your setting > Privacy > Photo enable");
            } else {
                pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorPermissionStateUnresolved, @"Photo permission request did not resolve to an authorized state.");
            }

            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }];
    } else if (status == PHAuthorizationStatusRestricted) {
        NSString* message = @"Access has been restricted. Change your setting > Privacy > Photo enable";
        NSLog(@"%@", message);

        CDVPluginResult* pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorPermissionRestricted, message);
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void) openAppSettings:(CDVInvokedUrlCommand *)command {
    NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    if (url == nil) {
        CDVPluginResult* pluginResult = SOSPickerPermissionErrorResult(SOSPickerErrorOpenSettingsFailed, @"Could not build app settings URL.");
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            CDVPluginResult* pluginResult = success
                ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
                : SOSPickerPermissionErrorResult(SOSPickerErrorOpenSettingsFailed, @"Could not open app settings.");
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL success = [[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
        CDVPluginResult* pluginResult = success
            ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
            : SOSPickerPermissionErrorResult(SOSPickerErrorOpenSettingsFailed, @"Could not open app settings.");
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void) getPictures:(CDVInvokedUrlCommand *)command {

    NSDictionary *options = [command.arguments objectAtIndex: 0];

    self.outputType = [[options objectForKey:@"outputType"] integerValue];
    self.includeThumb = [[options objectForKey:@"includeThumb"] boolValue];
    BOOL allow_video = [[options objectForKey:@"allow_video" ] boolValue ];
    NSInteger maximumImagesCount = [[options objectForKey:@"maximumImagesCount"] integerValue];
    NSString * title = [options objectForKey:@"title"];
    NSString * message = [options objectForKey:@"message"];
    BOOL disable_popover = [[options objectForKey:@"disable_popover" ] boolValue];
    if (message == (id)[NSNull null]) {
      message = nil;
    }
    self.width = [[options objectForKey:@"width"] integerValue];
    self.height = [[options objectForKey:@"height"] integerValue];
    self.quality = [[options objectForKey:@"quality"] integerValue];

    [self cleanupExpiredTemporaryFiles];

    self.callbackId = command.callbackId;
    [self launchGMImagePicker:allow_video title:title message:message disable_popover:disable_popover maximumImagesCount:maximumImagesCount];
}

- (void)launchGMImagePicker:(bool)allow_video title:(NSString *)title message:(NSString *)message disable_popover:(BOOL)disable_popover maximumImagesCount:(NSInteger)maximumImagesCount
{
    GMImagePickerController *picker = [[GMImagePickerController alloc] init:allow_video];
    picker.delegate = self;
    picker.maximumImagesCount = maximumImagesCount;
    picker.title = title;
    picker.customNavigationBarPrompt = message;
    picker.colsInPortrait = 4;
    picker.colsInLandscape = 6;
    picker.minimumInteritemSpacing = 2.0;

    if(!disable_popover) {
        picker.modalPresentationStyle = UIModalPresentationPopover;

        UIPopoverPresentationController *popPC = picker.popoverPresentationController;
        popPC.permittedArrowDirections = UIPopoverArrowDirectionAny;
        popPC.sourceView = picker.view;
        //popPC.sourceRect = nil;
    }

    [self.viewController showViewController:picker sender:nil];
}


#pragma mark - UIImagePickerControllerDelegate


- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    [picker.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    NSLog(@"UIImagePickerController: User finished picking assets");
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    CDVPluginResult* pluginResult = nil;
    NSArray* emptyArray = [NSArray array];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:emptyArray];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    [self.viewController dismissViewControllerAnimated:YES completion:nil];
    NSLog(@"UIImagePickerController: User pressed cancel button");
}

#pragma mark - GMImagePickerControllerDelegate

- (void)assetsPickerController:(GMImagePickerController *)picker didFinishPickingAssets:(NSArray *)fetchArray
{
    [picker.presentingViewController dismissViewControllerAnimated:YES completion:nil];

    NSLog(@"GMImagePicker: User finished picking assets. Number of selected items is: %lu", (unsigned long)fetchArray.count);

    NSMutableArray * result_all = [[NSMutableArray alloc] init];
    CGSize targetSize = CGSizeMake(self.width, self.height);
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];

    NSError* err = nil;
    int i = 1;
    NSString* filePath;
    CDVPluginResult* result = nil;
    CGFloat jpegQuality = [self jpegCompressionQuality];

    for (GMFetchItem *item in fetchArray) {

        if ( !item.image_fullsize ) {
            continue;
        }

        NSString *thumbValue = [self thumbValueForItem:item targetSize:targetSize jpegQuality:jpegQuality];

        do {
            filePath = [NSString stringWithFormat:@"%@/%@%03d.%@", docsPath, CDV_PHOTO_PREFIX, i++, @"jpg"];
        } while ([fileMgr fileExistsAtPath:filePath]);

        NSData* data = nil;
        if (self.width == 0 && self.height == 0) {
            // no scaling required
            if (self.outputType == BASE64_STRING){
                if (self.quality == 100) {
                    data = [NSData dataWithContentsOfFile:item.image_fullsize];
                } else {
                    data = [self createJPEGDataFromFile:item.image_fullsize targetSize:CGSizeZero jpegQuality:jpegQuality];
                }

                if (data == nil) {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"Could not read image data."];
                    break;
                }

                [result_all addObject:[self formattedResultWithPrimaryValue:[data base64EncodedStringWithOptions:0] thumbValue:thumbValue]];
            } else {
                if (self.quality == 100) {
                    // no scaling, no downsampling, this is the fastest option
                    [result_all addObject:[self formattedResultWithPrimaryValue:item.image_fullsize thumbValue:thumbValue]];
                } else {
                    if (![self createResizedImageFromFile:item.image_fullsize targetPath:filePath targetSize:CGSizeZero jpegQuality:jpegQuality error:&err]) {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                        break;
                    } else {
                        [result_all addObject:[self formattedResultWithPrimaryValue:[[NSURL fileURLWithPath:filePath] absoluteString] thumbValue:thumbValue]];
                    }
                }
            }
        } else {
            // scale
            if(self.outputType == BASE64_STRING){
                data = [self createJPEGDataFromFile:item.image_fullsize targetSize:targetSize jpegQuality:jpegQuality];
                if (data == nil) {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"Could not resize image data."];
                    break;
                }

                [result_all addObject:[self formattedResultWithPrimaryValue:[data base64EncodedStringWithOptions:0] thumbValue:thumbValue]];
            } else {
                if (![self createResizedImageFromFile:item.image_fullsize targetPath:filePath targetSize:targetSize jpegQuality:jpegQuality error:&err]) {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                    break;
                } else {
                    [result_all addObject:[self formattedResultWithPrimaryValue:[[NSURL fileURLWithPath:filePath] absoluteString] thumbValue:thumbValue]];
                }
            }
        }
    }

    if (result == nil) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:result_all];
    }

    [self.viewController dismissViewControllerAnimated:YES completion:nil];
    [self.commandDelegate sendPluginResult:result callbackId:self.callbackId];

}

//Optional implementation:
-(void)assetsPickerControllerDidCancel:(GMImagePickerController *)picker
{
   CDVPluginResult* pluginResult = nil;
   NSArray* emptyArray = [NSArray array];
   pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:emptyArray];
   [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
   [picker.presentingViewController dismissViewControllerAnimated:YES completion:nil];
   NSLog(@"GMImagePicker: User pressed cancel button");
}


@end
